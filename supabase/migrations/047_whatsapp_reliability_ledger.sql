-- ============================================================
-- 047_whatsapp_reliability_ledger.sql
--
-- Provider-neutral reliability ledger for inbound idempotency, outbound
-- retries, health checks and dead-letter inspection.
-- ============================================================

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'whatsapp_provider_enum') THEN
    CREATE TYPE whatsapp_provider_enum AS ENUM ('meta_cloud', 'evolution');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'integration_attempt_status_enum') THEN
    CREATE TYPE integration_attempt_status_enum AS ENUM ('pending', 'processing', 'succeeded', 'failed', 'dead_letter');
  END IF;
END $$;

ALTER TABLE public.whatsapp_config
  ADD COLUMN IF NOT EXISTS provider whatsapp_provider_enum NOT NULL DEFAULT 'meta_cloud',
  ADD COLUMN IF NOT EXISTS provider_instance_id TEXT,
  ADD COLUMN IF NOT EXISTS last_health_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_health_ok BOOLEAN,
  ADD COLUMN IF NOT EXISTS last_health_details JSONB NOT NULL DEFAULT '{}'::jsonb;

CREATE TABLE IF NOT EXISTS public.whatsapp_webhook_receipts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  provider whatsapp_provider_enum NOT NULL,
  provider_event_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  provider_message_id TEXT,
  phone_normalized TEXT,
  payload_hash TEXT NOT NULL,
  raw_payload JSONB NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processing_started_at TIMESTAMPTZ,
  processed_at TIMESTAMPTZ,
  status integration_attempt_status_enum NOT NULL DEFAULT 'pending',
  error_code TEXT,
  error_message TEXT,
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  next_attempt_at TIMESTAMPTZ,
  UNIQUE(account_id, provider, provider_event_id),
  UNIQUE(account_id, id)
);

CREATE TABLE IF NOT EXISTS public.whatsapp_delivery_attempts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  message_id UUID NOT NULL REFERENCES public.messages(id) ON DELETE CASCADE,
  provider whatsapp_provider_enum NOT NULL,
  idempotency_key TEXT NOT NULL,
  attempt_number INTEGER NOT NULL CHECK (attempt_number > 0),
  status integration_attempt_status_enum NOT NULL DEFAULT 'pending',
  provider_message_id TEXT,
  request_summary JSONB NOT NULL DEFAULT '{}'::jsonb,
  response_summary JSONB NOT NULL DEFAULT '{}'::jsonb,
  error_code TEXT,
  error_message TEXT,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at TIMESTAMPTZ,
  next_attempt_at TIMESTAMPTZ,
  UNIQUE(account_id, idempotency_key, attempt_number)
);

CREATE TABLE IF NOT EXISTS public.integration_dead_letters (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  integration_type TEXT NOT NULL,
  source_table TEXT NOT NULL,
  source_id UUID NOT NULL,
  error_code TEXT,
  error_message TEXT NOT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  first_failed_at TIMESTAMPTZ NOT NULL,
  last_failed_at TIMESTAMPTZ NOT NULL,
  failure_count INTEGER NOT NULL DEFAULT 1 CHECK (failure_count > 0),
  resolved_at TIMESTAMPTZ,
  resolved_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  resolution_notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(account_id, integration_type, source_table, source_id)
);

CREATE INDEX IF NOT EXISTS idx_whatsapp_receipts_pending
  ON public.whatsapp_webhook_receipts(account_id, status, next_attempt_at, received_at)
  WHERE status IN ('pending', 'failed');
CREATE INDEX IF NOT EXISTS idx_whatsapp_delivery_attempts_message
  ON public.whatsapp_delivery_attempts(account_id, message_id, attempt_number DESC);
CREATE INDEX IF NOT EXISTS idx_dead_letters_open
  ON public.integration_dead_letters(account_id, integration_type, last_failed_at DESC)
  WHERE resolved_at IS NULL;

CREATE OR REPLACE FUNCTION public.register_whatsapp_webhook_receipt(
  p_account_id UUID,
  p_provider whatsapp_provider_enum,
  p_provider_event_id TEXT,
  p_event_type TEXT,
  p_payload_hash TEXT,
  p_raw_payload JSONB,
  p_provider_message_id TEXT DEFAULT NULL,
  p_phone_normalized TEXT DEFAULT NULL
)
RETURNS TABLE(receipt_id UUID, is_new BOOLEAN)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
BEGIN
  IF NULLIF(btrim(p_provider_event_id), '') IS NULL THEN
    RAISE EXCEPTION 'provider_event_id is required' USING ERRCODE = 'check_violation';
  END IF;
  IF NULLIF(btrim(p_payload_hash), '') IS NULL THEN
    RAISE EXCEPTION 'payload_hash is required' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO public.whatsapp_webhook_receipts (
    account_id, provider, provider_event_id, event_type, provider_message_id,
    phone_normalized, payload_hash, raw_payload
  ) VALUES (
    p_account_id, p_provider, btrim(p_provider_event_id), p_event_type,
    p_provider_message_id, p_phone_normalized, p_payload_hash,
    COALESCE(p_raw_payload, '{}'::jsonb)
  )
  ON CONFLICT (account_id, provider, provider_event_id) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL THEN
    RETURN QUERY SELECT v_id, true;
  ELSE
    SELECT id INTO v_id
    FROM public.whatsapp_webhook_receipts
    WHERE account_id = p_account_id
      AND provider = p_provider
      AND provider_event_id = btrim(p_provider_event_id);
    RETURN QUERY SELECT v_id, false;
  END IF;
END;
$$;

ALTER FUNCTION public.register_whatsapp_webhook_receipt(
  UUID, whatsapp_provider_enum, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT
) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.register_whatsapp_webhook_receipt(
  UUID, whatsapp_provider_enum, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT
) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.register_whatsapp_webhook_receipt(
  UUID, whatsapp_provider_enum, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT
) TO service_role;

CREATE OR REPLACE FUNCTION public.claim_whatsapp_webhook_receipts(
  p_limit INTEGER DEFAULT 25,
  p_at TIMESTAMPTZ DEFAULT NOW()
)
RETURNS SETOF public.whatsapp_webhook_receipts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH candidates AS (
    SELECT id
    FROM public.whatsapp_webhook_receipts
    WHERE status IN ('pending', 'failed')
      AND (next_attempt_at IS NULL OR next_attempt_at <= p_at)
    ORDER BY received_at
    FOR UPDATE SKIP LOCKED
    LIMIT LEAST(GREATEST(p_limit, 1), 100)
  )
  UPDATE public.whatsapp_webhook_receipts r
  SET status = 'processing',
      processing_started_at = p_at,
      attempt_count = attempt_count + 1
  FROM candidates c
  WHERE r.id = c.id
  RETURNING r.*;
END;
$$;

ALTER FUNCTION public.claim_whatsapp_webhook_receipts(INTEGER, TIMESTAMPTZ)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION public.claim_whatsapp_webhook_receipts(INTEGER, TIMESTAMPTZ)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_whatsapp_webhook_receipts(INTEGER, TIMESTAMPTZ)
  TO service_role;

CREATE OR REPLACE FUNCTION public.fail_whatsapp_webhook_receipt(
  p_receipt_id UUID,
  p_error_code TEXT,
  p_error_message TEXT,
  p_max_attempts INTEGER DEFAULT 5,
  p_retry_delay INTERVAL DEFAULT INTERVAL '5 minutes'
)
RETURNS public.whatsapp_webhook_receipts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_receipt public.whatsapp_webhook_receipts%ROWTYPE;
  v_dead BOOLEAN;
BEGIN
  SELECT * INTO v_receipt
  FROM public.whatsapp_webhook_receipts
  WHERE id = p_receipt_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Receipt not found' USING ERRCODE = 'no_data_found';
  END IF;

  v_dead := v_receipt.attempt_count >= GREATEST(p_max_attempts, 1);
  UPDATE public.whatsapp_webhook_receipts
  SET status = CASE WHEN v_dead THEN 'dead_letter' ELSE 'failed' END,
      error_code = p_error_code,
      error_message = left(p_error_message, 4000),
      next_attempt_at = CASE WHEN v_dead THEN NULL ELSE NOW() + p_retry_delay END
  WHERE id = p_receipt_id
  RETURNING * INTO v_receipt;

  IF v_dead THEN
    INSERT INTO public.integration_dead_letters (
      account_id, integration_type, source_table, source_id,
      error_code, error_message, payload,
      first_failed_at, last_failed_at, failure_count
    ) VALUES (
      v_receipt.account_id, 'whatsapp', 'whatsapp_webhook_receipts', v_receipt.id,
      p_error_code, left(p_error_message, 4000), v_receipt.raw_payload,
      COALESCE(v_receipt.processing_started_at, v_receipt.received_at), NOW(),
      v_receipt.attempt_count
    )
    ON CONFLICT (account_id, integration_type, source_table, source_id) DO UPDATE
    SET error_code = EXCLUDED.error_code,
        error_message = EXCLUDED.error_message,
        payload = EXCLUDED.payload,
        last_failed_at = EXCLUDED.last_failed_at,
        failure_count = EXCLUDED.failure_count,
        resolved_at = NULL,
        resolved_by = NULL,
        resolution_notes = NULL;
  END IF;

  RETURN v_receipt;
END;
$$;

ALTER FUNCTION public.fail_whatsapp_webhook_receipt(UUID, TEXT, TEXT, INTEGER, INTERVAL)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION public.fail_whatsapp_webhook_receipt(UUID, TEXT, TEXT, INTEGER, INTERVAL)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_whatsapp_webhook_receipt(UUID, TEXT, TEXT, INTEGER, INTERVAL)
  TO service_role;

CREATE OR REPLACE FUNCTION public.complete_whatsapp_webhook_receipt(p_receipt_id UUID)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.whatsapp_webhook_receipts
  SET status = 'succeeded', processed_at = NOW(),
      error_code = NULL, error_message = NULL, next_attempt_at = NULL
  WHERE id = p_receipt_id;
$$;

ALTER FUNCTION public.complete_whatsapp_webhook_receipt(UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.complete_whatsapp_webhook_receipt(UUID)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_whatsapp_webhook_receipt(UUID)
  TO service_role;

ALTER TABLE public.whatsapp_webhook_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.whatsapp_delivery_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.integration_dead_letters ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS whatsapp_receipts_select ON public.whatsapp_webhook_receipts;
CREATE POLICY whatsapp_receipts_select ON public.whatsapp_webhook_receipts FOR SELECT
  USING (public.has_account_capability(account_id, 'audit.read'));
DROP POLICY IF EXISTS whatsapp_delivery_attempts_select ON public.whatsapp_delivery_attempts;
CREATE POLICY whatsapp_delivery_attempts_select ON public.whatsapp_delivery_attempts FOR SELECT
  USING (public.has_account_capability(account_id, 'audit.read'));
DROP POLICY IF EXISTS integration_dead_letters_select ON public.integration_dead_letters;
CREATE POLICY integration_dead_letters_select ON public.integration_dead_letters FOR SELECT
  USING (public.has_account_capability(account_id, 'audit.read'));
DROP POLICY IF EXISTS integration_dead_letters_update ON public.integration_dead_letters;
CREATE POLICY integration_dead_letters_update ON public.integration_dead_letters FOR UPDATE
  USING (public.has_account_capability(account_id, 'account.manage'))
  WITH CHECK (public.has_account_capability(account_id, 'account.manage'));

GRANT SELECT ON public.whatsapp_webhook_receipts TO authenticated;
GRANT SELECT ON public.whatsapp_delivery_attempts TO authenticated;
GRANT SELECT, UPDATE ON public.integration_dead_letters TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.whatsapp_webhook_receipts FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.whatsapp_delivery_attempts FROM authenticated;
REVOKE INSERT, DELETE ON public.integration_dead_letters FROM authenticated;

COMMIT;
