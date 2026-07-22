-- ============================================================
-- 037_disable_contact_hard_delete.sql
--
-- Safety containment until the CRM domain introduces audited contact
-- archival and restore. The current contact screen issues DELETE directly
-- from the authenticated browser. Because conversations reference contacts
-- with ON DELETE CASCADE, deleting one contact can also remove its complete
-- message history.
--
-- This migration deliberately does not invent a partial soft-delete model.
-- Archival affects contact lookup, deduplication, inbound webhook resolution,
-- public API behavior, lists, reports, tasks and automations; it belongs in
-- the domain migration planned for Block 1.
--
-- Result:
--   - authenticated clients cannot DELETE contacts, even through a manual
--     PostgREST request;
--   - service_role / postgres remain able to perform supervised maintenance;
--   - SELECT / INSERT / UPDATE policies are unchanged.
--
-- Idempotent and safe to re-run.
-- ============================================================

BEGIN;

-- Remove the operational DELETE policy created by migration 017.
DROP POLICY IF EXISTS contacts_delete ON public.contacts;

-- Defense in depth: RLS denies the operation without a policy, while the
-- column/table privilege revocation also prevents DELETE from authenticated
-- browser sessions if a permissive policy is accidentally added later.
REVOKE DELETE ON TABLE public.contacts FROM authenticated;

COMMENT ON TABLE public.contacts IS
  'CRM contacts. Authenticated hard delete is disabled; use the audited archival command introduced by the CRM domain layer.';

COMMIT;

-- Manual verification until the repository gains an automated SQL/RLS harness:
--
-- 1. Using an authenticated agent JWT, this must return insufficient_privilege
--    or an RLS denial and leave all rows unchanged:
--      DELETE /rest/v1/contacts?id=eq.<contact-id>
--
-- 2. The same user must still be able to SELECT and perform allowed UPDATEs.
--
-- 3. A supervised service_role maintenance request may DELETE only after an
--    explicit impact review and backup. Normal product flows must never use it.
