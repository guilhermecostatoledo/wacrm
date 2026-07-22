-- ============================================================
-- 028_crm_pipeline_sync.sql — keep deals, leads and tasks coherent
--
-- A deal created for a contact is linked to that contact's active lead. If no
-- active lead exists, a qualified lead is created automatically. Deal outcome
-- updates the lead outcome, and the earliest open task becomes the deal's next
-- action even when the task was created against the lead rather than the deal.
-- ============================================================

CREATE OR REPLACE FUNCTION crm_find_or_create_lead_for_deal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_lead UUID;
  v_owner UUID;
  v_assignee UUID;
  v_title TEXT;
BEGIN
  IF NEW.contact_id IS NULL OR NEW.lead_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT l.id
    INTO v_lead
  FROM leads l
  WHERE l.account_id = NEW.account_id
    AND l.contact_id = NEW.contact_id
    AND l.archived_at IS NULL
    AND l.status NOT IN ('disqualified', 'converted', 'archived')
  ORDER BY l.created_at DESC
  LIMIT 1;

  IF v_lead IS NULL THEN
    SELECT a.owner_user_id,
           COALESCE(NEW.assigned_to, a.owner_user_id),
           COALESCE(NULLIF(NEW.title, ''), NULLIF(c.name, ''), c.phone, 'Oportunidade')
      INTO v_owner, v_assignee, v_title
    FROM accounts a
    JOIN contacts c ON c.account_id = a.id
    WHERE a.id = NEW.account_id
      AND c.id = NEW.contact_id;

    BEGIN
      INSERT INTO leads (
        account_id,
        contact_id,
        created_by_user_id,
        assigned_to,
        title,
        source,
        status,
        priority,
        qualified_at
      ) VALUES (
        NEW.account_id,
        NEW.contact_id,
        COALESCE(auth.uid(), v_owner),
        v_assignee,
        v_title,
        'pipeline',
        'qualified',
        'medium',
        NOW()
      )
      RETURNING id INTO v_lead;
    EXCEPTION WHEN unique_violation THEN
      SELECT l.id
        INTO v_lead
      FROM leads l
      WHERE l.account_id = NEW.account_id
        AND l.contact_id = NEW.contact_id
        AND l.archived_at IS NULL
        AND l.status NOT IN ('disqualified', 'converted', 'archived')
      ORDER BY l.created_at DESC
      LIMIT 1;
    END;
  END IF;

  UPDATE deals
  SET lead_id = v_lead
  WHERE id = NEW.id
    AND lead_id IS NULL;

  RETURN NEW;
END;
$$;
ALTER FUNCTION crm_find_or_create_lead_for_deal() OWNER TO postgres;

DROP TRIGGER IF EXISTS crm_find_or_create_lead_for_deal_trigger ON deals;
CREATE TRIGGER crm_find_or_create_lead_for_deal_trigger
  AFTER INSERT ON deals
  FOR EACH ROW EXECUTE FUNCTION crm_find_or_create_lead_for_deal();

CREATE OR REPLACE FUNCTION crm_validate_deal_lead_scope()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account UUID;
  v_contact UUID;
BEGIN
  IF NEW.lead_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT account_id, contact_id
    INTO v_account, v_contact
  FROM leads
  WHERE id = NEW.lead_id;

  IF v_account IS NULL THEN
    RAISE EXCEPTION 'Lead % does not exist', NEW.lead_id;
  END IF;

  IF v_account <> NEW.account_id THEN
    RAISE EXCEPTION 'Deal and lead must belong to the same account';
  END IF;

  IF NEW.contact_id IS DISTINCT FROM v_contact THEN
    RAISE EXCEPTION 'Deal and lead must reference the same contact';
  END IF;

  RETURN NEW;
END;
$$;
ALTER FUNCTION crm_validate_deal_lead_scope() OWNER TO postgres;

DROP TRIGGER IF EXISTS crm_validate_deal_lead_scope_trigger ON deals;
CREATE TRIGGER crm_validate_deal_lead_scope_trigger
  BEFORE INSERT OR UPDATE OF lead_id, contact_id, account_id ON deals
  FOR EACH ROW EXECUTE FUNCTION crm_validate_deal_lead_scope();

CREATE OR REPLACE FUNCTION crm_sync_deal_outcome()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'won' THEN
    NEW.won_at := COALESCE(NEW.won_at, NOW());
    NEW.lost_at := NULL;

    IF NEW.lead_id IS NOT NULL THEN
      UPDATE leads
      SET status = 'converted',
          closed_at = COALESCE(closed_at, NOW())
      WHERE id = NEW.lead_id
        AND status <> 'converted';
    END IF;
  ELSIF NEW.status = 'lost' THEN
    NEW.lost_at := COALESCE(NEW.lost_at, NOW());
    NEW.won_at := NULL;

    IF NEW.lead_id IS NOT NULL THEN
      UPDATE leads
      SET status = 'disqualified',
          loss_reason = COALESCE(NULLIF(BTRIM(NEW.lost_reason), ''), loss_reason, 'Negócio perdido'),
          closed_at = COALESCE(closed_at, NOW())
      WHERE id = NEW.lead_id
        AND status <> 'disqualified';
    END IF;
  ELSE
    NEW.won_at := NULL;
    NEW.lost_at := NULL;
  END IF;

  RETURN NEW;
END;
$$;
ALTER FUNCTION crm_sync_deal_outcome() OWNER TO postgres;

DROP TRIGGER IF EXISTS crm_sync_deal_outcome_trigger ON deals;
CREATE TRIGGER crm_sync_deal_outcome_trigger
  BEFORE UPDATE OF status ON deals
  FOR EACH ROW EXECUTE FUNCTION crm_sync_deal_outcome();

CREATE OR REPLACE FUNCTION crm_refresh_deal_next_action(
  p_deal_id UUID DEFAULT NULL,
  p_lead_id UUID DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE deals d
  SET next_action_at = (
    SELECT MIN(t.due_at)
    FROM crm_tasks t
    WHERE t.status = 'open'
      AND (
        t.deal_id = d.id
        OR (t.deal_id IS NULL AND d.lead_id IS NOT NULL AND t.lead_id = d.lead_id)
      )
  )
  WHERE (p_deal_id IS NOT NULL AND d.id = p_deal_id)
     OR (p_lead_id IS NOT NULL AND d.lead_id = p_lead_id);
END;
$$;
ALTER FUNCTION crm_refresh_deal_next_action(UUID, UUID) OWNER TO postgres;

CREATE OR REPLACE FUNCTION crm_sync_deal_next_action_from_task()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM crm_refresh_deal_next_action(OLD.deal_id, OLD.lead_id);
    RETURN OLD;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF OLD.deal_id IS DISTINCT FROM NEW.deal_id
       OR OLD.lead_id IS DISTINCT FROM NEW.lead_id THEN
      PERFORM crm_refresh_deal_next_action(OLD.deal_id, OLD.lead_id);
    END IF;
  END IF;

  PERFORM crm_refresh_deal_next_action(NEW.deal_id, NEW.lead_id);
  RETURN NEW;
END;
$$;
ALTER FUNCTION crm_sync_deal_next_action_from_task() OWNER TO postgres;

DROP TRIGGER IF EXISTS crm_sync_deal_next_action_from_task_trigger ON crm_tasks;
CREATE TRIGGER crm_sync_deal_next_action_from_task_trigger
  AFTER INSERT OR UPDATE OR DELETE ON crm_tasks
  FOR EACH ROW EXECUTE FUNCTION crm_sync_deal_next_action_from_task();

CREATE OR REPLACE FUNCTION crm_log_deal_activity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO crm_activities (
      account_id, actor_user_id, contact_id, lead_id, deal_id,
      activity_type, description, metadata
    ) VALUES (
      NEW.account_id,
      auth.uid(),
      NEW.contact_id,
      NEW.lead_id,
      NEW.id,
      'deal_created',
      NEW.title,
      jsonb_build_object('stage_id', NEW.stage_id, 'value', NEW.value)
    );
  ELSE
    IF OLD.stage_id IS DISTINCT FROM NEW.stage_id THEN
      INSERT INTO crm_activities (
        account_id, actor_user_id, contact_id, lead_id, deal_id,
        activity_type, description, metadata
      ) VALUES (
        NEW.account_id,
        auth.uid(),
        NEW.contact_id,
        NEW.lead_id,
        NEW.id,
        'deal_stage_changed',
        NEW.title,
        jsonb_build_object('from', OLD.stage_id, 'to', NEW.stage_id)
      );
    END IF;

    IF OLD.status IS DISTINCT FROM NEW.status THEN
      INSERT INTO crm_activities (
        account_id, actor_user_id, contact_id, lead_id, deal_id,
        activity_type, description, metadata
      ) VALUES (
        NEW.account_id,
        auth.uid(),
        NEW.contact_id,
        NEW.lead_id,
        NEW.id,
        'deal_status_changed',
        NEW.title,
        jsonb_build_object('from', OLD.status, 'to', NEW.status)
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;
ALTER FUNCTION crm_log_deal_activity() OWNER TO postgres;

DROP TRIGGER IF EXISTS crm_log_deal_activity_trigger ON deals;
CREATE TRIGGER crm_log_deal_activity_trigger
  AFTER INSERT OR UPDATE ON deals
  FOR EACH ROW EXECUTE FUNCTION crm_log_deal_activity();
