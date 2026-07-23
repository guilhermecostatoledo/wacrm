-- ============================================================
-- 050_governance_audit_retention.sql
--
-- Production governance: bounded audit feed, account retention policy,
-- supervised dead-letter resolution and service-only operational cleanup.
-- Domain events remain append-only for the configured audit retention period.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.account_governance_settings (
  account_id UUID PRIMARY KEY REFERENCES public.accounts(id) ON DELETE CASCADE,
  domain_event_retention_days INTEGER NOT NULL DEFAULT 2555
    CHECK (domain_event_retention_days BETWEEN 365 AND 3650),
  successful_integration_log_retention_days INTEGER NOT NULL DEFAULT 90
    CHECK (successful_integration_log_retention_days BETWEEN 30 AND 730),
  failed_integration_log_retention_days INTEGER NOT NULL DEFAULT 730
    CHECK (failed_integration_log_retention_days BETWEEN 90 AND 3650),
  require_two_person_broadcast_approval BOOLEAN NOT NULL DEFAULT false,
  updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.account_governance_settings (account_id)
SELECT id FROM public.accounts
ON CONFLICT (account_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.on_account_seed_governance_settings()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.account_governance_settings (account_id)
  VALUES (NEW.id)
  ON CONFLICT (account_id) DO NOTHING;
  RETURN NEW;
END;
$$;

ALTER FUNCTION public.on_account_seed_governance_settings() OWNER TO postgres;
DROP TRIGGER IF EXISTS seed_governance_settings_after_account_insert ON public.accounts;
CREATE TRIGGER seed_governance_settings_after_account_insert
  AFTER INSERT ON public.accounts
  FOR EACH ROW EXECUTE FUNCTION public.on_account_seed_governance_settings();

CREATE INDEX IF NOT EXISTS idx_domain_events_account_occurred
  ON public.domain_events(account_id, occurred_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_domain_events_account_actor
  ON public.domain_events(account_id, actor_user_id, occurred_at DESC)
  WHERE actor_user_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.crm_audit_feed(
  p_account_id UUID,
  p_limit INTEGER DEFAULT 100,
  p_before TIMESTAMPTZ DEFAULT NULL,
  p_event_type TEXT DEFAULT NULL,
  p_aggregate_type TEXT DEFAULT NULL,
  p_actor_user_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
  v_result JSONB;
BEGIN
  IF NOT public.has_account_capability(p_account_id, 'audit.read') THEN
    RAISE EXCEPTION 'Missing audit.read capability'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  WITH domain_rows AS (
    SELECT
      e.occurred_at AS occurred_at,
      e.id AS id,
      'domain_event'::TEXT AS record_type,
      e.event_type AS event_type,
      e.aggregate_type AS aggregate_type,
      e.aggregate_id AS aggregate_id,
      e.actor_user_id AS actor_user_id,
      p.full_name AS actor_name,
      e.source::TEXT AS source,
      e.payload AS payload,
      NULL::TEXT AS severity,
      NULL::TEXT AS error_message,
      NULL::TIMESTAMPTZ AS resolved_at
    FROM public.domain_events e
    LEFT JOIN public.profiles p
      ON p.account_id = e.account_id AND p.user_id = e.actor_user_id
    WHERE e.account_id = p_account_id
      AND (p_before IS NULL OR e.occurred_at < p_before)
      AND (p_event_type IS NULL OR e.event_type = p_event_type)
      AND (p_aggregate_type IS NULL OR e.aggregate_type = p_aggregate_type)
      AND (p_actor_user_id IS NULL OR e.actor_user_id = p_actor_user_id)
  ),
  failure_rows AS (
    SELECT
      d.last_failed_at AS occurred_at,
      d.id AS id,
      'integration_dead_letter'::TEXT AS record_type,
      d.integration_type || '.dead_letter' AS event_type,
      d.source_table AS aggregate_type,
      d.source_id AS aggregate_id,
      d.resolved_by AS actor_user_id,
      p.full_name AS actor_name,
      'integration'::TEXT AS source,
      d.payload AS payload,
      CASE WHEN d.resolved_at IS NULL THEN 'error' ELSE 'resolved' END AS severity,
      d.error_message AS error_message,
      d.resolved_at AS resolved_at
    FROM public.integration_dead_letters d
    LEFT JOIN public.profiles p
      ON p.account_id = d.account_id AND p.user_id = d.resolved_by
    WHERE d.account_id = p_account_id
      AND (p_before IS NULL OR d.last_failed_at < p_before)
      AND (p_event_type IS NULL OR d.integration_type || '.dead_letter' = p_event_type)
      AND (p_aggregate_type IS NULL OR d.source_table = p_aggregate_type)
      AND (p_actor_user_id IS NULL OR d.resolved_by = p_actor_user_id)
  ),
  combined AS (
    SELECT * FROM domain_rows
    UNION ALL
    SELECT * FROM failure_rows
  ),
  page AS (
    SELECT *
    FROM combined
    ORDER BY occurred_at DESC, id DESC
    LIMIT v_limit + 1
  ),
  numbered AS (
    SELECT *, row_number() OVER (ORDER BY occurred_at DESC, id DESC) AS row_number
    FROM page
  )
  SELECT jsonb_build_object(
    'data', COALESCE(jsonb_agg(
      jsonb_build_object(
        'occurred_at', occurred_at,
        'id', id,
        'record_type', record_type,
        'event_type', event_type,
        'aggregate_type', aggregate_type,
        'aggregate_id', aggregate_id,
        'actor_user_id', actor_user_id,
        'actor_name', actor_name,
        'source', source,
        'payload', payload,
        'severity', severity,
        'error_message', error_message,
        'resolved_at', resolved_at
      ) ORDER BY occurred_at DESC, id DESC
    ) FILTER (WHERE row_number <= v_limit), '[]'::jsonb),
    'next_before', (
      SELECT occurred_at FROM numbered WHERE row_number = v_limit + 1 LIMIT 1
    )
  ) INTO v_result
  FROM numbered;

  RETURN COALESCE(v_result, jsonb_build_object('data', '[]'::jsonb, 'next_before', NULL));
END;
$$;

ALTER FUNCTION public.crm_audit_feed(UUID, INTEGER, TIMESTAMPTZ, TEXT, TEXT, UUID)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION public.crm_audit_feed(UUID, INTEGER, TIMESTAMPTZ, TEXT, TEXT, UUID)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.crm_audit_feed(UUID, INTEGER, TIMESTAMPTZ, TEXT, TEXT, UUID)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.resolve_integration_dead_letter(
  p_dead_letter_id UUID,
  p_notes TEXT
)
RETURNS public.integration_dead_letters
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.integration_dead_letters%ROWTYPE;
  v_actor UUID := auth.uid();
BEGIN
  IF NULLIF(btrim(p_notes), '') IS NULL THEN
    RAISE EXCEPTION 'Resolution notes are required'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_row
  FROM public.integration_dead_letters
  WHERE id = p_dead_letter_id
  FOR UPDATE;

  IF NOT FOUND OR NOT public.has_account_capability(v_row.account_id, 'account.manage') THEN
    RAISE EXCEPTION 'Dead letter not found or resolution denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_row.resolved_at IS NOT NULL THEN
    RETURN v_row;
  END IF;

  UPDATE public.integration_dead_letters
  SET resolved_at = NOW(),
      resolved_by = v_actor,
      resolution_notes = btrim(p_notes)
  WHERE id = p_dead_letter_id
  RETURNING * INTO v_row;

  INSERT INTO public.domain_events (
    account_id, aggregate_type, aggregate_id, event_type,
    actor_user_id, source, payload
  ) VALUES (
    v_row.account_id,
    'integration_dead_letter',
    v_row.id,
    'integration.dead_letter_resolved',
    v_actor,
    'human',
    jsonb_build_object(
      'integration_type', v_row.integration_type,
      'source_table', v_row.source_table,
      'source_id', v_row.source_id,
      'notes', v_row.resolution_notes
    )
  );

  RETURN v_row;
END;
$$;

ALTER FUNCTION public.resolve_integration_dead_letter(UUID, TEXT) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.resolve_integration_dead_letter(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_integration_dead_letter(UUID, TEXT)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.purge_expired_operational_logs(p_at TIMESTAMPTZ DEFAULT NOW())
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_receipts INTEGER := 0;
  v_attempts INTEGER := 0;
  v_dead_letters INTEGER := 0;
  v_events INTEGER := 0;
  v_row RECORD;
  v_count INTEGER;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres') THEN
    RAISE EXCEPTION 'Operational retention is service-only'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  FOR v_row IN
    SELECT * FROM public.account_governance_settings
  LOOP
    DELETE FROM public.whatsapp_webhook_receipts r
    WHERE r.account_id = v_row.account_id
      AND r.status = 'succeeded'
      AND r.received_at < p_at - make_interval(days => v_row.successful_integration_log_retention_days);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_receipts := v_receipts + v_count;

    DELETE FROM public.whatsapp_delivery_attempts a
    WHERE a.account_id = v_row.account_id
      AND a.status = 'succeeded'
      AND a.started_at < p_at - make_interval(days => v_row.successful_integration_log_retention_days);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_attempts := v_attempts + v_count;

    DELETE FROM public.integration_dead_letters d
    WHERE d.account_id = v_row.account_id
      AND d.resolved_at IS NOT NULL
      AND d.last_failed_at < p_at - make_interval(days => v_row.failed_integration_log_retention_days);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_dead_letters := v_dead_letters + v_count;

    DELETE FROM public.domain_events e
    WHERE e.account_id = v_row.account_id
      AND e.occurred_at < p_at - make_interval(days => v_row.domain_event_retention_days);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_events := v_events + v_count;
  END LOOP;

  RETURN jsonb_build_object(
    'receipts_deleted', v_receipts,
    'delivery_attempts_deleted', v_attempts,
    'dead_letters_deleted', v_dead_letters,
    'domain_events_deleted', v_events,
    'executed_at', p_at
  );
END;
$$;

ALTER FUNCTION public.purge_expired_operational_logs(TIMESTAMPTZ) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.purge_expired_operational_logs(TIMESTAMPTZ)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_expired_operational_logs(TIMESTAMPTZ)
  TO service_role;

ALTER TABLE public.account_governance_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS account_governance_settings_select ON public.account_governance_settings;
DROP POLICY IF EXISTS account_governance_settings_update ON public.account_governance_settings;
CREATE POLICY account_governance_settings_select ON public.account_governance_settings FOR SELECT
  USING (public.has_account_capability(account_id, 'audit.read'));
CREATE POLICY account_governance_settings_update ON public.account_governance_settings FOR UPDATE
  USING (public.has_account_capability(account_id, 'account.manage'))
  WITH CHECK (public.has_account_capability(account_id, 'account.manage'));

GRANT SELECT, UPDATE ON public.account_governance_settings TO authenticated;
REVOKE INSERT, DELETE ON public.account_governance_settings FROM authenticated;

DROP TRIGGER IF EXISTS set_updated_at ON public.account_governance_settings;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.account_governance_settings
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

COMMENT ON FUNCTION public.purge_expired_operational_logs(TIMESTAMPTZ) IS
  'Service-only retention job. Run after backup verification and monitor returned deletion counts.';

COMMIT;
