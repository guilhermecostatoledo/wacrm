-- ============================================================
-- 043_task_commands_and_due_notifications.sql
--
-- Transactional task operations. UI/API clients call commands rather than
-- patching state columns directly, so completion, recurrence, activity and
-- notifications remain consistent.
-- ============================================================

BEGIN;

ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS dedupe_key TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS uq_notifications_account_dedupe_key
  ON public.notifications(account_id, dedupe_key)
  WHERE dedupe_key IS NOT NULL;

CREATE OR REPLACE FUNCTION public.validate_crm_recurrence_rule(rule TEXT)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT rule IS NULL
    OR rule ~* '^FREQ=(DAILY|WEEKLY|MONTHLY)(;INTERVAL=[1-9][0-9]{0,2})?$';
$$;

CREATE OR REPLACE FUNCTION public.next_crm_recurrence_due_at(
  current_due_at TIMESTAMPTZ,
  rule TEXT
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  v_frequency TEXT;
  v_interval INTEGER := 1;
  v_match TEXT[];
BEGIN
  SELECT regexp_match(
    upper(rule),
    '^FREQ=(DAILY|WEEKLY|MONTHLY)(?:;INTERVAL=([1-9][0-9]{0,2}))?$'
  ) INTO v_match;

  IF v_match IS NULL THEN
    RAISE EXCEPTION 'Unsupported recurrence rule'
      USING ERRCODE = 'check_violation';
  END IF;

  v_frequency := v_match[1];
  IF v_match[2] IS NOT NULL THEN
    v_interval := v_match[2]::INTEGER;
  END IF;

  RETURN CASE v_frequency
    WHEN 'DAILY' THEN current_due_at + make_interval(days => v_interval)
    WHEN 'WEEKLY' THEN current_due_at + make_interval(days => v_interval * 7)
    WHEN 'MONTHLY' THEN current_due_at + make_interval(months => v_interval)
  END;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'tasks_recurrence_rule_check'
  ) THEN
    ALTER TABLE public.tasks
      ADD CONSTRAINT tasks_recurrence_rule_check
      CHECK (public.validate_crm_recurrence_rule(recurrence_rule));
  END IF;
END $$;

-- Prevent browser clients from bypassing task commands by directly changing
-- lifecycle/assignment columns. SECURITY DEFINER commands run as postgres and
-- are therefore not blocked by this trigger.
CREATE OR REPLACE FUNCTION public.enforce_task_command_columns()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF current_user = 'authenticated' AND (
    NEW.status IS DISTINCT FROM OLD.status
    OR NEW.assigned_to IS DISTINCT FROM OLD.assigned_to
    OR NEW.started_at IS DISTINCT FROM OLD.started_at
    OR NEW.completed_at IS DISTINCT FROM OLD.completed_at
    OR NEW.cancelled_at IS DISTINCT FROM OLD.cancelled_at
    OR NEW.completion_outcome IS DISTINCT FROM OLD.completion_outcome
    OR NEW.cancellation_reason IS DISTINCT FROM OLD.cancellation_reason
    OR NEW.archived_at IS DISTINCT FROM OLD.archived_at
  ) THEN
    RAISE EXCEPTION 'Use CRM task commands for state, assignment and archival changes'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_task_command_columns ON public.tasks;
CREATE TRIGGER enforce_task_command_columns
  BEFORE UPDATE OF status, assigned_to, started_at, completed_at,
    cancelled_at, completion_outcome, cancellation_reason, archived_at
  ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.enforce_task_command_columns();

CREATE OR REPLACE FUNCTION public.create_crm_task(
  p_account_id UUID,
  p_contact_id UUID,
  p_title TEXT,
  p_due_at TIMESTAMPTZ,
  p_assigned_to UUID DEFAULT NULL,
  p_lead_id UUID DEFAULT NULL,
  p_opportunity_id UUID DEFAULT NULL,
  p_conversation_id UUID DEFAULT NULL,
  p_task_type crm_task_type_enum DEFAULT 'follow_up',
  p_description TEXT DEFAULT NULL,
  p_priority crm_priority_enum DEFAULT 'normal',
  p_recurrence_rule TEXT DEFAULT NULL,
  p_created_by UUID DEFAULT NULL
)
RETURNS public.tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor UUID := COALESCE(auth.uid(), p_created_by);
  v_assignee UUID := COALESCE(p_assigned_to, v_actor);
  v_task public.tasks%ROWTYPE;
BEGIN
  IF current_user = 'authenticated'
     AND NOT public.has_account_capability(p_account_id, 'task.create')
  THEN
    RAISE EXCEPTION 'Missing task.create capability'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_actor IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.account_id = p_account_id AND p.user_id = v_actor
  ) THEN
    RAISE EXCEPTION 'A valid account member is required as created_by'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NULLIF(btrim(p_title), '') IS NULL THEN
    RAISE EXCEPTION 'Task title is required' USING ERRCODE = 'check_violation';
  END IF;
  IF p_due_at IS NULL THEN
    RAISE EXCEPTION 'Task due_at is required' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT public.validate_crm_recurrence_rule(p_recurrence_rule) THEN
    RAISE EXCEPTION 'Unsupported recurrence rule' USING ERRCODE = 'check_violation';
  END IF;

  v_assignee := public.resolve_delegated_user(
    p_account_id, v_assignee, 'open_tasks', p_due_at
  );

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.account_id = p_account_id AND p.user_id = v_assignee
  ) THEN
    RAISE EXCEPTION 'Task assignee is not an account member'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_assignee IS DISTINCT FROM v_actor
     AND current_user = 'authenticated'
     AND NOT public.has_account_capability(p_account_id, 'task.delegate')
  THEN
    RAISE EXCEPTION 'Missing task.delegate capability'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  INSERT INTO public.tasks (
    account_id, contact_id, lead_id, opportunity_id, conversation_id,
    assigned_to, created_by, task_type, title, description, priority,
    status, due_at, recurrence_rule
  ) VALUES (
    p_account_id, p_contact_id, p_lead_id, p_opportunity_id, p_conversation_id,
    v_assignee, v_actor, p_task_type, btrim(p_title), NULLIF(btrim(p_description), ''),
    p_priority, 'open', p_due_at, upper(p_recurrence_rule)
  )
  RETURNING * INTO v_task;

  RETURN v_task;
END;
$$;

ALTER FUNCTION public.create_crm_task(
  UUID, UUID, TEXT, TIMESTAMPTZ, UUID, UUID, UUID, UUID,
  crm_task_type_enum, TEXT, crm_priority_enum, TEXT, UUID
) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.create_crm_task(
  UUID, UUID, TEXT, TIMESTAMPTZ, UUID, UUID, UUID, UUID,
  crm_task_type_enum, TEXT, crm_priority_enum, TEXT, UUID
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_crm_task(
  UUID, UUID, TEXT, TIMESTAMPTZ, UUID, UUID, UUID, UUID,
  crm_task_type_enum, TEXT, crm_priority_enum, TEXT, UUID
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.start_crm_task(p_task_id UUID)
RETURNS public.tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task public.tasks%ROWTYPE;
BEGIN
  SELECT * INTO v_task FROM public.tasks WHERE id = p_task_id FOR UPDATE;
  IF NOT FOUND OR NOT public.has_account_capability(v_task.account_id, 'task.update') THEN
    RAISE EXCEPTION 'Task not found or access denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_task.status <> 'open' THEN
    RAISE EXCEPTION 'Only open tasks can be started' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE public.tasks
  SET status = 'in_progress', started_at = COALESCE(started_at, NOW())
  WHERE id = p_task_id
  RETURNING * INTO v_task;
  RETURN v_task;
END;
$$;

ALTER FUNCTION public.start_crm_task(UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.start_crm_task(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_crm_task(UUID) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.complete_crm_task(
  p_task_id UUID,
  p_outcome TEXT,
  p_create_next BOOLEAN DEFAULT true
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task public.tasks%ROWTYPE;
  v_next public.tasks%ROWTYPE;
  v_actor UUID := auth.uid();
  v_next_due TIMESTAMPTZ;
BEGIN
  IF NULLIF(btrim(p_outcome), '') IS NULL THEN
    RAISE EXCEPTION 'Completion outcome is required' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_task FROM public.tasks WHERE id = p_task_id FOR UPDATE;
  IF NOT FOUND OR NOT public.has_account_capability(v_task.account_id, 'task.update') THEN
    RAISE EXCEPTION 'Task not found or access denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_task.status NOT IN ('open', 'in_progress') THEN
    RAISE EXCEPTION 'Only active tasks can be completed' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE public.tasks
  SET status = 'completed',
      completed_at = NOW(),
      completion_outcome = btrim(p_outcome)
  WHERE id = p_task_id
  RETURNING * INTO v_task;

  INSERT INTO public.activities (
    account_id, contact_id, lead_id, opportunity_id, conversation_id,
    activity_type, summary, outcome, occurred_at, performed_by, source,
    metadata
  ) VALUES (
    v_task.account_id, v_task.contact_id, v_task.lead_id,
    v_task.opportunity_id, v_task.conversation_id,
    CASE v_task.task_type
      WHEN 'call' THEN 'call'::crm_activity_type_enum
      WHEN 'whatsapp' THEN 'whatsapp'::crm_activity_type_enum
      WHEN 'email' THEN 'email'::crm_activity_type_enum
      WHEN 'meeting' THEN 'meeting'::crm_activity_type_enum
      WHEN 'visit' THEN 'visit'::crm_activity_type_enum
      WHEN 'qualification' THEN 'qualification'::crm_activity_type_enum
      WHEN 'proposal' THEN 'proposal_sent'::crm_activity_type_enum
      ELSE 'system'::crm_activity_type_enum
    END,
    v_task.title,
    btrim(p_outcome),
    NOW(),
    v_actor,
    'human',
    jsonb_build_object('task_id', v_task.id)
  );

  IF p_create_next AND v_task.recurrence_rule IS NOT NULL THEN
    v_next_due := public.next_crm_recurrence_due_at(v_task.due_at, v_task.recurrence_rule);
    INSERT INTO public.tasks (
      account_id, contact_id, lead_id, opportunity_id, conversation_id,
      assigned_to, created_by, task_type, title, description, priority,
      status, due_at, recurrence_rule, parent_task_id
    ) VALUES (
      v_task.account_id, v_task.contact_id, v_task.lead_id,
      v_task.opportunity_id, v_task.conversation_id,
      public.resolve_delegated_user(
        v_task.account_id, v_task.assigned_to, 'open_tasks', v_next_due
      ),
      v_actor, v_task.task_type, v_task.title, v_task.description,
      v_task.priority, 'open', v_next_due, v_task.recurrence_rule, v_task.id
    )
    RETURNING * INTO v_next;
  END IF;

  RETURN jsonb_build_object(
    'task', to_jsonb(v_task),
    'next_task', CASE WHEN v_next.id IS NULL THEN NULL ELSE to_jsonb(v_next) END
  );
END;
$$;

ALTER FUNCTION public.complete_crm_task(UUID, TEXT, BOOLEAN) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.complete_crm_task(UUID, TEXT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.complete_crm_task(UUID, TEXT, BOOLEAN)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.cancel_crm_task(
  p_task_id UUID,
  p_reason TEXT
)
RETURNS public.tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task public.tasks%ROWTYPE;
BEGIN
  IF NULLIF(btrim(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Cancellation reason is required' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_task FROM public.tasks WHERE id = p_task_id FOR UPDATE;
  IF NOT FOUND OR NOT public.has_account_capability(v_task.account_id, 'task.update') THEN
    RAISE EXCEPTION 'Task not found or access denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_task.status NOT IN ('open', 'in_progress') THEN
    RAISE EXCEPTION 'Only active tasks can be cancelled' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE public.tasks
  SET status = 'cancelled',
      cancelled_at = NOW(),
      cancellation_reason = btrim(p_reason)
  WHERE id = p_task_id
  RETURNING * INTO v_task;
  RETURN v_task;
END;
$$;

ALTER FUNCTION public.cancel_crm_task(UUID, TEXT) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.cancel_crm_task(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_crm_task(UUID, TEXT)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.reassign_crm_task(
  p_task_id UUID,
  p_assigned_to UUID,
  p_reason TEXT
)
RETURNS public.tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_task public.tasks%ROWTYPE;
  v_actor UUID := auth.uid();
  v_target UUID;
BEGIN
  IF NULLIF(btrim(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Reassignment reason is required' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_task FROM public.tasks WHERE id = p_task_id FOR UPDATE;
  IF NOT FOUND OR NOT public.has_account_capability(v_task.account_id, 'task.delegate') THEN
    RAISE EXCEPTION 'Task not found or delegation denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_task.status NOT IN ('open', 'in_progress') THEN
    RAISE EXCEPTION 'Only active tasks can be reassigned' USING ERRCODE = 'check_violation';
  END IF;

  v_target := public.resolve_delegated_user(
    v_task.account_id, p_assigned_to, 'open_tasks', v_task.due_at
  );
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.account_id = v_task.account_id AND p.user_id = v_target
  ) THEN
    RAISE EXCEPTION 'Task assignee is not an account member'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  UPDATE public.tasks
  SET assigned_to = v_target
  WHERE id = p_task_id
  RETURNING * INTO v_task;

  INSERT INTO public.activities (
    account_id, contact_id, lead_id, opportunity_id, conversation_id,
    activity_type, summary, outcome, occurred_at, performed_by, source,
    metadata
  ) VALUES (
    v_task.account_id, v_task.contact_id, v_task.lead_id,
    v_task.opportunity_id, v_task.conversation_id,
    'assignment', 'Task reassigned', btrim(p_reason), NOW(), v_actor, 'human',
    jsonb_build_object('task_id', v_task.id, 'assigned_to', v_target)
  );

  RETURN v_task;
END;
$$;

ALTER FUNCTION public.reassign_crm_task(UUID, UUID, TEXT) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reassign_crm_task(UUID, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reassign_crm_task(UUID, UUID, TEXT)
  TO authenticated, service_role;

-- Idempotently create notifications for tasks due within a configurable window.
-- Intended for the existing supervised cron path; clients cannot execute it.
CREATE OR REPLACE FUNCTION public.enqueue_due_task_notifications(
  at_time TIMESTAMPTZ DEFAULT NOW(),
  due_window INTERVAL DEFAULT INTERVAL '15 minutes'
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  WITH inserted AS (
    INSERT INTO public.notifications (
      account_id, user_id, type, task_id, lead_id, contact_id,
      title, body, dedupe_key
    )
    SELECT
      t.account_id,
      t.assigned_to,
      'task_due',
      t.id,
      t.lead_id,
      t.contact_id,
      CASE WHEN t.due_at < at_time THEN 'Task overdue' ELSE 'Task due soon' END,
      t.title,
      'task-due:' || t.id::TEXT || ':' || to_char(t.due_at AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI')
    FROM public.tasks t
    WHERE t.archived_at IS NULL
      AND t.status IN ('open', 'in_progress')
      AND t.due_at <= at_time + due_window
    ON CONFLICT (account_id, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING
    RETURNING id
  )
  SELECT count(*) INTO v_count FROM inserted;
  RETURN v_count;
END;
$$;

ALTER FUNCTION public.enqueue_due_task_notifications(TIMESTAMPTZ, INTERVAL)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION public.enqueue_due_task_notifications(TIMESTAMPTZ, INTERVAL)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.enqueue_due_task_notifications(TIMESTAMPTZ, INTERVAL)
  TO service_role;

COMMIT;
