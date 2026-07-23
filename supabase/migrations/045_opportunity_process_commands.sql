-- ============================================================
-- 045_opportunity_process_commands.sql
--
-- Makes pipeline stages semantic and opportunity movement transactional.
-- Stage and commercial lifecycle are separate: moving through open stages
-- preserves status=open; terminal commands set won/lost with audit metadata.
-- ============================================================

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pipeline_stage_kind_enum') THEN
    CREATE TYPE pipeline_stage_kind_enum AS ENUM ('open', 'won', 'lost');
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_pipelines_account_id_id
  ON public.pipelines(account_id, id);

ALTER TABLE public.pipeline_stages
  ADD COLUMN IF NOT EXISTS account_id UUID,
  ADD COLUMN IF NOT EXISTS stage_kind pipeline_stage_kind_enum NOT NULL DEFAULT 'open',
  ADD COLUMN IF NOT EXISTS default_probability SMALLINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS requires_next_task BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

UPDATE public.pipeline_stages s
SET account_id = p.account_id
FROM public.pipelines p
WHERE p.id = s.pipeline_id AND s.account_id IS NULL;

UPDATE public.pipeline_stages
SET stage_kind = CASE
      WHEN lower(name) IN ('won', 'ganho', 'ganha', 'fechado ganho') THEN 'won'::pipeline_stage_kind_enum
      WHEN lower(name) IN ('lost', 'perdido', 'perdida', 'fechado perdido') THEN 'lost'::pipeline_stage_kind_enum
      ELSE 'open'::pipeline_stage_kind_enum
    END,
    default_probability = CASE
      WHEN lower(name) IN ('won', 'ganho', 'ganha', 'fechado ganho') THEN 100
      WHEN lower(name) IN ('lost', 'perdido', 'perdida', 'fechado perdido') THEN 0
      WHEN position <= 0 THEN 10
      ELSE LEAST(90, 10 + position * 15)
    END,
    requires_next_task = CASE
      WHEN lower(name) IN (
        'won', 'ganho', 'ganha', 'fechado ganho',
        'lost', 'perdido', 'perdida', 'fechado perdido'
      ) THEN false
      ELSE true
    END;

ALTER TABLE public.pipeline_stages ALTER COLUMN account_id SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pipeline_stages_account_pipeline_fkey') THEN
    ALTER TABLE public.pipeline_stages
      ADD CONSTRAINT pipeline_stages_account_pipeline_fkey
      FOREIGN KEY (account_id, pipeline_id)
      REFERENCES public.pipelines(account_id, id) ON DELETE CASCADE;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pipeline_stage_probability_check') THEN
    ALTER TABLE public.pipeline_stages
      ADD CONSTRAINT pipeline_stage_probability_check
      CHECK (default_probability BETWEEN 0 AND 100);
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_pipeline_stages_account_id_id
  ON public.pipeline_stages(account_id, id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_pipeline_single_won_stage
  ON public.pipeline_stages(pipeline_id)
  WHERE stage_kind = 'won';
CREATE UNIQUE INDEX IF NOT EXISTS uq_pipeline_single_lost_stage
  ON public.pipeline_stages(pipeline_id)
  WHERE stage_kind = 'lost';

-- Normalize legacy lifecycle values before enforcing the contract.
UPDATE public.deals SET status = 'open' WHERE status IS NULL OR status = 'active';
ALTER TABLE public.deals DROP CONSTRAINT IF EXISTS deals_status_check;
ALTER TABLE public.deals
  ADD CONSTRAINT deals_status_check CHECK (status IN ('open', 'won', 'lost', 'cancelled'));

CREATE TABLE IF NOT EXISTS public.opportunity_stage_history (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  opportunity_id UUID NOT NULL,
  from_stage_id UUID,
  to_stage_id UUID NOT NULL,
  from_status TEXT,
  to_status TEXT NOT NULL,
  changed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  reason TEXT,
  changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT opportunity_history_deal_fkey
    FOREIGN KEY (account_id, opportunity_id)
    REFERENCES public.deals(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT opportunity_history_from_stage_fkey
    FOREIGN KEY (account_id, from_stage_id)
    REFERENCES public.pipeline_stages(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT opportunity_history_to_stage_fkey
    FOREIGN KEY (account_id, to_stage_id)
    REFERENCES public.pipeline_stages(account_id, id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_opportunity_stage_history
  ON public.opportunity_stage_history(account_id, opportunity_id, changed_at DESC);

-- Existing open opportunities receive a first follow-up so the new invariant
-- does not strand legacy records without an actionable next step.
INSERT INTO public.tasks (
  account_id, contact_id, lead_id, opportunity_id, conversation_id,
  assigned_to, created_by, task_type, title, description, priority,
  status, due_at
)
SELECT
  d.account_id,
  d.contact_id,
  d.lead_id,
  d.id,
  d.conversation_id,
  COALESCE(d.assigned_to, d.user_id),
  d.user_id,
  'follow_up',
  'Opportunity follow-up',
  'Review the opportunity and define the next commercial action.',
  'normal',
  'open',
  NOW() + INTERVAL '1 day'
FROM public.deals d
WHERE d.status = 'open'
  AND d.archived_at IS NULL
  AND d.contact_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.tasks t
    WHERE t.account_id = d.account_id
      AND t.opportunity_id = d.id
      AND t.status IN ('open', 'in_progress')
      AND t.archived_at IS NULL
  );

-- Browser clients may edit descriptive fields but lifecycle/stage changes must
-- use the commands below. Service role/postgres is supervised separately.
CREATE OR REPLACE FUNCTION public.enforce_opportunity_command_columns()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF current_user = 'authenticated' AND (
    NEW.stage_id IS DISTINCT FROM OLD.stage_id
    OR NEW.status IS DISTINCT FROM OLD.status
    OR NEW.probability IS DISTINCT FROM OLD.probability
    OR NEW.won_at IS DISTINCT FROM OLD.won_at
    OR NEW.lost_at IS DISTINCT FROM OLD.lost_at
    OR NEW.loss_reason_id IS DISTINCT FROM OLD.loss_reason_id
    OR NEW.closed_by IS DISTINCT FROM OLD.closed_by
    OR NEW.archived_at IS DISTINCT FROM OLD.archived_at
  ) THEN
    RAISE EXCEPTION 'Use opportunity process commands for stage and lifecycle changes'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_opportunity_command_columns ON public.deals;
CREATE TRIGGER enforce_opportunity_command_columns
  BEFORE UPDATE OF stage_id, status, probability, won_at, lost_at,
    loss_reason_id, closed_by, archived_at
  ON public.deals
  FOR EACH ROW EXECUTE FUNCTION public.enforce_opportunity_command_columns();

CREATE OR REPLACE FUNCTION public.resolve_opportunity_actor(
  target_account_id UUID,
  requested_actor UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor UUID := COALESCE(auth.uid(), requested_actor);
BEGIN
  IF v_actor IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.account_id = target_account_id AND p.user_id = v_actor
  ) THEN
    RAISE EXCEPTION 'A valid account member is required as actor'
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN v_actor;
END;
$$;

ALTER FUNCTION public.resolve_opportunity_actor(UUID, UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.resolve_opportunity_actor(UUID, UUID) FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.record_opportunity_movement(
  p_deal public.deals,
  p_from_stage UUID,
  p_from_status TEXT,
  p_actor UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.opportunity_stage_history (
    account_id, opportunity_id, from_stage_id, to_stage_id,
    from_status, to_status, changed_by, reason
  ) VALUES (
    p_deal.account_id, p_deal.id, p_from_stage, p_deal.stage_id,
    p_from_status, p_deal.status, p_actor, NULLIF(btrim(p_reason), '')
  );

  IF p_deal.contact_id IS NOT NULL THEN
    INSERT INTO public.activities (
      account_id, contact_id, lead_id, opportunity_id, conversation_id,
      activity_type, summary, outcome, occurred_at, performed_by, source,
      metadata
    ) VALUES (
      p_deal.account_id, p_deal.contact_id, p_deal.lead_id, p_deal.id,
      p_deal.conversation_id, 'stage_change', 'Opportunity process updated',
      NULLIF(btrim(p_reason), ''), NOW(), p_actor, 'human',
      jsonb_build_object(
        'from_stage_id', p_from_stage,
        'to_stage_id', p_deal.stage_id,
        'from_status', p_from_status,
        'to_status', p_deal.status
      )
    );
  END IF;
END;
$$;

ALTER FUNCTION public.record_opportunity_movement(public.deals, UUID, TEXT, UUID, TEXT)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION public.record_opportunity_movement(public.deals, UUID, TEXT, UUID, TEXT)
  FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.move_opportunity(
  p_opportunity_id UUID,
  p_stage_id UUID,
  p_next_task_title TEXT DEFAULT NULL,
  p_next_task_due_at TIMESTAMPTZ DEFAULT NULL,
  p_actor UUID DEFAULT NULL
)
RETURNS public.deals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deal public.deals%ROWTYPE;
  v_stage public.pipeline_stages%ROWTYPE;
  v_from_stage UUID;
  v_from_status TEXT;
  v_actor UUID;
BEGIN
  SELECT * INTO v_deal FROM public.deals WHERE id = p_opportunity_id FOR UPDATE;
  IF NOT FOUND OR NOT public.has_account_capability(v_deal.account_id, 'opportunity.update') THEN
    RAISE EXCEPTION 'Opportunity not found or access denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_deal.status <> 'open' THEN
    RAISE EXCEPTION 'Closed opportunities must be reopened explicitly'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_stage
  FROM public.pipeline_stages
  WHERE id = p_stage_id
    AND account_id = v_deal.account_id
    AND pipeline_id = v_deal.pipeline_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Target stage does not belong to the opportunity pipeline'
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF v_stage.stage_kind = 'lost' THEN
    RAISE EXCEPTION 'Use close_opportunity_lost and provide a loss reason'
      USING ERRCODE = 'check_violation';
  END IF;

  v_actor := public.resolve_opportunity_actor(v_deal.account_id, p_actor);
  v_from_stage := v_deal.stage_id;
  v_from_status := v_deal.status;

  IF v_stage.stage_kind = 'won' THEN
    IF NOT public.has_account_capability(v_deal.account_id, 'opportunity.close') THEN
      RAISE EXCEPTION 'Missing opportunity.close capability'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    UPDATE public.deals
    SET stage_id = v_stage.id,
        status = 'won',
        probability = 100,
        won_at = NOW(),
        lost_at = NULL,
        loss_reason_id = NULL,
        closed_by = v_actor,
        last_stage_changed_at = NOW(),
        updated_at = NOW()
    WHERE id = v_deal.id
    RETURNING * INTO v_deal;

    UPDATE public.tasks
    SET status = 'cancelled', cancelled_at = NOW(),
        cancellation_reason = 'Opportunity won', archived_at = NOW()
    WHERE account_id = v_deal.account_id
      AND opportunity_id = v_deal.id
      AND status IN ('open', 'in_progress');
  ELSE
    IF p_next_task_due_at IS NOT NULL THEN
      IF NULLIF(btrim(p_next_task_title), '') IS NULL THEN
        RAISE EXCEPTION 'next_task_title is required when next_task_due_at is provided'
          USING ERRCODE = 'check_violation';
      END IF;
      INSERT INTO public.tasks (
        account_id, contact_id, lead_id, opportunity_id, conversation_id,
        assigned_to, created_by, task_type, title, priority, status, due_at
      ) VALUES (
        v_deal.account_id, v_deal.contact_id, v_deal.lead_id, v_deal.id,
        v_deal.conversation_id, COALESCE(v_deal.assigned_to, v_actor), v_actor,
        'follow_up', btrim(p_next_task_title), 'normal', 'open', p_next_task_due_at
      );
    END IF;

    IF v_stage.requires_next_task AND NOT EXISTS (
      SELECT 1 FROM public.tasks t
      WHERE t.account_id = v_deal.account_id
        AND t.opportunity_id = v_deal.id
        AND t.status IN ('open', 'in_progress')
        AND t.archived_at IS NULL
    ) THEN
      RAISE EXCEPTION 'Open opportunity stages require a next task'
        USING ERRCODE = 'check_violation';
    END IF;

    UPDATE public.deals
    SET stage_id = v_stage.id,
        probability = LEAST(99, v_stage.default_probability),
        last_stage_changed_at = NOW(),
        updated_at = NOW()
    WHERE id = v_deal.id
    RETURNING * INTO v_deal;
  END IF;

  PERFORM public.record_opportunity_movement(
    v_deal, v_from_stage, v_from_status, v_actor,
    CASE WHEN v_stage.stage_kind = 'won' THEN 'Opportunity won' ELSE 'Stage changed' END
  );
  RETURN v_deal;
END;
$$;

ALTER FUNCTION public.move_opportunity(UUID, UUID, TEXT, TIMESTAMPTZ, UUID)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION public.move_opportunity(UUID, UUID, TEXT, TIMESTAMPTZ, UUID)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.move_opportunity(UUID, UUID, TEXT, TIMESTAMPTZ, UUID)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.close_opportunity_lost(
  p_opportunity_id UUID,
  p_loss_reason_id UUID,
  p_stage_id UUID DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_actor UUID DEFAULT NULL
)
RETURNS public.deals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deal public.deals%ROWTYPE;
  v_stage public.pipeline_stages%ROWTYPE;
  v_from_stage UUID;
  v_from_status TEXT;
  v_actor UUID;
BEGIN
  SELECT * INTO v_deal FROM public.deals WHERE id = p_opportunity_id FOR UPDATE;
  IF NOT FOUND OR NOT public.has_account_capability(v_deal.account_id, 'opportunity.close') THEN
    RAISE EXCEPTION 'Opportunity not found or closing denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_deal.status <> 'open' THEN
    RAISE EXCEPTION 'Only open opportunities can be lost'
      USING ERRCODE = 'check_violation';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.opportunity_loss_reasons r
    WHERE r.account_id = v_deal.account_id AND r.id = p_loss_reason_id AND r.is_active
  ) THEN
    RAISE EXCEPTION 'A valid active loss reason is required'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF p_stage_id IS NULL THEN
    SELECT * INTO v_stage
    FROM public.pipeline_stages
    WHERE pipeline_id = v_deal.pipeline_id AND stage_kind = 'lost'
    LIMIT 1;
  ELSE
    SELECT * INTO v_stage
    FROM public.pipeline_stages
    WHERE id = p_stage_id
      AND account_id = v_deal.account_id
      AND pipeline_id = v_deal.pipeline_id
      AND stage_kind = 'lost';
  END IF;

  v_actor := public.resolve_opportunity_actor(v_deal.account_id, p_actor);
  v_from_stage := v_deal.stage_id;
  v_from_status := v_deal.status;

  UPDATE public.deals
  SET stage_id = COALESCE(v_stage.id, stage_id),
      status = 'lost', probability = 0,
      lost_at = NOW(), won_at = NULL,
      loss_reason_id = p_loss_reason_id,
      closed_by = v_actor,
      last_stage_changed_at = CASE WHEN v_stage.id IS NULL THEN last_stage_changed_at ELSE NOW() END,
      notes = COALESCE(NULLIF(btrim(p_notes), ''), notes),
      updated_at = NOW()
  WHERE id = v_deal.id
  RETURNING * INTO v_deal;

  UPDATE public.tasks
  SET status = 'cancelled', cancelled_at = NOW(),
      cancellation_reason = 'Opportunity lost', archived_at = NOW()
  WHERE account_id = v_deal.account_id
    AND opportunity_id = v_deal.id
    AND status IN ('open', 'in_progress');

  PERFORM public.record_opportunity_movement(
    v_deal, v_from_stage, v_from_status, v_actor, COALESCE(p_notes, 'Opportunity lost')
  );
  RETURN v_deal;
END;
$$;

ALTER FUNCTION public.close_opportunity_lost(UUID, UUID, UUID, TEXT, UUID)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION public.close_opportunity_lost(UUID, UUID, UUID, TEXT, UUID)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.close_opportunity_lost(UUID, UUID, UUID, TEXT, UUID)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.reopen_opportunity(
  p_opportunity_id UUID,
  p_stage_id UUID,
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
  v_deal public.deals%ROWTYPE;
  v_stage public.pipeline_stages%ROWTYPE;
  v_from_stage UUID;
  v_from_status TEXT;
  v_actor UUID;
BEGIN
  SELECT * INTO v_deal FROM public.deals WHERE id = p_opportunity_id FOR UPDATE;
  IF NOT FOUND OR NOT public.has_account_capability(v_deal.account_id, 'opportunity.close') THEN
    RAISE EXCEPTION 'Opportunity not found or reopening denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_deal.status NOT IN ('won', 'lost') THEN
    RAISE EXCEPTION 'Only won or lost opportunities can be reopened'
      USING ERRCODE = 'check_violation';
  END IF;
  IF NULLIF(btrim(p_next_task_title), '') IS NULL OR p_next_task_due_at IS NULL THEN
    RAISE EXCEPTION 'Reopening requires a next task and due date'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_stage
  FROM public.pipeline_stages
  WHERE id = p_stage_id
    AND account_id = v_deal.account_id
    AND pipeline_id = v_deal.pipeline_id
    AND stage_kind = 'open';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reopen stage must be an open stage in the same pipeline'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  v_actor := public.resolve_opportunity_actor(v_deal.account_id, p_actor);
  v_from_stage := v_deal.stage_id;
  v_from_status := v_deal.status;

  UPDATE public.deals
  SET stage_id = v_stage.id,
      status = 'open',
      probability = LEAST(99, v_stage.default_probability),
      won_at = NULL, lost_at = NULL,
      loss_reason_id = NULL, closed_by = NULL,
      last_stage_changed_at = NOW(), updated_at = NOW()
  WHERE id = v_deal.id
  RETURNING * INTO v_deal;

  INSERT INTO public.tasks (
    account_id, contact_id, lead_id, opportunity_id, conversation_id,
    assigned_to, created_by, task_type, title, priority, status, due_at
  ) VALUES (
    v_deal.account_id, v_deal.contact_id, v_deal.lead_id, v_deal.id,
    v_deal.conversation_id, COALESCE(v_deal.assigned_to, v_actor), v_actor,
    'follow_up', btrim(p_next_task_title), 'high', 'open', p_next_task_due_at
  );

  PERFORM public.record_opportunity_movement(
    v_deal, v_from_stage, v_from_status, v_actor, 'Opportunity reopened'
  );
  RETURN v_deal;
END;
$$;

ALTER FUNCTION public.reopen_opportunity(UUID, UUID, TEXT, TIMESTAMPTZ, UUID)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reopen_opportunity(UUID, UUID, TEXT, TIMESTAMPTZ, UUID)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reopen_opportunity(UUID, UUID, TEXT, TIMESTAMPTZ, UUID)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.archive_opportunity(
  p_opportunity_id UUID,
  p_reason TEXT,
  p_actor UUID DEFAULT NULL
)
RETURNS public.deals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deal public.deals%ROWTYPE;
  v_actor UUID;
BEGIN
  IF NULLIF(btrim(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Archive reason is required' USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO v_deal FROM public.deals WHERE id = p_opportunity_id FOR UPDATE;
  IF NOT FOUND OR NOT public.has_account_capability(v_deal.account_id, 'opportunity.update') THEN
    RAISE EXCEPTION 'Opportunity not found or access denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  v_actor := public.resolve_opportunity_actor(v_deal.account_id, p_actor);

  UPDATE public.deals
  SET archived_at = COALESCE(archived_at, NOW()), updated_at = NOW()
  WHERE id = v_deal.id
  RETURNING * INTO v_deal;

  UPDATE public.tasks
  SET status = 'cancelled', cancelled_at = NOW(),
      cancellation_reason = 'Opportunity archived: ' || btrim(p_reason),
      archived_at = NOW()
  WHERE account_id = v_deal.account_id
    AND opportunity_id = v_deal.id
    AND status IN ('open', 'in_progress');

  IF v_deal.contact_id IS NOT NULL THEN
    INSERT INTO public.activities (
      account_id, contact_id, lead_id, opportunity_id, conversation_id,
      activity_type, summary, outcome, occurred_at, performed_by, source
    ) VALUES (
      v_deal.account_id, v_deal.contact_id, v_deal.lead_id, v_deal.id,
      v_deal.conversation_id, 'system', 'Opportunity archived', btrim(p_reason),
      NOW(), v_actor, 'human'
    );
  END IF;
  RETURN v_deal;
END;
$$;

ALTER FUNCTION public.archive_opportunity(UUID, TEXT, UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.archive_opportunity(UUID, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.archive_opportunity(UUID, TEXT, UUID)
  TO authenticated, service_role;

-- Hard delete is removed from normal product operations.
DROP POLICY IF EXISTS deals_delete ON public.deals;
REVOKE DELETE ON public.deals FROM authenticated;

ALTER TABLE public.opportunity_stage_history ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS opportunity_stage_history_select ON public.opportunity_stage_history;
CREATE POLICY opportunity_stage_history_select ON public.opportunity_stage_history FOR SELECT
  USING (public.is_account_member(account_id));
GRANT SELECT ON public.opportunity_stage_history TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.opportunity_stage_history FROM authenticated;

DROP TRIGGER IF EXISTS set_updated_at ON public.pipeline_stages;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.pipeline_stages
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

COMMENT ON TABLE public.opportunity_stage_history IS
  'Immutable movement history for opportunities. Writes occur only through process commands.';

COMMIT;
