-- ============================================================
-- 039_capabilities_teams_delegations.sql
--
-- Block 2 foundation. Adds granular capabilities, teams and temporary
-- delegation without immediately rewriting every legacy RLS policy. The
-- helper functions introduced here become the authorization source used by
-- subsequent API/UI/RLS migrations.
-- ============================================================

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'capability_effect_enum') THEN
    CREATE TYPE capability_effect_enum AS ENUM ('allow', 'deny');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'team_member_role_enum') THEN
    CREATE TYPE team_member_role_enum AS ENUM ('member', 'manager');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'record_visibility_scope_enum') THEN
    CREATE TYPE record_visibility_scope_enum AS ENUM ('own', 'team', 'account');
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_profiles_account_user
  ON public.profiles(account_id, user_id);

-- ============================================================
-- CAPABILITY REGISTRY
-- ============================================================
CREATE TABLE IF NOT EXISTS public.capability_definitions (
  capability TEXT PRIMARY KEY,
  category TEXT NOT NULL,
  description TEXT NOT NULL,
  risk_level TEXT NOT NULL DEFAULT 'normal'
    CHECK (risk_level IN ('normal', 'sensitive', 'critical')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.capability_definitions (capability, category, description, risk_level)
VALUES
  ('contact.read', 'commercial', 'View contacts', 'normal'),
  ('contact.write', 'commercial', 'Create and edit contacts', 'normal'),
  ('contact.archive', 'commercial', 'Archive and restore contacts', 'sensitive'),
  ('contact.import', 'commercial', 'Import contacts in bulk', 'sensitive'),
  ('lead.read', 'commercial', 'View leads', 'normal'),
  ('lead.create', 'commercial', 'Create leads', 'normal'),
  ('lead.update', 'commercial', 'Edit lead qualification data', 'normal'),
  ('lead.assign', 'commercial', 'Assign and transfer leads', 'sensitive'),
  ('lead.disqualify', 'commercial', 'Disqualify leads', 'sensitive'),
  ('lead.convert', 'commercial', 'Convert leads into opportunities', 'sensitive'),
  ('activity.read', 'commercial', 'View commercial activities', 'normal'),
  ('activity.create', 'commercial', 'Record commercial activities', 'normal'),
  ('activity.correct', 'commercial', 'Correct activity content with audit', 'sensitive'),
  ('task.read', 'operations', 'View tasks', 'normal'),
  ('task.create', 'operations', 'Create tasks', 'normal'),
  ('task.update', 'operations', 'Update and complete tasks', 'normal'),
  ('task.delegate', 'operations', 'Delegate tasks to other members', 'sensitive'),
  ('opportunity.read', 'commercial', 'View opportunities', 'normal'),
  ('opportunity.create', 'commercial', 'Create opportunities', 'normal'),
  ('opportunity.update', 'commercial', 'Edit opportunities and stages', 'normal'),
  ('opportunity.close', 'commercial', 'Mark opportunities won or lost', 'sensitive'),
  ('conversation.read', 'service', 'View conversations and messages', 'normal'),
  ('conversation.assign', 'service', 'Assign conversations', 'sensitive'),
  ('message.send', 'service', 'Send individual messages', 'normal'),
  ('broadcast.read', 'marketing', 'View campaigns and broadcasts', 'normal'),
  ('broadcast.create', 'marketing', 'Create campaigns and broadcasts', 'sensitive'),
  ('broadcast.approve', 'marketing', 'Approve a broadcast for sending', 'critical'),
  ('broadcast.send', 'marketing', 'Send broadcasts', 'critical'),
  ('automation.read', 'automation', 'View automations and flows', 'normal'),
  ('automation.manage', 'automation', 'Create, edit and activate automations', 'critical'),
  ('pipeline.read', 'commercial', 'View pipeline configuration', 'normal'),
  ('pipeline.manage', 'commercial', 'Manage pipelines and stages', 'sensitive'),
  ('report.view', 'management', 'View reports', 'normal'),
  ('report.export', 'management', 'Export account data and reports', 'sensitive'),
  ('audit.read', 'management', 'View administrative and domain audit', 'sensitive'),
  ('team.manage', 'administration', 'Manage teams and team membership', 'sensitive'),
  ('member.manage', 'administration', 'Invite and manage account members', 'critical'),
  ('account.settings', 'administration', 'Edit account-wide settings', 'sensitive'),
  ('account.manage', 'administration', 'Manage account policy and capability overrides', 'critical'),
  ('account.transfer', 'administration', 'Transfer account ownership', 'critical'),
  ('account.delete', 'administration', 'Delete the account', 'critical')
ON CONFLICT (capability) DO UPDATE
SET category = EXCLUDED.category,
    description = EXCLUDED.description,
    risk_level = EXCLUDED.risk_level;

CREATE TABLE IF NOT EXISTS public.role_capability_grants (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  role account_role_enum NOT NULL,
  capability TEXT NOT NULL REFERENCES public.capability_definitions(capability) ON DELETE RESTRICT,
  effect capability_effect_enum NOT NULL DEFAULT 'allow',
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(account_id, role, capability)
);

CREATE TABLE IF NOT EXISTS public.member_capability_grants (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  capability TEXT NOT NULL REFERENCES public.capability_definitions(capability) ON DELETE RESTRICT,
  effect capability_effect_enum NOT NULL,
  expires_at TIMESTAMPTZ,
  reason TEXT,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT member_capability_profile_fkey
    FOREIGN KEY (account_id, user_id)
    REFERENCES public.profiles(account_id, user_id) ON DELETE CASCADE,
  UNIQUE(account_id, user_id, capability)
);

CREATE INDEX IF NOT EXISTS idx_role_capability_lookup
  ON public.role_capability_grants(account_id, role, capability)
  WHERE is_active;
CREATE INDEX IF NOT EXISTS idx_member_capability_lookup
  ON public.member_capability_grants(account_id, user_id, capability, expires_at);

-- ============================================================
-- TEAMS
-- ============================================================
CREATE TABLE IF NOT EXISTS public.teams (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  manager_user_id UUID,
  visibility_scope record_visibility_scope_enum NOT NULL DEFAULT 'account',
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  archived_at TIMESTAMPTZ,
  CONSTRAINT teams_manager_profile_fkey
    FOREIGN KEY (account_id, manager_user_id)
    REFERENCES public.profiles(account_id, user_id) ON DELETE RESTRICT,
  UNIQUE(account_id, name),
  UNIQUE(account_id, id)
);

CREATE TABLE IF NOT EXISTS public.team_members (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  team_id UUID NOT NULL,
  user_id UUID NOT NULL,
  team_role team_member_role_enum NOT NULL DEFAULT 'member',
  joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ended_at TIMESTAMPTZ,
  added_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  CONSTRAINT team_members_team_fkey
    FOREIGN KEY (account_id, team_id)
    REFERENCES public.teams(account_id, id) ON DELETE CASCADE,
  CONSTRAINT team_members_profile_fkey
    FOREIGN KEY (account_id, user_id)
    REFERENCES public.profiles(account_id, user_id) ON DELETE CASCADE,
  UNIQUE(team_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_team_members_account_user
  ON public.team_members(account_id, user_id)
  WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_team_members_account_team
  ON public.team_members(account_id, team_id)
  WHERE ended_at IS NULL;

-- ============================================================
-- TEMPORARY DELEGATIONS
-- ============================================================
CREATE TABLE IF NOT EXISTS public.delegations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  from_user_id UUID NOT NULL,
  to_user_id UUID NOT NULL,
  starts_at TIMESTAMPTZ NOT NULL,
  ends_at TIMESTAMPTZ NOT NULL,
  scopes TEXT[] NOT NULL,
  reason TEXT,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  revoked_at TIMESTAMPTZ,
  revoked_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  CONSTRAINT delegations_from_profile_fkey
    FOREIGN KEY (account_id, from_user_id)
    REFERENCES public.profiles(account_id, user_id) ON DELETE RESTRICT,
  CONSTRAINT delegations_to_profile_fkey
    FOREIGN KEY (account_id, to_user_id)
    REFERENCES public.profiles(account_id, user_id) ON DELETE RESTRICT,
  CONSTRAINT delegations_distinct_users_check CHECK (from_user_id <> to_user_id),
  CONSTRAINT delegations_period_check CHECK (ends_at > starts_at),
  CONSTRAINT delegations_scopes_check CHECK (
    cardinality(scopes) > 0
    AND scopes <@ ARRAY['new_leads', 'open_tasks', 'conversations', 'portfolio', 'approvals']::TEXT[]
  )
);

CREATE INDEX IF NOT EXISTS idx_delegations_active_from_scope
  ON public.delegations(account_id, from_user_id, starts_at, ends_at)
  WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_delegations_active_to
  ON public.delegations(account_id, to_user_id, starts_at, ends_at)
  WHERE revoked_at IS NULL;

CREATE OR REPLACE FUNCTION public.prevent_overlapping_delegations()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.revoked_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.delegations d
    WHERE d.account_id = NEW.account_id
      AND d.from_user_id = NEW.from_user_id
      AND d.id <> NEW.id
      AND d.revoked_at IS NULL
      AND tstzrange(d.starts_at, d.ends_at, '[)') && tstzrange(NEW.starts_at, NEW.ends_at, '[)')
      AND d.scopes && NEW.scopes
  ) THEN
    RAISE EXCEPTION 'Overlapping delegation exists for the same scope'
      USING ERRCODE = 'exclusion_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS prevent_overlapping_delegations ON public.delegations;
CREATE TRIGGER prevent_overlapping_delegations
  BEFORE INSERT OR UPDATE ON public.delegations
  FOR EACH ROW EXECUTE FUNCTION public.prevent_overlapping_delegations();

-- ============================================================
-- DEFAULT ROLE PRESETS
-- ============================================================
CREATE OR REPLACE FUNCTION public.seed_account_capability_defaults(target_account_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Viewer: account-wide read access, no mutations.
  INSERT INTO public.role_capability_grants (account_id, role, capability, effect)
  SELECT target_account_id, 'viewer'::account_role_enum, capability, 'allow'::capability_effect_enum
  FROM unnest(ARRAY[
    'contact.read', 'lead.read', 'activity.read', 'task.read',
    'opportunity.read', 'conversation.read', 'broadcast.read',
    'automation.read', 'pipeline.read', 'report.view'
  ]::TEXT[]) AS capability
  ON CONFLICT (account_id, role, capability) DO NOTHING;

  -- Agent: individual sales/service operations, no campaign or automation control.
  INSERT INTO public.role_capability_grants (account_id, role, capability, effect)
  SELECT target_account_id, 'agent'::account_role_enum, capability, 'allow'::capability_effect_enum
  FROM unnest(ARRAY[
    'contact.read', 'contact.write', 'contact.archive', 'contact.import',
    'lead.read', 'lead.create', 'lead.update', 'lead.assign', 'lead.disqualify', 'lead.convert',
    'activity.read', 'activity.create', 'activity.correct',
    'task.read', 'task.create', 'task.update', 'task.delegate',
    'opportunity.read', 'opportunity.create', 'opportunity.update', 'opportunity.close',
    'conversation.read', 'conversation.assign', 'message.send',
    'broadcast.read', 'automation.read', 'pipeline.read', 'report.view'
  ]::TEXT[]) AS capability
  ON CONFLICT (account_id, role, capability) DO NOTHING;

  -- Admin: operational capabilities plus settings, campaigns and governance.
  INSERT INTO public.role_capability_grants (account_id, role, capability, effect)
  SELECT target_account_id, 'admin'::account_role_enum, capability, 'allow'::capability_effect_enum
  FROM unnest(ARRAY[
    'contact.read', 'contact.write', 'contact.archive', 'contact.import',
    'lead.read', 'lead.create', 'lead.update', 'lead.assign', 'lead.disqualify', 'lead.convert',
    'activity.read', 'activity.create', 'activity.correct',
    'task.read', 'task.create', 'task.update', 'task.delegate',
    'opportunity.read', 'opportunity.create', 'opportunity.update', 'opportunity.close',
    'conversation.read', 'conversation.assign', 'message.send',
    'broadcast.read', 'broadcast.create', 'broadcast.approve', 'broadcast.send',
    'automation.read', 'automation.manage',
    'pipeline.read', 'pipeline.manage',
    'report.view', 'report.export', 'audit.read',
    'team.manage', 'member.manage', 'account.settings', 'account.manage'
  ]::TEXT[]) AS capability
  ON CONFLICT (account_id, role, capability) DO NOTHING;

  -- Owner: all registered capabilities.
  INSERT INTO public.role_capability_grants (account_id, role, capability, effect)
  SELECT target_account_id, 'owner'::account_role_enum, capability, 'allow'::capability_effect_enum
  FROM public.capability_definitions
  ON CONFLICT (account_id, role, capability) DO NOTHING;
END;
$$;

ALTER FUNCTION public.seed_account_capability_defaults(UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.seed_account_capability_defaults(UUID) FROM PUBLIC, authenticated;

SELECT public.seed_account_capability_defaults(id) FROM public.accounts;

CREATE OR REPLACE FUNCTION public.on_account_seed_capability_defaults()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.seed_account_capability_defaults(NEW.id);
  RETURN NEW;
END;
$$;

ALTER FUNCTION public.on_account_seed_capability_defaults() OWNER TO postgres;
DROP TRIGGER IF EXISTS seed_capability_defaults_after_account_insert ON public.accounts;
CREATE TRIGGER seed_capability_defaults_after_account_insert
  AFTER INSERT ON public.accounts
  FOR EACH ROW EXECUTE FUNCTION public.on_account_seed_capability_defaults();

-- ============================================================
-- AUTHORIZATION HELPERS
-- ============================================================
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
BEGIN
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
GRANT EXECUTE ON FUNCTION public.has_account_capability(UUID, TEXT) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.shares_active_team(
  target_account_id UUID,
  other_user_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.team_members mine
    JOIN public.team_members theirs
      ON theirs.account_id = mine.account_id
     AND theirs.team_id = mine.team_id
     AND theirs.ended_at IS NULL
    WHERE mine.account_id = target_account_id
      AND mine.user_id = auth.uid()
      AND mine.ended_at IS NULL
      AND theirs.user_id = other_user_id
  );
$$;

ALTER FUNCTION public.shares_active_team(UUID, UUID) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.shares_active_team(UUID, UUID) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.resolve_delegated_user(
  target_account_id UUID,
  original_user_id UUID,
  requested_scope TEXT,
  at_time TIMESTAMPTZ DEFAULT NOW()
)
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (
      SELECT d.to_user_id
      FROM public.delegations d
      WHERE d.account_id = target_account_id
        AND d.from_user_id = original_user_id
        AND requested_scope = ANY(d.scopes)
        AND d.revoked_at IS NULL
        AND at_time >= d.starts_at
        AND at_time < d.ends_at
      ORDER BY d.created_at DESC
      LIMIT 1
    ),
    original_user_id
  );
$$;

ALTER FUNCTION public.resolve_delegated_user(UUID, UUID, TEXT, TIMESTAMPTZ) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.resolve_delegated_user(UUID, UUID, TEXT, TIMESTAMPTZ) TO authenticated, service_role;

-- ============================================================
-- UPDATED_AT / AUDIT TRIGGERS
-- ============================================================
DROP TRIGGER IF EXISTS set_updated_at ON public.role_capability_grants;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.role_capability_grants
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
DROP TRIGGER IF EXISTS set_updated_at ON public.member_capability_grants;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.member_capability_grants
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
DROP TRIGGER IF EXISTS set_updated_at ON public.teams;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.teams
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS capture_role_capability_domain_event ON public.role_capability_grants;
CREATE TRIGGER capture_role_capability_domain_event
  AFTER INSERT OR UPDATE ON public.role_capability_grants
  FOR EACH ROW EXECUTE FUNCTION public.capture_crm_domain_event();
DROP TRIGGER IF EXISTS capture_member_capability_domain_event ON public.member_capability_grants;
CREATE TRIGGER capture_member_capability_domain_event
  AFTER INSERT OR UPDATE ON public.member_capability_grants
  FOR EACH ROW EXECUTE FUNCTION public.capture_crm_domain_event();
DROP TRIGGER IF EXISTS capture_team_domain_event ON public.teams;
CREATE TRIGGER capture_team_domain_event
  AFTER INSERT OR UPDATE ON public.teams
  FOR EACH ROW EXECUTE FUNCTION public.capture_crm_domain_event();
DROP TRIGGER IF EXISTS capture_team_member_domain_event ON public.team_members;
CREATE TRIGGER capture_team_member_domain_event
  AFTER INSERT OR UPDATE ON public.team_members
  FOR EACH ROW EXECUTE FUNCTION public.capture_crm_domain_event();
DROP TRIGGER IF EXISTS capture_delegation_domain_event ON public.delegations;
CREATE TRIGGER capture_delegation_domain_event
  AFTER INSERT OR UPDATE ON public.delegations
  FOR EACH ROW EXECUTE FUNCTION public.capture_crm_domain_event();

-- ============================================================
-- RLS
-- ============================================================
ALTER TABLE public.capability_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_capability_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_capability_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.teams ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.team_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delegations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS capability_definitions_select ON public.capability_definitions;
CREATE POLICY capability_definitions_select ON public.capability_definitions FOR SELECT
  USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS role_capability_grants_select ON public.role_capability_grants;
DROP POLICY IF EXISTS role_capability_grants_insert ON public.role_capability_grants;
DROP POLICY IF EXISTS role_capability_grants_update ON public.role_capability_grants;
DROP POLICY IF EXISTS role_capability_grants_delete ON public.role_capability_grants;
CREATE POLICY role_capability_grants_select ON public.role_capability_grants FOR SELECT
  USING (public.is_account_member(account_id));
CREATE POLICY role_capability_grants_insert ON public.role_capability_grants FOR INSERT
  WITH CHECK (public.is_account_member(account_id, 'owner'));
CREATE POLICY role_capability_grants_update ON public.role_capability_grants FOR UPDATE
  USING (public.is_account_member(account_id, 'owner'))
  WITH CHECK (public.is_account_member(account_id, 'owner'));

DROP POLICY IF EXISTS member_capability_grants_select ON public.member_capability_grants;
DROP POLICY IF EXISTS member_capability_grants_insert ON public.member_capability_grants;
DROP POLICY IF EXISTS member_capability_grants_update ON public.member_capability_grants;
DROP POLICY IF EXISTS member_capability_grants_delete ON public.member_capability_grants;
CREATE POLICY member_capability_grants_select ON public.member_capability_grants FOR SELECT
  USING (user_id = auth.uid() OR public.is_account_member(account_id, 'admin'));
CREATE POLICY member_capability_grants_insert ON public.member_capability_grants FOR INSERT
  WITH CHECK (public.is_account_member(account_id, 'admin'));
CREATE POLICY member_capability_grants_update ON public.member_capability_grants FOR UPDATE
  USING (public.is_account_member(account_id, 'admin'))
  WITH CHECK (public.is_account_member(account_id, 'admin'));

DROP POLICY IF EXISTS teams_select ON public.teams;
DROP POLICY IF EXISTS teams_insert ON public.teams;
DROP POLICY IF EXISTS teams_update ON public.teams;
DROP POLICY IF EXISTS teams_delete ON public.teams;
CREATE POLICY teams_select ON public.teams FOR SELECT
  USING (public.is_account_member(account_id));
CREATE POLICY teams_insert ON public.teams FOR INSERT
  WITH CHECK (public.has_account_capability(account_id, 'team.manage'));
CREATE POLICY teams_update ON public.teams FOR UPDATE
  USING (public.has_account_capability(account_id, 'team.manage'))
  WITH CHECK (public.has_account_capability(account_id, 'team.manage'));

DROP POLICY IF EXISTS team_members_select ON public.team_members;
DROP POLICY IF EXISTS team_members_insert ON public.team_members;
DROP POLICY IF EXISTS team_members_update ON public.team_members;
DROP POLICY IF EXISTS team_members_delete ON public.team_members;
CREATE POLICY team_members_select ON public.team_members FOR SELECT
  USING (public.is_account_member(account_id));
CREATE POLICY team_members_insert ON public.team_members FOR INSERT
  WITH CHECK (public.has_account_capability(account_id, 'team.manage'));
CREATE POLICY team_members_update ON public.team_members FOR UPDATE
  USING (public.has_account_capability(account_id, 'team.manage'))
  WITH CHECK (public.has_account_capability(account_id, 'team.manage'));

DROP POLICY IF EXISTS delegations_select ON public.delegations;
DROP POLICY IF EXISTS delegations_insert ON public.delegations;
DROP POLICY IF EXISTS delegations_update ON public.delegations;
DROP POLICY IF EXISTS delegations_delete ON public.delegations;
CREATE POLICY delegations_select ON public.delegations FOR SELECT
  USING (public.is_account_member(account_id));
CREATE POLICY delegations_insert ON public.delegations FOR INSERT
  WITH CHECK (
    created_by = auth.uid()
    AND (
      from_user_id = auth.uid()
      OR public.has_account_capability(account_id, 'team.manage')
    )
  );
CREATE POLICY delegations_update ON public.delegations FOR UPDATE
  USING (
    from_user_id = auth.uid()
    OR public.has_account_capability(account_id, 'team.manage')
  )
  WITH CHECK (
    from_user_id = auth.uid()
    OR public.has_account_capability(account_id, 'team.manage')
  );

GRANT SELECT ON public.capability_definitions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.role_capability_grants TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.member_capability_grants TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.teams TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.team_members TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.delegations TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.capability_definitions FROM authenticated;
REVOKE DELETE ON public.role_capability_grants FROM authenticated;
REVOKE DELETE ON public.member_capability_grants FROM authenticated;
REVOKE DELETE ON public.teams FROM authenticated;
REVOKE DELETE ON public.team_members FROM authenticated;
REVOKE DELETE ON public.delegations FROM authenticated;

COMMENT ON FUNCTION public.has_account_capability(UUID, TEXT) IS
  'Resolves active member override first, then the account role preset. Deny wins through the unique member override row.';
COMMENT ON TABLE public.delegations IS
  'Temporary, scoped substitution for vacations and absences. Revoke instead of delete.';

COMMIT;
