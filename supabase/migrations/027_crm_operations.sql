-- ============================================================
-- 027_crm_operations.sql — operational CRM domain
--
-- Adds the missing commercial execution layer between contacts,
-- conversations and deals:
--   * leads with an explicit lifecycle and ownership
--   * tasks with due dates and a single source of truth for next action
--   * immutable activities for audit/history
--   * actionable notifications tied to tasks/leads
--   * WhatsApp inbound messages creating a lead only when no active lead exists
--
-- Deletion/closure invariants:
--   * deleting a contact cascades to its leads
--   * deleting a lead cascades to its tasks and notifications
--   * closing/archiving a lead cancels open tasks and dismisses notifications
--   * deleting a deal never deletes the lead or task history
--
-- Idempotent: enums/tables/indexes are guarded and policies/triggers are
-- dropped before recreation.
-- ============================================================

-- ============================================================
-- ENUMS
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'lead_status_enum') THEN
    CREATE TYPE lead_status_enum AS ENUM (
      'new',
      'attempting_contact',
      'contacted',
      'qualified',
      'disqualified',
      'converted',
      'archived'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'lead_priority_enum') THEN
    CREATE TYPE lead_priority_enum AS ENUM ('low', 'medium', 'high', 'urgent');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'crm_task_status_enum') THEN
    CREATE TYPE crm_task_status_enum AS ENUM ('open', 'completed', 'cancelled');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'crm_task_type_enum') THEN
    CREATE TYPE crm_task_type_enum AS ENUM (
      'call',
      'whatsapp',
      'email',
      'meeting',
      'follow_up',
      'qualification',
      'other'
    );
  END IF;
END $$;

-- ============================================================
-- LEADS
-- ============================================================
CREATE TABLE IF NOT EXISTS leads (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  contact_id UUID NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  created_by_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  assigned_to UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  title TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'manual',
  status lead_status_enum NOT NULL DEFAULT 'new',
  priority lead_priority_enum NOT NULL DEFAULT 'medium',
  notes TEXT,
  loss_reason TEXT,
  next_action_at TIMESTAMPTZ,
  first_contact_at TIMESTAMPTZ,
  qualified_at TIMESTAMPTZ,
  closed_at TIMESTAMPTZ,
  archived_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_leads_account_status
  ON leads(account_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_leads_assigned_next_action
  ON leads(account_id, assigned_to, next_action_at)
  WHERE archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_leads_contact
  ON leads(account_id, contact_id);

-- One active commercial process per contact/account. Closed leads remain as
-- history and a future interaction may create a new lead.
CREATE UNIQUE INDEX IF NOT EXISTS idx_leads_one_active_per_contact
  ON leads(account_id, contact_id)
  WHERE archived_at IS NULL
    AND status NOT IN ('disqualified', 'converted', 'archived');

ALTER TABLE leads ENABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS set_updated_at ON leads;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON leads
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- TASKS
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_tasks (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  lead_id UUID REFERENCES leads(id) ON DELETE CASCADE,
  deal_id UUID REFERENCES deals(id) ON DELETE SET NULL,
  contact_id UUID REFERENCES contacts(id) ON DELETE SET NULL,
  created_by_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  assigned_to UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  title TEXT NOT NULL,
  description TEXT,
  task_type crm_task_type_enum NOT NULL DEFAULT 'follow_up',
  status crm_task_status_enum NOT NULL DEFAULT 'open',
  priority lead_priority_enum NOT NULL DEFAULT 'medium',
  due_at TIMESTAMPTZ NOT NULL,
  completed_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT crm_tasks_has_context CHECK (
    lead_id IS NOT NULL OR deal_id IS NOT NULL OR contact_id IS NOT NULL
  )
);

CREATE INDEX IF NOT EXISTS idx_crm_tasks_assignee_due
  ON crm_tasks(account_id, assigned_to, status, due_at);
CREATE INDEX IF NOT EXISTS idx_crm_tasks_lead_open
  ON crm_tasks(lead_id, due_at)
  WHERE status = 'open';
CREATE INDEX IF NOT EXISTS idx_crm_tasks_deal
  ON crm_tasks(deal_id, status, due_at);

ALTER TABLE crm_tasks ENABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS set_updated_at ON crm_tasks;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON crm_tasks
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- IMMUTABLE ACTIVITY LOG
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_activities (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  actor_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  contact_id UUID REFERENCES contacts(id) ON DELETE SET NULL,
  lead_id UUID REFERENCES leads(id) ON DELETE CASCADE,
  deal_id UUID REFERENCES deals(id) ON DELETE SET NULL,
  task_id UUID REFERENCES crm_tasks(id) ON DELETE SET NULL,
  activity_type TEXT NOT NULL,
  description TEXT NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_crm_activities_lead_time
  ON crm_activities(lead_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_crm_activities_account_time
  ON crm_activities(account_id, created_at DESC);

ALTER TABLE crm_activities ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- ACTIONABLE NOTIFICATIONS
-- ============================================================
CREATE TABLE IF NOT EXISTS crm_notifications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  task_id UUID NOT NULL REFERENCES crm_tasks(id) ON DELETE CASCADE,
  lead_id UUID REFERENCES leads(id) ON DELETE CASCADE,
  kind TEXT NOT NULL DEFAULT 'task_due',
  title TEXT NOT NULL,
  read_at TIMESTAMPTZ,
  dismissed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(task_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_crm_notifications_user_open
  ON crm_notifications(account_id, user_id, created_at DESC)
  WHERE dismissed_at IS NULL;

ALTER TABLE crm_notifications ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- PIPELINE INTEGRATION
-- ============================================================
ALTER TABLE deals
  ADD COLUMN IF NOT EXISTS lead_id UUID REFERENCES leads(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS next_action_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS lost_reason TEXT,
  ADD COLUMN IF NOT EXISTS won_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS lost_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_deals_lead ON deals(lead_id);
CREATE INDEX IF NOT EXISTS idx_deals_next_action
  ON deals(account_id, next_action_at)
  WHERE status = 'open';

-- ============================================================
-- RLS
-- ============================================================
DO $$
DECLARE
  pol RECORD;
BEGIN
  FOR pol IN
    SELECT policyname, tablename
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = ANY (ARRAY[
        'leads', 'crm_tasks', 'crm_activities', 'crm_notifications'
      ])
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol.policyname, pol.tablename);
  END LOOP;
END $$;

CREATE POLICY leads_select ON leads FOR SELECT
  USING (is_account_member(account_id));
CREATE POLICY leads_insert ON leads FOR INSERT
  WITH CHECK (is_account_member(account_id, 'agent'));
CREATE POLICY leads_update ON leads FOR UPDATE
  USING (is_account_member(account_id, 'agent'))
  WITH CHECK (is_account_member(account_id, 'agent'));
CREATE POLICY leads_delete ON leads FOR DELETE
  USING (is_account_member(account_id, 'agent'));

CREATE POLICY crm_tasks_select ON crm_tasks FOR SELECT
  USING (is_account_member(account_id));
CREATE POLICY crm_tasks_insert ON crm_tasks FOR INSERT
  WITH CHECK (is_account_member(account_id, 'agent'));
CREATE POLICY crm_tasks_update ON crm_tasks FOR UPDATE
  USING (is_account_member(account_id, 'agent'))
  WITH CHECK (is_account_member(account_id, 'agent'));
CREATE POLICY crm_tasks_delete ON crm_tasks FOR DELETE
  USING (is_account_member(account_id, 'agent'));

CREATE POLICY crm_activities_select ON crm_activities FOR SELECT
  USING (is_account_member(account_id));
CREATE POLICY crm_activities_insert ON crm_activities FOR INSERT
  WITH CHECK (is_account_member(account_id, 'agent'));
-- Activities are intentionally immutable to authenticated clients.

CREATE POLICY crm_notifications_select ON crm_notifications FOR SELECT
  USING (is_account_member(account_id) AND user_id = auth.uid());
CREATE POLICY crm_notifications_update ON crm_notifications FOR UPDATE
  USING (is_account_member(account_id) AND user_id = auth.uid())
  WITH CHECK (is_account_member(account_id) AND user_id = auth.uid());
CREATE POLICY crm_notifications_delete ON crm_notifications FOR DELETE
  USING (is_account_member(account_id) AND user_id = auth.uid());
-- Inserts are performed only by the task trigger/service role.

-- ============================================================
-- PREPARE / VALIDATE LEAD
-- ============================================================
CREATE OR REPLACE FUNCTION crm_prepare_lead()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_contact_account UUID;
  v_contact_name TEXT;
  v_owner UUID;
BEGIN
  SELECT c.account_id, COALESCE(NULLIF(c.name, ''), c.phone), a.owner_user_id
    INTO v_contact_account, v_contact_name, v_owner
  FROM contacts c
  JOIN accounts a ON a.id = c.account_id
  WHERE c.id = NEW.contact_id;

  IF v_contact_account IS NULL THEN
    RAISE EXCEPTION 'Contact % does not exist', NEW.contact_id;
  END IF;

  NEW.account_id := COALESCE(NEW.account_id, v_contact_account);
  IF NEW.account_id <> v_contact_account THEN
    RAISE EXCEPTION 'Lead and contact must belong to the same account';
  END IF;

  NEW.created_by_user_id := COALESCE(NEW.created_by_user_id, auth.uid(), v_owner);
  NEW.assigned_to := COALESCE(NEW.assigned_to, auth.uid(), v_owner);
  NEW.title := COALESCE(NULLIF(BTRIM(NEW.title), ''), v_contact_name, 'Lead');

  IF TG_OP = 'UPDATE' THEN
    IF OLD.status <> NEW.status THEN
      IF NEW.status = 'contacted' AND NEW.first_contact_at IS NULL THEN
        NEW.first_contact_at := NOW();
      END IF;
      IF NEW.status = 'qualified' AND NEW.qualified_at IS NULL THEN
        NEW.qualified_at := NOW();
      END IF;
      IF NEW.status IN ('disqualified', 'converted', 'archived') THEN
        NEW.closed_at := COALESCE(NEW.closed_at, NOW());
      END IF;
      IF NEW.status = 'archived' THEN
        NEW.archived_at := COALESCE(NEW.archived_at, NOW());
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;
ALTER FUNCTION crm_prepare_lead() OWNER TO postgres;

DROP TRIGGER IF EXISTS crm_prepare_lead_trigger ON leads;
CREATE TRIGGER crm_prepare_lead_trigger
  BEFORE INSERT OR UPDATE ON leads
  FOR EACH ROW EXECUTE FUNCTION crm_prepare_lead();

-- ============================================================
-- PREPARE / VALIDATE TASK
-- ============================================================
CREATE OR REPLACE FUNCTION crm_prepare_task()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account UUID;
  v_contact UUID;
  v_assignee UUID;
  v_owner UUID;
BEGIN
  IF NEW.lead_id IS NOT NULL THEN
    SELECT l.account_id, l.contact_id, l.assigned_to
      INTO v_account, v_contact, v_assignee
    FROM leads l
    WHERE l.id = NEW.lead_id;
  ELSIF NEW.deal_id IS NOT NULL THEN
    SELECT d.account_id, d.contact_id, d.assigned_to
      INTO v_account, v_contact, v_assignee
    FROM deals d
    WHERE d.id = NEW.deal_id;
  ELSIF NEW.contact_id IS NOT NULL THEN
    SELECT c.account_id, c.id
      INTO v_account, v_contact
    FROM contacts c
    WHERE c.id = NEW.contact_id;
  END IF;

  IF v_account IS NULL THEN
    RAISE EXCEPTION 'Task context does not exist';
  END IF;

  SELECT owner_user_id INTO v_owner FROM accounts WHERE id = v_account;

  NEW.account_id := COALESCE(NEW.account_id, v_account);
  IF NEW.account_id <> v_account THEN
    RAISE EXCEPTION 'Task and related record must belong to the same account';
  END IF;

  NEW.contact_id := COALESCE(NEW.contact_id, v_contact);
  NEW.created_by_user_id := COALESCE(NEW.created_by_user_id, auth.uid(), v_owner);
  NEW.assigned_to := COALESCE(NEW.assigned_to, v_assignee, auth.uid(), v_owner);

  IF NEW.status = 'completed' THEN
    NEW.completed_at := COALESCE(NEW.completed_at, NOW());
    NEW.cancelled_at := NULL;
  ELSIF NEW.status = 'cancelled' THEN
    NEW.cancelled_at := COALESCE(NEW.cancelled_at, NOW());
    NEW.completed_at := NULL;
  ELSE
    NEW.completed_at := NULL;
    NEW.cancelled_at := NULL;
  END IF;

  RETURN NEW;
END;
$$;
ALTER FUNCTION crm_prepare_task() OWNER TO postgres;

DROP TRIGGER IF EXISTS crm_prepare_task_trigger ON crm_tasks;
CREATE TRIGGER crm_prepare_task_trigger
  BEFORE INSERT OR UPDATE ON crm_tasks
  FOR EACH ROW EXECUTE FUNCTION crm_prepare_task();

-- ============================================================
-- NEXT ACTION SYNCHRONISATION
-- ============================================================
CREATE OR REPLACE FUNCTION crm_refresh_lead_next_action(p_lead_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_lead_id IS NULL THEN
    RETURN;
  END IF;

  UPDATE leads l
  SET next_action_at = (
    SELECT MIN(t.due_at)
    FROM crm_tasks t
    WHERE t.lead_id = p_lead_id
      AND t.status = 'open'
  )
  WHERE l.id = p_lead_id;
END;
$$;
ALTER FUNCTION crm_refresh_lead_next_action(UUID) OWNER TO postgres;

CREATE OR REPLACE FUNCTION crm_sync_task_dependencies()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new crm_tasks;
  v_lead UUID;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_lead := OLD.lead_id;
    PERFORM crm_refresh_lead_next_action(v_lead);
    RETURN OLD;
  END IF;

  v_new := NEW;
  v_lead := NEW.lead_id;

  IF TG_OP = 'UPDATE' AND OLD.lead_id IS DISTINCT FROM NEW.lead_id THEN
    PERFORM crm_refresh_lead_next_action(OLD.lead_id);
  END IF;
  PERFORM crm_refresh_lead_next_action(v_lead);

  IF NEW.status = 'open' THEN
    INSERT INTO crm_notifications (
      account_id, user_id, task_id, lead_id, kind, title, dismissed_at
    ) VALUES (
      NEW.account_id,
      NEW.assigned_to,
      NEW.id,
      NEW.lead_id,
      CASE WHEN NEW.due_at < NOW() THEN 'task_overdue' ELSE 'task_due' END,
      NEW.title,
      NULL
    )
    ON CONFLICT (task_id, user_id)
    DO UPDATE SET
      lead_id = EXCLUDED.lead_id,
      kind = EXCLUDED.kind,
      title = EXCLUDED.title,
      dismissed_at = NULL;
  ELSE
    UPDATE crm_notifications
    SET dismissed_at = COALESCE(dismissed_at, NOW())
    WHERE task_id = NEW.id
      AND dismissed_at IS NULL;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.assigned_to IS DISTINCT FROM NEW.assigned_to THEN
    DELETE FROM crm_notifications
    WHERE task_id = NEW.id
      AND user_id <> NEW.assigned_to;
  END IF;

  RETURN v_new;
END;
$$;
ALTER FUNCTION crm_sync_task_dependencies() OWNER TO postgres;

DROP TRIGGER IF EXISTS crm_sync_task_dependencies_trigger ON crm_tasks;
CREATE TRIGGER crm_sync_task_dependencies_trigger
  AFTER INSERT OR UPDATE OR DELETE ON crm_tasks
  FOR EACH ROW EXECUTE FUNCTION crm_sync_task_dependencies();

-- ============================================================
-- FIRST TASK ON LEAD CREATION
-- ============================================================
CREATE OR REPLACE FUNCTION crm_create_first_task()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IN ('disqualified', 'converted', 'archived') THEN
    RETURN NEW;
  END IF;

  INSERT INTO crm_tasks (
    account_id,
    lead_id,
    contact_id,
    created_by_user_id,
    assigned_to,
    title,
    description,
    task_type,
    status,
    priority,
    due_at
  ) VALUES (
    NEW.account_id,
    NEW.id,
    NEW.contact_id,
    NEW.created_by_user_id,
    NEW.assigned_to,
    'Realizar primeiro contato',
    'Primeira ação criada automaticamente para impedir que o lead fique sem acompanhamento.',
    'qualification',
    'open',
    NEW.priority,
    NOW()
  );

  RETURN NEW;
END;
$$;
ALTER FUNCTION crm_create_first_task() OWNER TO postgres;

DROP TRIGGER IF EXISTS crm_create_first_task_trigger ON leads;
CREATE TRIGGER crm_create_first_task_trigger
  AFTER INSERT ON leads
  FOR EACH ROW EXECUTE FUNCTION crm_create_first_task();

-- ============================================================
-- CLOSE/ARCHIVE CLEANUP
-- ============================================================
CREATE OR REPLACE FUNCTION crm_close_lead_dependencies()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status
     AND NEW.status IN ('disqualified', 'converted', 'archived') THEN
    UPDATE crm_tasks
    SET status = 'cancelled'
    WHERE lead_id = NEW.id
      AND status = 'open';

    UPDATE crm_notifications
    SET dismissed_at = COALESCE(dismissed_at, NOW())
    WHERE lead_id = NEW.id
      AND dismissed_at IS NULL;
  END IF;

  RETURN NEW;
END;
$$;
ALTER FUNCTION crm_close_lead_dependencies() OWNER TO postgres;

DROP TRIGGER IF EXISTS crm_close_lead_dependencies_trigger ON leads;
CREATE TRIGGER crm_close_lead_dependencies_trigger
  AFTER UPDATE ON leads
  FOR EACH ROW EXECUTE FUNCTION crm_close_lead_dependencies();

-- ============================================================
-- AUDIT EVENTS
-- ============================================================
CREATE OR REPLACE FUNCTION crm_log_lead_activity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO crm_activities (
      account_id, actor_user_id, contact_id, lead_id,
      activity_type, description, metadata
    ) VALUES (
      NEW.account_id,
      NEW.created_by_user_id,
      NEW.contact_id,
      NEW.id,
      'lead_created',
      'Lead criado',
      jsonb_build_object('source', NEW.source, 'status', NEW.status)
    );
  ELSIF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO crm_activities (
      account_id, actor_user_id, contact_id, lead_id,
      activity_type, description, metadata
    ) VALUES (
      NEW.account_id,
      auth.uid(),
      NEW.contact_id,
      NEW.id,
      'lead_status_changed',
      'Status do lead alterado',
      jsonb_build_object('from', OLD.status, 'to', NEW.status)
    );
  END IF;

  RETURN NEW;
END;
$$;
ALTER FUNCTION crm_log_lead_activity() OWNER TO postgres;

DROP TRIGGER IF EXISTS crm_log_lead_activity_trigger ON leads;
CREATE TRIGGER crm_log_lead_activity_trigger
  AFTER INSERT OR UPDATE ON leads
  FOR EACH ROW EXECUTE FUNCTION crm_log_lead_activity();

CREATE OR REPLACE FUNCTION crm_log_task_activity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO crm_activities (
      account_id, actor_user_id, contact_id, lead_id, deal_id, task_id,
      activity_type, description, metadata
    ) VALUES (
      NEW.account_id,
      auth.uid(),
      NEW.contact_id,
      NEW.lead_id,
      NEW.deal_id,
      NEW.id,
      CASE NEW.status
        WHEN 'completed' THEN 'task_completed'
        WHEN 'cancelled' THEN 'task_cancelled'
        ELSE 'task_reopened'
      END,
      NEW.title,
      jsonb_build_object('from', OLD.status, 'to', NEW.status)
    );
  END IF;

  RETURN NEW;
END;
$$;
ALTER FUNCTION crm_log_task_activity() OWNER TO postgres;

DROP TRIGGER IF EXISTS crm_log_task_activity_trigger ON crm_tasks;
CREATE TRIGGER crm_log_task_activity_trigger
  AFTER UPDATE ON crm_tasks
  FOR EACH ROW EXECUTE FUNCTION crm_log_task_activity();

-- ============================================================
-- WHATSAPP → LEAD BRIDGE
--
-- Only inbound customer messages create leads. Existing active leads are
-- reused; closed leads remain history and a new inbound interaction starts
-- a new commercial cycle.
-- ============================================================
CREATE OR REPLACE FUNCTION crm_ensure_lead_from_inbound_message()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account UUID;
  v_contact UUID;
  v_assignee UUID;
  v_title TEXT;
BEGIN
  IF NEW.sender_type <> 'customer' THEN
    RETURN NEW;
  END IF;

  SELECT c.account_id,
         c.contact_id,
         COALESCE(c.assigned_agent_id, a.owner_user_id),
         COALESCE(NULLIF(ct.name, ''), ct.phone, 'Lead WhatsApp')
    INTO v_account, v_contact, v_assignee, v_title
  FROM conversations c
  JOIN contacts ct ON ct.id = c.contact_id
  JOIN accounts a ON a.id = c.account_id
  WHERE c.id = NEW.conversation_id;

  IF v_account IS NULL THEN
    RETURN NEW;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM leads l
    WHERE l.account_id = v_account
      AND l.contact_id = v_contact
      AND l.archived_at IS NULL
      AND l.status NOT IN ('disqualified', 'converted', 'archived')
  ) THEN
    BEGIN
      INSERT INTO leads (
        account_id,
        contact_id,
        created_by_user_id,
        assigned_to,
        title,
        source,
        status,
        priority
      ) VALUES (
        v_account,
        v_contact,
        v_assignee,
        v_assignee,
        v_title,
        'whatsapp',
        'new',
        'medium'
      );
    EXCEPTION WHEN unique_violation THEN
      -- Concurrent inbound messages may race; the partial unique index is
      -- the final authority and the second event safely becomes a no-op.
      NULL;
    END;
  END IF;

  RETURN NEW;
END;
$$;
ALTER FUNCTION crm_ensure_lead_from_inbound_message() OWNER TO postgres;

DROP TRIGGER IF EXISTS crm_ensure_lead_from_inbound_message_trigger ON messages;
CREATE TRIGGER crm_ensure_lead_from_inbound_message_trigger
  AFTER INSERT ON messages
  FOR EACH ROW EXECUTE FUNCTION crm_ensure_lead_from_inbound_message();

-- ============================================================
-- SAFE ARCHIVE RPC
-- ============================================================
CREATE OR REPLACE FUNCTION crm_archive_lead(
  p_lead_id UUID,
  p_reason TEXT DEFAULT NULL
) RETURNS SETOF leads
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  UPDATE leads
  SET status = 'archived',
      archived_at = NOW(),
      loss_reason = COALESCE(NULLIF(BTRIM(p_reason), ''), loss_reason)
  WHERE id = p_lead_id
  RETURNING *;
END;
$$;
GRANT EXECUTE ON FUNCTION crm_archive_lead(UUID, TEXT) TO authenticated;

-- ============================================================
-- REALTIME
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'leads'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE leads;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'crm_tasks'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE crm_tasks;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'crm_notifications'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE crm_notifications;
  END IF;
END $$;
