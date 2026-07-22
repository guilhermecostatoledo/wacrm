-- ============================================================
-- 040_capability_grant_guard.sql
--
-- Prevents an admin from using member capability overrides to elevate their
-- own permissions or to alter the owner's effective access. Role grants are
-- already owner-only through RLS; this trigger protects member overrides.
-- ============================================================

BEGIN;

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
  -- Server-side service_role/postgres maintenance is supervised separately.
  IF current_user <> 'authenticated' THEN
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

DROP TRIGGER IF EXISTS enforce_member_capability_grant_authority
  ON public.member_capability_grants;
CREATE TRIGGER enforce_member_capability_grant_authority
  BEFORE INSERT OR UPDATE ON public.member_capability_grants
  FOR EACH ROW EXECUTE FUNCTION public.enforce_member_capability_grant_authority();

COMMIT;
