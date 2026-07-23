-- ============================================================
-- 046_convert_lead_to_opportunity.sql
--
-- Converts one qualified lead into one opportunity, updates lead lifecycle,
-- records history and creates the mandatory next task in one transaction.
-- ============================================================

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS uq_deals_one_active_per_lead
  ON public.deals(account_id, lead_id)
  WHERE lead_id IS NOT NULL AND archived_at IS NULL;

CREATE OR REPLACE FUNCTION public.convert_lead_to_opportunity(
  p_lead_id UUID,
  p_pipeline_id UUID,
  p_stage_id UUID,
  p_title TEXT,
  p_value NUMERIC,
  p_currency TEXT,
  p_expected_close_date DATE,
  p_next_task_title TEXT,
  p_next_task_due_at TIMESTAMPTZ,
  p_actor UUID DEFAULT NULL
)
RETURNS public.deals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_lead public.leads%ROWTYPE;
  v_stage public.pipeline_stages%ROWTYPE;
  v_deal public.deals%ROWTYPE;
  v_actor UUID;
BEGIN
  SELECT * INTO v_lead FROM public.leads WHERE id = p_lead_id FOR UPDATE;
  IF NOT FOUND OR NOT public.has_account_capability(v_lead.account_id, 'lead.convert') THEN
    RAISE EXCEPTION 'Lead not found or conversion denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_lead.status <> 'qualified' THEN
    RAISE EXCEPTION 'Only qualified leads can be converted'
      USING ERRCODE = 'check_violation';
  END IF;
  IF NULLIF(btrim(p_title), '') IS NULL THEN
    RAISE EXCEPTION 'Opportunity title is required' USING ERRCODE = 'check_violation';
  END IF;
  IF NULLIF(btrim(p_next_task_title), '') IS NULL OR p_next_task_due_at IS NULL THEN
    RAISE EXCEPTION 'Conversion requires a next task and due date'
      USING ERRCODE = 'check_violation';
  END IF;
  IF p_value < 0 THEN
    RAISE EXCEPTION 'Opportunity value cannot be negative'
      USING ERRCODE = 'check_violation';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.deals d
    WHERE d.account_id = v_lead.account_id
      AND d.lead_id = v_lead.id
      AND d.archived_at IS NULL
  ) THEN
    SELECT * INTO v_deal
    FROM public.deals d
    WHERE d.account_id = v_lead.account_id
      AND d.lead_id = v_lead.id
      AND d.archived_at IS NULL
    LIMIT 1;
    RETURN v_deal;
  END IF;

  SELECT * INTO v_stage
  FROM public.pipeline_stages
  WHERE id = p_stage_id
    AND account_id = v_lead.account_id
    AND pipeline_id = p_pipeline_id
    AND stage_kind = 'open';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Initial stage must be open and belong to the selected pipeline'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  v_actor := public.resolve_opportunity_actor(v_lead.account_id, p_actor);

  INSERT INTO public.deals (
    user_id, account_id, pipeline_id, stage_id, contact_id, lead_id,
    title, value, currency, expected_close_date, status, probability,
    assigned_to, created_at, updated_at, last_stage_changed_at
  ) VALUES (
    v_actor, v_lead.account_id, p_pipeline_id, p_stage_id, v_lead.contact_id,
    v_lead.id, btrim(p_title), p_value, upper(COALESCE(NULLIF(btrim(p_currency), ''), 'BRL')),
    p_expected_close_date, 'open', LEAST(99, v_stage.default_probability),
    COALESCE(v_lead.owner_id, v_actor), NOW(), NOW(), NOW()
  )
  RETURNING * INTO v_deal;

  UPDATE public.leads
  SET status = 'converted', converted_at = NOW(), updated_at = NOW()
  WHERE id = v_lead.id;

  INSERT INTO public.tasks (
    account_id, contact_id, lead_id, opportunity_id,
    assigned_to, created_by, task_type, title, priority, status, due_at
  ) VALUES (
    v_deal.account_id, v_deal.contact_id, v_lead.id, v_deal.id,
    COALESCE(v_deal.assigned_to, v_actor), v_actor, 'follow_up',
    btrim(p_next_task_title), 'high', 'open', p_next_task_due_at
  );

  INSERT INTO public.opportunity_stage_history (
    account_id, opportunity_id, from_stage_id, to_stage_id,
    from_status, to_status, changed_by, reason
  ) VALUES (
    v_deal.account_id, v_deal.id, NULL, v_deal.stage_id,
    NULL, 'open', v_actor, 'Lead converted to opportunity'
  );

  INSERT INTO public.activities (
    account_id, contact_id, lead_id, opportunity_id,
    activity_type, summary, occurred_at, performed_by, source,
    metadata
  ) VALUES (
    v_deal.account_id, v_deal.contact_id, v_lead.id, v_deal.id,
    'qualification', 'Lead converted to opportunity', NOW(), v_actor, 'human',
    jsonb_build_object('pipeline_id', p_pipeline_id, 'stage_id', p_stage_id)
  );

  RETURN v_deal;
END;
$$;

ALTER FUNCTION public.convert_lead_to_opportunity(
  UUID, UUID, UUID, TEXT, NUMERIC, TEXT, DATE, TEXT, TIMESTAMPTZ, UUID
) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.convert_lead_to_opportunity(
  UUID, UUID, UUID, TEXT, NUMERIC, TEXT, DATE, TEXT, TIMESTAMPTZ, UUID
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.convert_lead_to_opportunity(
  UUID, UUID, UUID, TEXT, NUMERIC, TEXT, DATE, TEXT, TIMESTAMPTZ, UUID
) TO authenticated, service_role;

COMMIT;
