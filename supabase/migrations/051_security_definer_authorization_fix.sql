-- ============================================================
-- 051_security_definer_authorization_fix.sql
--
-- SECURITY DEFINER functions execute with the function owner's current_user.
-- Therefore `current_user = 'authenticated'` is not a reliable way to detect
-- a browser caller and can silently skip authorization. This migration:
--   1. resolves trusted backend access from the JWT role claim;
--   2. fixes the member-grant self-escalation trigger;
--   3. wraps command functions that previously used conditional checks so
--      every caller is authorized before the original transactional body runs.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.has_account_capability(
  target_account_id UUID,
  target_capability TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role account_role_enum;
  v_effect capability_effect_enum;
  v_jwt_role TEXT := COALESCE(auth.jwt()->>'role', '');
BEGIN
  -- Service-role requests have already been authenticated and scope-checked
  -- by a supervised server route/worker. Direct SQL by postgres bypasses RLS
  -- and does not depend on this helper.
  IF v_jwt_role = 'service_role' THEN
    RETURN EXISTS (SELECT 1 FROM public.accounts a WHERE a.id = target_account_id)
      AND EXISTS (
        SELECT 1 FROM public.capability_definitions c
        WHERE c.capability = target_capability
      );
  END IF;

  IF auth.uid() IS NULL THEN
    RETURN false;
  END IF;

  SELECT p.account_role INTO v_role
  FROM public.profiles p
  WHERE p.user_id = auth.uid()
    AND p.account_id = target_account_id;

  IF v_role IS NULL THEN
    RETURN false;
  END IF;

  SELECT g.effect INTO v_effect
  FROM public.member_capability_grants g
  WHERE g.account_id = target_account_id
    AND g.user_id = auth.uid()
    AND g.capability = target_capability
    AND (g.expires_at IS NULL OR g.expires_at > NOW())
  ORDER BY CASE g.effect WHEN 'deny' THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_effect IS NOT NULL THEN
    RETURN v_effect = 'allow';
  END IF;

  SELECT g.effect INTO v_effect
  FROM public.role_capability_grants g
  WHERE g.account_id = target_account_id
    AND g.role = v_role
    AND g.capability = target_capability
    AND g.is_active
  LIMIT 1;

  RETURN COALESCE(v_effect = 'allow', false);
END;
$$;

ALTER FUNCTION public.has_account_capability(UUID, TEXT) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.has_account_capability(UUID, TEXT)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.enforce_member_capability_grant_authority()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_actor_is_owner BOOLEAN;
  v_target_role account_role_enum;
BEGIN
  -- A service-role operation has no user JWT and is supervised server-side.
  -- Authenticated users always carry auth.uid(), regardless of SECURITY
  -- DEFINER ownership.
  IF v_actor IS NULL THEN
    RETURN NEW;
  END IF;

  v_actor_is_owner := public.is_account_member(NEW.account_id, 'owner');

  SELECT p.account_role INTO v_target_role
  FROM public.profiles p
  WHERE p.account_id = NEW.account_id
    AND p.user_id = NEW.user_id;

  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'Capability target is not an account member'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NOT v_actor_is_owner AND NEW.user_id = v_actor THEN
    RAISE EXCEPTION 'Non-owner members cannot modify their own capability overrides'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT v_actor_is_owner AND v_target_role = 'owner' THEN
    RAISE EXCEPTION 'Only the owner can modify owner capability overrides'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NEW.capability IN ('account.transfer', 'account.delete') AND NOT v_actor_is_owner THEN
    RAISE EXCEPTION 'This capability can only be granted or denied by the owner'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NEW.created_by IS NULL THEN
    NEW.created_by := v_actor;
  ELSIF NEW.created_by IS DISTINCT FROM v_actor AND NOT v_actor_is_owner THEN
    RAISE EXCEPTION 'created_by must match the authenticated administrator'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN NEW;
END;
$$;

ALTER FUNCTION public.enforce_member_capability_grant_authority() OWNER TO postgres;

-- -------------------------------------------------------------------------
-- Rename the original transactional implementations once. They remain
-- private and are callable only by the authorized wrappers below.
-- -------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regprocedure(
    'public.intake_lead(uuid,text,text,text,text,text,text,uuid,jsonb,integer,boolean,boolean,uuid)'
  ) IS NOT NULL
  AND to_regprocedure(
    'public.intake_lead_unchecked(uuid,text,text,text,text,text,text,uuid,jsonb,integer,boolean,boolean,uuid)'
  ) IS NULL THEN
    ALTER FUNCTION public.intake_lead(
      UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, JSONB,
      INTEGER, BOOLEAN, BOOLEAN, UUID
    ) RENAME TO intake_lead_unchecked;
  END IF;

  IF to_regprocedure(
    'public.create_crm_task(uuid,uuid,text,timestamptz,uuid,uuid,uuid,uuid,crm_task_type_enum,text,crm_priority_enum,text,uuid)'
  ) IS NOT NULL
  AND to_regprocedure(
    'public.create_crm_task_unchecked(uuid,uuid,text,timestamptz,uuid,uuid,uuid,uuid,crm_task_type_enum,text,crm_priority_enum,text,uuid)'
  ) IS NULL THEN
    ALTER FUNCTION public.create_crm_task(
      UUID, UUID, TEXT, TIMESTAMPTZ, UUID, UUID, UUID, UUID,
      crm_task_type_enum, TEXT, crm_priority_enum, TEXT, UUID
    ) RENAME TO create_crm_task_unchecked;
  END IF;

  IF to_regprocedure(
    'public.record_marketing_touchpoint(uuid,uuid,uuid,marketing_touchpoint_event_enum,text,uuid,uuid,text,timestamptz,jsonb)'
  ) IS NOT NULL
  AND to_regprocedure(
    'public.record_marketing_touchpoint_unchecked(uuid,uuid,uuid,marketing_touchpoint_event_enum,text,uuid,uuid,text,timestamptz,jsonb)'
  ) IS NULL THEN
    ALTER FUNCTION public.record_marketing_touchpoint(
      UUID, UUID, UUID, marketing_touchpoint_event_enum, TEXT,
      UUID, UUID, TEXT, TIMESTAMPTZ, JSONB
    ) RENAME TO record_marketing_touchpoint_unchecked;
  END IF;
END $$;

REVOKE ALL ON FUNCTION public.intake_lead_unchecked(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, JSONB,
  INTEGER, BOOLEAN, BOOLEAN, UUID
) FROM PUBLIC, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_crm_task_unchecked(
  UUID, UUID, TEXT, TIMESTAMPTZ, UUID, UUID, UUID, UUID,
  crm_task_type_enum, TEXT, crm_priority_enum, TEXT, UUID
) FROM PUBLIC, authenticated, service_role;
REVOKE ALL ON FUNCTION public.record_marketing_touchpoint_unchecked(
  UUID, UUID, UUID, marketing_touchpoint_event_enum, TEXT,
  UUID, UUID, TEXT, TIMESTAMPTZ, JSONB
) FROM PUBLIC, authenticated, service_role;

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
BEGIN
  IF NOT public.has_account_capability(p_account_id, 'lead.create') THEN
    RAISE EXCEPTION 'Missing lead.create capability'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN public.intake_lead_unchecked(
    p_account_id, p_phone, p_name, p_email, p_company, p_source_code,
    p_external_key, p_requested_owner_id, p_source_detail,
    p_first_response_minutes, p_create_first_task, p_reopen_disqualified,
    p_created_by
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
BEGIN
  IF NOT public.has_account_capability(p_account_id, 'task.create') THEN
    RAISE EXCEPTION 'Missing task.create capability'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN public.create_crm_task_unchecked(
    p_account_id, p_contact_id, p_title, p_due_at, p_assigned_to,
    p_lead_id, p_opportunity_id, p_conversation_id, p_task_type,
    p_description, p_priority, p_recurrence_rule, p_created_by
  );
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

CREATE OR REPLACE FUNCTION public.record_marketing_touchpoint(
  p_account_id UUID,
  p_campaign_id UUID,
  p_contact_id UUID,
  p_event_type marketing_touchpoint_event_enum,
  p_channel TEXT,
  p_lead_id UUID DEFAULT NULL,
  p_opportunity_id UUID DEFAULT NULL,
  p_external_event_id TEXT DEFAULT NULL,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW(),
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS public.marketing_touchpoints
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_account_capability(p_account_id, 'broadcast.create') THEN
    RAISE EXCEPTION 'Missing campaign write capability'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN public.record_marketing_touchpoint_unchecked(
    p_account_id, p_campaign_id, p_contact_id, p_event_type, p_channel,
    p_lead_id, p_opportunity_id, p_external_event_id, p_occurred_at,
    p_metadata
  );
END;
$$;

ALTER FUNCTION public.record_marketing_touchpoint(
  UUID, UUID, UUID, marketing_touchpoint_event_enum, TEXT,
  UUID, UUID, TEXT, TIMESTAMPTZ, JSONB
) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.record_marketing_touchpoint(
  UUID, UUID, UUID, marketing_touchpoint_event_enum, TEXT,
  UUID, UUID, TEXT, TIMESTAMPTZ, JSONB
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_marketing_touchpoint(
  UUID, UUID, UUID, marketing_touchpoint_event_enum, TEXT,
  UUID, UUID, TEXT, TIMESTAMPTZ, JSONB
) TO authenticated, service_role;

COMMENT ON FUNCTION public.has_account_capability(UUID, TEXT) IS
  'Uses auth.uid for user sessions and the JWT role claim for supervised service-role execution. Never branches on SECURITY DEFINER current_user.';

COMMIT;
