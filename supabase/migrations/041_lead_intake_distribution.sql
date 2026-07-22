-- ============================================================
-- 041_lead_intake_distribution.sql
--
-- Transactional lead intake: contact normalization/deduplication, lead
-- idempotency, distribution, SLA and first task are committed together.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.lead_distribution_rules (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  source_id UUID,
  strategy TEXT NOT NULL DEFAULT 'round_robin'
    CHECK (strategy IN ('round_robin', 'fixed', 'queue')),
  team_id UUID,
  fixed_owner_id UUID,
  queue_key TEXT,
  daily_capacity INTEGER NOT NULL DEFAULT 50 CHECK (daily_capacity > 0),
  priority INTEGER NOT NULL DEFAULT 100,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_assigned_at TIMESTAMPTZ,
  CONSTRAINT lead_distribution_source_fkey
    FOREIGN KEY (account_id, source_id)
    REFERENCES public.lead_sources(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT lead_distribution_team_fkey
    FOREIGN KEY (account_id, team_id)
    REFERENCES public.teams(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT lead_distribution_owner_fkey
    FOREIGN KEY (account_id, fixed_owner_id)
    REFERENCES public.profiles(account_id, user_id) ON DELETE RESTRICT,
  CONSTRAINT lead_distribution_strategy_check CHECK (
    (strategy <> 'fixed' OR fixed_owner_id IS NOT NULL)
    AND (strategy <> 'queue' OR NULLIF(btrim(queue_key), '') IS NOT NULL)
  ),
  UNIQUE(account_id, name),
  UNIQUE(account_id, id)
);

CREATE TABLE IF NOT EXISTS public.lead_assignment_counters (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  rule_id UUID NOT NULL,
  user_id UUID NOT NULL,
  assignment_date DATE NOT NULL DEFAULT CURRENT_DATE,
  assigned_count INTEGER NOT NULL DEFAULT 0 CHECK (assigned_count >= 0),
  last_assigned_at TIMESTAMPTZ,
  CONSTRAINT lead_assignment_counter_rule_fkey
    FOREIGN KEY (account_id, rule_id)
    REFERENCES public.lead_distribution_rules(account_id, id) ON DELETE CASCADE,
  CONSTRAINT lead_assignment_counter_profile_fkey
    FOREIGN KEY (account_id, user_id)
    REFERENCES public.profiles(account_id, user_id) ON DELETE CASCADE,
  UNIQUE(rule_id, user_id, assignment_date)
);

CREATE INDEX IF NOT EXISTS idx_lead_distribution_match
  ON public.lead_distribution_rules(account_id, source_id, priority)
  WHERE is_active;
CREATE INDEX IF NOT EXISTS idx_lead_assignment_daily
  ON public.lead_assignment_counters(account_id, assignment_date, rule_id);

-- One active commercial cycle per contact. Historical converted/disqualified
-- leads remain unlimited and preserve repeated interest over time.
CREATE UNIQUE INDEX IF NOT EXISTS uq_leads_one_active_per_contact
  ON public.leads(account_id, contact_id)
  WHERE archived_at IS NULL AND status NOT IN ('converted', 'disqualified');

CREATE OR REPLACE FUNCTION public.seed_default_lead_distribution(target_account_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.lead_distribution_rules (
    account_id, name, strategy, queue_key, daily_capacity, priority
  ) VALUES (
    target_account_id, 'Default distribution', 'round_robin', 'unassigned', 50, 1000
  )
  ON CONFLICT (account_id, name) DO NOTHING;
END;
$$;

ALTER FUNCTION public.seed_default_lead_distribution(UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.seed_default_lead_distribution(UUID) FROM PUBLIC, authenticated;
SELECT public.seed_default_lead_distribution(id) FROM public.accounts;

CREATE OR REPLACE FUNCTION public.on_account_seed_lead_distribution()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.seed_default_lead_distribution(NEW.id);
  RETURN NEW;
END;
$$;

ALTER FUNCTION public.on_account_seed_lead_distribution() OWNER TO postgres;
DROP TRIGGER IF EXISTS seed_lead_distribution_after_account_insert ON public.accounts;
CREATE TRIGGER seed_lead_distribution_after_account_insert
  AFTER INSERT ON public.accounts
  FOR EACH ROW EXECUTE FUNCTION public.on_account_seed_lead_distribution();

-- Returns one owner/queue decision and increments capacity atomically.
CREATE OR REPLACE FUNCTION public.select_lead_assignment(
  target_account_id UUID,
  target_source_id UUID,
  requested_owner_id UUID DEFAULT NULL,
  at_time TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE(owner_id UUID, queue_key TEXT, rule_id UUID)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rule public.lead_distribution_rules%ROWTYPE;
  v_owner UUID;
BEGIN
  IF requested_owner_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.account_id = target_account_id AND p.user_id = requested_owner_id
    ) THEN
      RAISE EXCEPTION 'Requested owner is not an account member'
        USING ERRCODE = 'foreign_key_violation';
    END IF;

    v_owner := public.resolve_delegated_user(
      target_account_id, requested_owner_id, 'new_leads', at_time
    );

    IF NOT EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.account_id = target_account_id AND p.user_id = v_owner
    ) THEN
      RAISE EXCEPTION 'Delegated owner is not an account member'
        USING ERRCODE = 'foreign_key_violation';
    END IF;

    RETURN QUERY SELECT v_owner, NULL::TEXT, NULL::UUID;
    RETURN;
  END IF;

  SELECT r.* INTO v_rule
  FROM public.lead_distribution_rules r
  WHERE r.account_id = target_account_id
    AND r.is_active
    AND (r.source_id = target_source_id OR r.source_id IS NULL)
  ORDER BY (r.source_id IS NOT NULL) DESC, r.priority ASC, r.created_at ASC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY SELECT NULL::UUID, 'unassigned'::TEXT, NULL::UUID;
    RETURN;
  END IF;

  IF v_rule.strategy = 'queue' THEN
    RETURN QUERY SELECT NULL::UUID, COALESCE(v_rule.queue_key, 'unassigned'), v_rule.id;
    RETURN;
  END IF;

  IF v_rule.strategy = 'fixed' THEN
    v_owner := public.resolve_delegated_user(
      target_account_id, v_rule.fixed_owner_id, 'new_leads', at_time
    );
    RETURN QUERY SELECT v_owner, NULL::TEXT, v_rule.id;
    RETURN;
  END IF;

  -- Serialize round-robin selection per rule so simultaneous webhooks cannot
  -- pick the same lowest counter before either increment is visible.
  PERFORM pg_advisory_xact_lock(hashtext(target_account_id::TEXT || ':' || v_rule.id::TEXT));

  SELECT p.user_id INTO v_owner
  FROM public.profiles p
  LEFT JOIN public.lead_assignment_counters c
    ON c.account_id = target_account_id
   AND c.rule_id = v_rule.id
   AND c.user_id = p.user_id
   AND c.assignment_date = (at_time AT TIME ZONE 'UTC')::DATE
  WHERE p.account_id = target_account_id
    AND p.account_role IN ('owner', 'admin', 'agent')
    AND COALESCE(c.assigned_count, 0) < v_rule.daily_capacity
    AND (
      v_rule.team_id IS NULL
      OR EXISTS (
        SELECT 1 FROM public.team_members tm
        WHERE tm.account_id = target_account_id
          AND tm.team_id = v_rule.team_id
          AND tm.user_id = p.user_id
          AND tm.ended_at IS NULL
      )
    )
  ORDER BY COALESCE(c.assigned_count, 0), c.last_assigned_at NULLS FIRST, p.created_at
  LIMIT 1;

  IF v_owner IS NULL THEN
    RETURN QUERY SELECT NULL::UUID, COALESCE(v_rule.queue_key, 'unassigned'), v_rule.id;
    RETURN;
  END IF;

  v_owner := public.resolve_delegated_user(target_account_id, v_owner, 'new_leads', at_time);

  INSERT INTO public.lead_assignment_counters (
    account_id, rule_id, user_id, assignment_date, assigned_count, last_assigned_at
  ) VALUES (
    target_account_id,
    v_rule.id,
    v_owner,
    (at_time AT TIME ZONE 'UTC')::DATE,
    1,
    at_time
  )
  ON CONFLICT (rule_id, user_id, assignment_date) DO UPDATE
  SET assigned_count = public.lead_assignment_counters.assigned_count + 1,
      last_assigned_at = EXCLUDED.last_assigned_at;

  UPDATE public.lead_distribution_rules
  SET last_assigned_at = at_time
  WHERE id = v_rule.id;

  RETURN QUERY SELECT v_owner, NULL::TEXT, v_rule.id;
END;
$$;

ALTER FUNCTION public.select_lead_assignment(UUID, UUID, UUID, TIMESTAMPTZ) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.select_lead_assignment(UUID, UUID, UUID, TIMESTAMPTZ)
  FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.intake_lead(
  p_account_id UUID,
  p_phone TEXT,
  p_name TEXT DEFAULT NULL,
  p_email TEXT DEFAULT NULL,
  p_company TEXT DEFAULT NULL,
  p_source_code TEXT DEFAULT 'manual',
  p_external_key TEXT DEFAULT NULL,
  p_requested_owner_id UUID DEFAULT NULL,
  p_source_detail JSONB DEFAULT '{}'::jsonb,
  p_first_response_minutes INTEGER DEFAULT 60,
  p_create_first_task BOOLEAN DEFAULT true,
  p_reopen_disqualified BOOLEAN DEFAULT false,
  p_created_by UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor UUID := COALESCE(auth.uid(), p_created_by);
  v_phone_normalized TEXT := regexp_replace(COALESCE(p_phone, ''), '\D', '', 'g');
  v_source_code TEXT := lower(btrim(COALESCE(p_source_code, 'manual')));
  v_source_id UUID;
  v_contact public.contacts%ROWTYPE;
  v_lead public.leads%ROWTYPE;
  v_owner UUID;
  v_queue TEXT;
  v_rule UUID;
  v_task_id UUID;
  v_lead_created BOOLEAN := false;
  v_contact_created BOOLEAN := false;
  v_now TIMESTAMPTZ := NOW();
BEGIN
  IF current_user = 'authenticated'
     AND NOT public.has_account_capability(p_account_id, 'lead.create')
  THEN
    RAISE EXCEPTION 'Missing lead.create capability'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_actor IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.account_id = p_account_id AND p.user_id = v_actor
  ) THEN
    RAISE EXCEPTION 'A valid account member is required as created_by'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF length(v_phone_normalized) < 8 OR length(v_phone_normalized) > 15 THEN
    RAISE EXCEPTION 'Phone must contain between 8 and 15 digits'
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_source_code !~ '^[a-z0-9][a-z0-9_-]{0,63}$' THEN
    RAISE EXCEPTION 'Invalid source code' USING ERRCODE = 'check_violation';
  END IF;

  IF p_first_response_minutes < 1 OR p_first_response_minutes > 10080 THEN
    RAISE EXCEPTION 'first_response_minutes must be between 1 and 10080'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Serialize all intake for one account/phone pair. This protects both the
  -- contact and active-lead find-or-create paths from concurrent webhooks.
  PERFORM pg_advisory_xact_lock(hashtext(p_account_id::TEXT || ':' || v_phone_normalized));

  IF p_external_key IS NOT NULL THEN
    SELECT * INTO v_lead
    FROM public.leads
    WHERE account_id = p_account_id AND external_key = p_external_key
    LIMIT 1;

    IF FOUND THEN
      SELECT * INTO v_contact FROM public.contacts WHERE id = v_lead.contact_id;
      SELECT t.id INTO v_task_id
      FROM public.tasks t
      WHERE t.account_id = p_account_id
        AND t.lead_id = v_lead.id
        AND t.status IN ('open', 'in_progress')
      ORDER BY t.due_at
      LIMIT 1;

      RETURN jsonb_build_object(
        'contact_id', v_contact.id,
        'lead_id', v_lead.id,
        'task_id', v_task_id,
        'contact_created', false,
        'lead_created', false,
        'idempotent_replay', true
      );
    END IF;
  END IF;

  INSERT INTO public.lead_sources (account_id, code, name, is_system)
  VALUES (p_account_id, v_source_code, initcap(replace(v_source_code, '_', ' ')), false)
  ON CONFLICT (account_id, code) DO UPDATE SET is_active = true
  RETURNING id INTO v_source_id;

  SELECT * INTO v_contact
  FROM public.contacts
  WHERE account_id = p_account_id AND phone_normalized = v_phone_normalized
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.contacts (
      user_id, account_id, phone, name, email, company, company_name, created_by
    ) VALUES (
      v_actor, p_account_id, p_phone, NULLIF(btrim(p_name), ''),
      NULLIF(lower(btrim(p_email)), ''), NULLIF(btrim(p_company), ''),
      NULLIF(btrim(p_company), ''), v_actor
    )
    RETURNING * INTO v_contact;
    v_contact_created := true;
  ELSE
    UPDATE public.contacts
    SET name = COALESCE(NULLIF(name, ''), NULLIF(btrim(p_name), '')),
        email = COALESCE(NULLIF(email, ''), NULLIF(lower(btrim(p_email)), '')),
        company = COALESCE(NULLIF(company, ''), NULLIF(btrim(p_company), '')),
        company_name = COALESCE(NULLIF(company_name, ''), NULLIF(btrim(p_company), '')),
        archived_at = NULL,
        archived_by = NULL,
        archive_reason = NULL,
        updated_at = v_now
    WHERE id = v_contact.id
    RETURNING * INTO v_contact;
  END IF;

  SELECT * INTO v_lead
  FROM public.leads
  WHERE account_id = p_account_id
    AND contact_id = v_contact.id
    AND archived_at IS NULL
    AND status NOT IN ('converted', 'disqualified')
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  SELECT a.owner_id, a.queue_key, a.rule_id
  INTO v_owner, v_queue, v_rule
  FROM public.select_lead_assignment(
    p_account_id, v_source_id, p_requested_owner_id, v_now
  ) a;

  IF NOT FOUND AND p_reopen_disqualified THEN
    SELECT * INTO v_lead
    FROM public.leads
    WHERE account_id = p_account_id
      AND contact_id = v_contact.id
      AND status = 'disqualified'
      AND archived_at IS NULL
    ORDER BY disqualified_at DESC NULLS LAST, created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      UPDATE public.leads
      SET status = 'reopened',
          owner_id = v_owner,
          assigned_by = v_actor,
          queue_key = v_queue,
          source_id = v_source_id,
          source_detail = source_detail || COALESCE(p_source_detail, '{}'::jsonb),
          first_response_due_at = v_now + make_interval(mins => p_first_response_minutes),
          external_key = COALESCE(external_key, p_external_key),
          updated_at = v_now
      WHERE id = v_lead.id
      RETURNING * INTO v_lead;
    END IF;
  END IF;

  IF v_lead.id IS NULL THEN
    INSERT INTO public.leads (
      account_id, contact_id, source_id, owner_id, assigned_by, queue_key,
      status, priority, source_detail, first_response_due_at,
      external_key, created_by, created_at, updated_at
    ) VALUES (
      p_account_id, v_contact.id, v_source_id, v_owner, v_actor, v_queue,
      CASE WHEN v_owner IS NULL THEN 'new'::lead_status_enum ELSE 'assigned'::lead_status_enum END,
      'normal'::crm_priority_enum,
      COALESCE(p_source_detail, '{}'::jsonb) || jsonb_build_object('distribution_rule_id', v_rule),
      v_now + make_interval(mins => p_first_response_minutes),
      p_external_key, v_actor, v_now, v_now
    )
    RETURNING * INTO v_lead;
    v_lead_created := true;
  ELSE
    UPDATE public.leads
    SET owner_id = COALESCE(owner_id, v_owner),
        assigned_by = CASE WHEN owner_id IS NULL AND v_owner IS NOT NULL THEN v_actor ELSE assigned_by END,
        queue_key = CASE WHEN owner_id IS NULL THEN COALESCE(v_queue, queue_key) ELSE queue_key END,
        status = CASE WHEN status = 'new' AND v_owner IS NOT NULL THEN 'assigned'::lead_status_enum ELSE status END,
        source_detail = source_detail || COALESCE(p_source_detail, '{}'::jsonb),
        external_key = COALESCE(external_key, p_external_key),
        updated_at = v_now
    WHERE id = v_lead.id
    RETURNING * INTO v_lead;
  END IF;

  IF p_create_first_task AND v_lead.owner_id IS NOT NULL THEN
    SELECT id INTO v_task_id
    FROM public.tasks
    WHERE account_id = p_account_id
      AND lead_id = v_lead.id
      AND status IN ('open', 'in_progress')
    ORDER BY due_at
    LIMIT 1;

    IF v_task_id IS NULL THEN
      INSERT INTO public.tasks (
        account_id, contact_id, lead_id, assigned_to, created_by,
        task_type, title, description, priority, status, due_at
      ) VALUES (
        p_account_id,
        v_contact.id,
        v_lead.id,
        v_lead.owner_id,
        v_actor,
        'qualification',
        'First contact',
        'Make the first contact and record the outcome.',
        CASE WHEN p_first_response_minutes <= 30 THEN 'high'::crm_priority_enum ELSE 'normal'::crm_priority_enum END,
        'open',
        v_lead.first_response_due_at
      )
      RETURNING id INTO v_task_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'contact_id', v_contact.id,
    'lead_id', v_lead.id,
    'task_id', v_task_id,
    'owner_id', v_lead.owner_id,
    'queue_key', v_lead.queue_key,
    'contact_created', v_contact_created,
    'lead_created', v_lead_created,
    'idempotent_replay', false
  );
END;
$$;

ALTER FUNCTION public.intake_lead(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, JSONB,
  INTEGER, BOOLEAN, BOOLEAN, UUID
) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.intake_lead(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, JSONB,
  INTEGER, BOOLEAN, BOOLEAN, UUID
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.intake_lead(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, JSONB,
  INTEGER, BOOLEAN, BOOLEAN, UUID
) TO authenticated, service_role;

-- ============================================================
-- RLS / AUDIT
-- ============================================================
ALTER TABLE public.lead_distribution_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lead_assignment_counters ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lead_distribution_rules_select ON public.lead_distribution_rules;
DROP POLICY IF EXISTS lead_distribution_rules_insert ON public.lead_distribution_rules;
DROP POLICY IF EXISTS lead_distribution_rules_update ON public.lead_distribution_rules;
DROP POLICY IF EXISTS lead_distribution_rules_delete ON public.lead_distribution_rules;
CREATE POLICY lead_distribution_rules_select ON public.lead_distribution_rules FOR SELECT
  USING (public.is_account_member(account_id));
CREATE POLICY lead_distribution_rules_insert ON public.lead_distribution_rules FOR INSERT
  WITH CHECK (public.has_account_capability(account_id, 'account.settings'));
CREATE POLICY lead_distribution_rules_update ON public.lead_distribution_rules FOR UPDATE
  USING (public.has_account_capability(account_id, 'account.settings'))
  WITH CHECK (public.has_account_capability(account_id, 'account.settings'));

DROP POLICY IF EXISTS lead_assignment_counters_select ON public.lead_assignment_counters;
CREATE POLICY lead_assignment_counters_select ON public.lead_assignment_counters FOR SELECT
  USING (
    user_id = auth.uid()
    OR public.has_account_capability(account_id, 'report.view')
  );

GRANT SELECT, INSERT, UPDATE ON public.lead_distribution_rules TO authenticated;
GRANT SELECT ON public.lead_assignment_counters TO authenticated;
REVOKE DELETE ON public.lead_distribution_rules FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.lead_assignment_counters FROM authenticated;

DROP TRIGGER IF EXISTS set_updated_at ON public.lead_distribution_rules;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.lead_distribution_rules
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
DROP TRIGGER IF EXISTS capture_lead_distribution_domain_event ON public.lead_distribution_rules;
CREATE TRIGGER capture_lead_distribution_domain_event
  AFTER INSERT OR UPDATE ON public.lead_distribution_rules
  FOR EACH ROW EXECUTE FUNCTION public.capture_crm_domain_event();

COMMENT ON FUNCTION public.intake_lead(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, JSONB,
  INTEGER, BOOLEAN, BOOLEAN, UUID
) IS 'Transactional CRM lead capture with contact dedupe, assignment, SLA and first task.';

COMMIT;
