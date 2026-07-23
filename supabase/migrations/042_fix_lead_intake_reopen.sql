-- ============================================================
-- 042_fix_lead_intake_reopen.sql
--
-- PostgreSQL's FOUND flag is changed by every SELECT. Migration 041 selected
-- the distribution decision after looking for an active lead, so the later
-- reopen branch observed the assignment SELECT instead of the lead lookup.
-- Keep an explicit boolean and replace the function atomically.
-- ============================================================

BEGIN;

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
  v_active_lead_found BOOLEAN := false;
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
  v_active_lead_found := FOUND;

  SELECT a.owner_id, a.queue_key, a.rule_id
  INTO v_owner, v_queue, v_rule
  FROM public.select_lead_assignment(
    p_account_id, v_source_id, p_requested_owner_id, v_now
  ) a;

  IF NOT v_active_lead_found AND p_reopen_disqualified THEN
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

COMMIT;
