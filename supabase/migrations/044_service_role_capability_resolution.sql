-- ============================================================
-- 044_service_role_capability_resolution.sql
--
-- Public API keys are authenticated by trusted server routes that use the
-- Supabase service role. The original capability helper returned false when
-- auth.uid() was absent, which correctly denied anonymous/browser calls but
-- also blocked supervised backend commands. Service role/postgres already
-- bypass RLS; treat them as trusted after the route/worker has authenticated
-- its own credential.
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
BEGIN
  IF current_user IN ('service_role', 'postgres') THEN
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

COMMENT ON FUNCTION public.has_account_capability(UUID, TEXT) IS
  'Resolves member override then role preset for browser sessions. Trusted service_role/postgres callers may execute registered capabilities after server-side credential authorization.';

COMMIT;
