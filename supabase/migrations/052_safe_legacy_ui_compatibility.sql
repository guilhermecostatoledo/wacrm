-- ============================================================
-- 052_safe_legacy_ui_compatibility.sql
--
-- Temporary compatibility for UI callsites inherited from upstream:
--   - browser DELETE on contacts becomes archive (never hard delete);
--   - direct browser stage changes become safe open/won transitions;
--   - lost stages remain command-only because a structured reason is required.
--
-- New UI/API code should call archive/process commands directly. These guards
-- prevent old screens or external PostgREST clients from losing consistency
-- while callsites are migrated.
-- ============================================================

BEGIN;

-- -------------------------------------------------------------------------
-- CONTACT DELETE -> ARCHIVE
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.archive_contact_from_legacy_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_actor UUID := auth.uid();
BEGIN
  -- Supervised maintenance retains the ability to hard-delete only when it is
  -- explicitly executed outside an authenticated browser JWT.
  IF COALESCE(auth.jwt()->>'role', '') <> 'authenticated' THEN
    RETURN OLD;
  END IF;

  IF NOT public.has_account_capability(OLD.account_id, 'contact.archive') THEN
    RAISE EXCEPTION 'Missing contact.archive capability'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE public.contacts
  SET archived_at = COALESCE(archived_at, NOW()),
      archived_by = COALESCE(archived_by, v_actor),
      archive_reason = COALESCE(
        NULLIF(archive_reason, ''),
        'Archived from legacy delete action'
      ),
      lifecycle_status = 'archived',
      updated_at = NOW()
  WHERE id = OLD.id;

  UPDATE public.leads
  SET archived_at = COALESCE(archived_at, NOW()),
      updated_at = NOW()
  WHERE account_id = OLD.account_id
    AND contact_id = OLD.id
    AND archived_at IS NULL;

  UPDATE public.tasks
  SET status = CASE
        WHEN status IN ('open', 'in_progress') THEN 'cancelled'::task_status_enum
        ELSE status
      END,
      cancelled_at = CASE
        WHEN status IN ('open', 'in_progress') THEN NOW()
        ELSE cancelled_at
      END,
      cancellation_reason = CASE
        WHEN status IN ('open', 'in_progress') THEN 'Contact archived'
        ELSE cancellation_reason
      END,
      archived_at = COALESCE(archived_at, NOW()),
      updated_at = NOW()
  WHERE account_id = OLD.account_id
    AND contact_id = OLD.id
    AND archived_at IS NULL;

  INSERT INTO public.domain_events (
    account_id, aggregate_type, aggregate_id, event_type,
    actor_user_id, source, payload
  ) VALUES (
    OLD.account_id,
    'contact',
    OLD.id,
    'contact.archived',
    v_actor,
    'human',
    jsonb_build_object(
      'reason', 'Archived from legacy delete action',
      'compatibility_path', true
    )
  );

  -- Cancels the DELETE statement for this row. PostgREST may report zero
  -- deleted rows, but the contact and dependent work are safely archived.
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS archive_contact_from_legacy_delete ON public.contacts;
CREATE TRIGGER archive_contact_from_legacy_delete
  BEFORE DELETE ON public.contacts
  FOR EACH ROW EXECUTE FUNCTION public.archive_contact_from_legacy_delete();

DROP POLICY IF EXISTS contacts_delete_compat_archive ON public.contacts;
CREATE POLICY contacts_delete_compat_archive ON public.contacts FOR DELETE
  USING (public.has_account_capability(account_id, 'contact.archive'));
GRANT DELETE ON public.contacts TO authenticated;

-- -------------------------------------------------------------------------
-- LEGACY DIRECT STAGE UPDATE -> SAFE PROCESS TRANSITION
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_opportunity_command_columns()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_stage public.pipeline_stages%ROWTYPE;
  v_actor UUID := auth.uid();
BEGIN
  -- Transactional SECURITY DEFINER commands execute their nested UPDATE as
  -- postgres. Only compatibility writes made directly by browser JWTs enter
  -- this branch.
  IF COALESCE(auth.jwt()->>'role', '') <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  IF NEW.archived_at IS DISTINCT FROM OLD.archived_at
     OR NEW.loss_reason_id IS DISTINCT FROM OLD.loss_reason_id
     OR NEW.closed_by IS DISTINCT FROM OLD.closed_by
     OR NEW.won_at IS DISTINCT FROM OLD.won_at
     OR NEW.lost_at IS DISTINCT FROM OLD.lost_at
     OR (NEW.status IS DISTINCT FROM OLD.status AND NEW.stage_id IS NOT DISTINCT FROM OLD.stage_id)
     OR (NEW.probability IS DISTINCT FROM OLD.probability AND NEW.stage_id IS NOT DISTINCT FROM OLD.stage_id)
  THEN
    RAISE EXCEPTION 'Use opportunity process commands for lifecycle changes'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NEW.stage_id IS NOT DISTINCT FROM OLD.stage_id THEN
    RETURN NEW;
  END IF;

  IF NOT public.has_account_capability(OLD.account_id, 'opportunity.update') THEN
    RAISE EXCEPTION 'Missing opportunity.update capability'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF OLD.status <> 'open' THEN
    RAISE EXCEPTION 'Closed opportunities must be reopened explicitly'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_stage
  FROM public.pipeline_stages
  WHERE id = NEW.stage_id
    AND account_id = OLD.account_id
    AND pipeline_id = OLD.pipeline_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Target stage does not belong to the opportunity pipeline'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_stage.stage_kind = 'lost' THEN
    RAISE EXCEPTION 'Use the lost-opportunity command and provide a structured loss reason'
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_stage.stage_kind = 'won' THEN
    IF NOT public.has_account_capability(OLD.account_id, 'opportunity.close') THEN
      RAISE EXCEPTION 'Missing opportunity.close capability'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    NEW.status := 'won';
    NEW.probability := 100;
    NEW.won_at := NOW();
    NEW.lost_at := NULL;
    NEW.loss_reason_id := NULL;
    NEW.closed_by := v_actor;
  ELSE
    NEW.status := 'open';
    NEW.probability := LEAST(99, v_stage.default_probability);
    NEW.won_at := NULL;
    NEW.lost_at := NULL;
    NEW.loss_reason_id := NULL;
    NEW.closed_by := NULL;

    IF v_stage.requires_next_task AND NOT EXISTS (
      SELECT 1 FROM public.tasks t
      WHERE t.account_id = OLD.account_id
        AND t.opportunity_id = OLD.id
        AND t.status IN ('open', 'in_progress')
        AND t.archived_at IS NULL
    ) THEN
      INSERT INTO public.tasks (
        account_id, contact_id, lead_id, opportunity_id, conversation_id,
        assigned_to, created_by, task_type, title, description,
        priority, status, due_at
      ) VALUES (
        OLD.account_id,
        OLD.contact_id,
        OLD.lead_id,
        OLD.id,
        OLD.conversation_id,
        COALESCE(OLD.assigned_to, v_actor),
        v_actor,
        'follow_up',
        'Opportunity follow-up',
        'Automatically created while moving the opportunity from a legacy pipeline screen.',
        'normal',
        'open',
        NOW() + INTERVAL '1 day'
      );
    END IF;
  END IF;

  NEW.last_stage_changed_at := NOW();
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_legacy_opportunity_stage_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_actor UUID := auth.uid();
BEGIN
  IF COALESCE(auth.jwt()->>'role', '') <> 'authenticated'
     OR NEW.stage_id IS NOT DISTINCT FROM OLD.stage_id
  THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.opportunity_stage_history (
    account_id, opportunity_id, from_stage_id, to_stage_id,
    from_status, to_status, changed_by, reason
  ) VALUES (
    NEW.account_id, NEW.id, OLD.stage_id, NEW.stage_id,
    OLD.status, NEW.status, v_actor,
    CASE WHEN NEW.status = 'won'
      THEN 'Opportunity won from legacy pipeline screen'
      ELSE 'Stage changed from legacy pipeline screen'
    END
  );

  IF NEW.contact_id IS NOT NULL THEN
    INSERT INTO public.activities (
      account_id, contact_id, lead_id, opportunity_id, conversation_id,
      activity_type, summary, outcome, occurred_at, performed_by,
      source, metadata
    ) VALUES (
      NEW.account_id, NEW.contact_id, NEW.lead_id, NEW.id,
      NEW.conversation_id, 'stage_change', 'Opportunity process updated',
      CASE WHEN NEW.status = 'won' THEN 'Opportunity won' ELSE 'Stage changed' END,
      NOW(), v_actor, 'human',
      jsonb_build_object(
        'from_stage_id', OLD.stage_id,
        'to_stage_id', NEW.stage_id,
        'compatibility_path', true
      )
    );
  END IF;

  IF NEW.status = 'won' THEN
    UPDATE public.tasks
    SET status = 'cancelled',
        cancelled_at = NOW(),
        cancellation_reason = 'Opportunity won',
        archived_at = NOW(),
        updated_at = NOW()
    WHERE account_id = NEW.account_id
      AND opportunity_id = NEW.id
      AND status IN ('open', 'in_progress');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS record_legacy_opportunity_stage_change ON public.deals;
CREATE TRIGGER record_legacy_opportunity_stage_change
  AFTER UPDATE OF stage_id ON public.deals
  FOR EACH ROW EXECUTE FUNCTION public.record_legacy_opportunity_stage_change();

COMMENT ON FUNCTION public.archive_contact_from_legacy_delete() IS
  'Compatibility safety net: authenticated DELETE requests archive contacts and dependent work instead of deleting data.';
COMMENT ON FUNCTION public.record_legacy_opportunity_stage_change() IS
  'Compatibility audit for direct stage updates from legacy pipeline screens. Remove after all callsites use process commands.';

COMMIT;
