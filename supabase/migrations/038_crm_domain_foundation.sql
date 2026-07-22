-- ============================================================
-- 038_crm_domain_foundation.sql
--
-- Block 1 foundation for a commercial CRM domain. Introduces explicit
-- Lead, Activity, Task and DomainEvent concepts while extending contacts
-- and deals without breaking the existing application surfaces.
--
-- Design goals:
--   - every new domain row is account-scoped and RLS protected;
--   - contact archival is transactional and audited;
--   - lead/task state changes are validated by the database;
--   - assignees must belong to the same account;
--   - existing deals and notes are migrated without deleting history;
--   - authenticated hard deletes remain disabled.
--
-- Idempotent where PostgreSQL supports it. Constraint/policy/trigger
-- recreation is guarded explicitly so a partially applied migration can
-- converge safely on a re-run.
-- ============================================================

BEGIN;

-- ============================================================
-- TYPES
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'crm_contact_kind_enum') THEN
    CREATE TYPE crm_contact_kind_enum AS ENUM ('person', 'organization');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'crm_contact_lifecycle_enum') THEN
    CREATE TYPE crm_contact_lifecycle_enum AS ENUM ('prospect', 'customer', 'former_customer', 'partner', 'other');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'lead_status_enum') THEN
    CREATE TYPE lead_status_enum AS ENUM (
      'new', 'assigned', 'attempting_contact', 'connected', 'qualifying',
      'qualified', 'nurturing', 'disqualified', 'reopened', 'converted'
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'crm_priority_enum') THEN
    CREATE TYPE crm_priority_enum AS ENUM ('low', 'normal', 'high', 'urgent');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'crm_activity_type_enum') THEN
    CREATE TYPE crm_activity_type_enum AS ENUM (
      'call', 'whatsapp', 'email', 'meeting', 'visit', 'note',
      'stage_change', 'assignment', 'proposal_sent', 'qualification', 'system'
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'crm_activity_source_enum') THEN
    CREATE TYPE crm_activity_source_enum AS ENUM ('human', 'system', 'integration', 'automation');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'crm_task_status_enum') THEN
    CREATE TYPE crm_task_status_enum AS ENUM ('open', 'in_progress', 'completed', 'cancelled');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'crm_task_type_enum') THEN
    CREATE TYPE crm_task_type_enum AS ENUM (
      'call', 'whatsapp', 'email', 'meeting', 'visit', 'follow_up',
      'qualification', 'proposal', 'custom'
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'domain_event_source_enum') THEN
    CREATE TYPE domain_event_source_enum AS ENUM ('human', 'system', 'integration', 'automation', 'migration');
  END IF;
END $$;

-- ============================================================
-- CONTACT EXTENSION / ARCHIVAL
-- ============================================================
ALTER TABLE public.contacts
  ADD COLUMN IF NOT EXISTS contact_kind crm_contact_kind_enum NOT NULL DEFAULT 'person',
  ADD COLUMN IF NOT EXISTS lifecycle crm_contact_lifecycle_enum NOT NULL DEFAULT 'prospect',
  ADD COLUMN IF NOT EXISTS document_normalized TEXT,
  ADD COLUMN IF NOT EXISTS company_name TEXT,
  ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS archived_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS archive_reason TEXT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'contacts' AND column_name = 'email_normalized'
  ) THEN
    ALTER TABLE public.contacts
      ADD COLUMN email_normalized TEXT
      GENERATED ALWAYS AS (NULLIF(lower(btrim(email)), '')) STORED;
  END IF;
END $$;

UPDATE public.contacts
SET company_name = COALESCE(company_name, company),
    created_by = COALESCE(created_by, user_id)
WHERE company_name IS NULL OR created_by IS NULL;

CREATE INDEX IF NOT EXISTS idx_contacts_account_archived
  ON public.contacts(account_id, archived_at);
CREATE INDEX IF NOT EXISTS idx_contacts_account_email_normalized
  ON public.contacts(account_id, email_normalized)
  WHERE email_normalized IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_contacts_account_document_normalized
  ON public.contacts(account_id, document_normalized)
  WHERE document_normalized IS NOT NULL AND archived_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_contacts_account_id_id
  ON public.contacts(account_id, id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_conversations_account_id_id
  ON public.conversations(account_id, id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_deals_account_id_id
  ON public.deals(account_id, id);

-- ============================================================
-- SETTINGS / REASON TABLES
-- ============================================================
CREATE TABLE IF NOT EXISTS public.lead_sources (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  name TEXT NOT NULL,
  is_system BOOLEAN NOT NULL DEFAULT false,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(account_id, code),
  UNIQUE(account_id, id)
);

CREATE TABLE IF NOT EXISTS public.lead_disqualification_reasons (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  name TEXT NOT NULL,
  is_system BOOLEAN NOT NULL DEFAULT false,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(account_id, code),
  UNIQUE(account_id, id)
);

CREATE TABLE IF NOT EXISTS public.opportunity_loss_reasons (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  name TEXT NOT NULL,
  is_system BOOLEAN NOT NULL DEFAULT false,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(account_id, code),
  UNIQUE(account_id, id)
);

CREATE INDEX IF NOT EXISTS idx_lead_sources_account_active
  ON public.lead_sources(account_id, is_active);
CREATE INDEX IF NOT EXISTS idx_lead_disqualification_reasons_account_active
  ON public.lead_disqualification_reasons(account_id, is_active);
CREATE INDEX IF NOT EXISTS idx_opportunity_loss_reasons_account_active
  ON public.opportunity_loss_reasons(account_id, is_active);

-- ============================================================
-- LEADS
-- ============================================================
CREATE TABLE IF NOT EXISTS public.leads (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  contact_id UUID NOT NULL,
  source_id UUID,
  owner_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  assigned_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  queue_key TEXT,
  status lead_status_enum NOT NULL DEFAULT 'new',
  priority crm_priority_enum NOT NULL DEFAULT 'normal',
  qualification_score SMALLINT CHECK (qualification_score BETWEEN 0 AND 100),
  source_detail JSONB NOT NULL DEFAULT '{}'::jsonb,
  first_response_due_at TIMESTAMPTZ,
  first_contacted_at TIMESTAMPTZ,
  qualified_at TIMESTAMPTZ,
  disqualified_at TIMESTAMPTZ,
  converted_at TIMESTAMPTZ,
  disqualification_reason_id UUID,
  external_key TEXT,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  archived_at TIMESTAMPTZ,
  archived_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  archive_reason TEXT,
  CONSTRAINT leads_contact_account_fkey
    FOREIGN KEY (account_id, contact_id)
    REFERENCES public.contacts(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT leads_source_account_fkey
    FOREIGN KEY (account_id, source_id)
    REFERENCES public.lead_sources(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT leads_disqualification_reason_account_fkey
    FOREIGN KEY (account_id, disqualification_reason_id)
    REFERENCES public.lead_disqualification_reasons(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT leads_owner_or_queue_check CHECK (
    status IN ('converted', 'disqualified') OR owner_id IS NOT NULL OR queue_key IS NOT NULL
  ),
  CONSTRAINT leads_disqualified_state_check CHECK (
    status <> 'disqualified'
    OR (disqualification_reason_id IS NOT NULL AND disqualified_at IS NOT NULL)
  ),
  CONSTRAINT leads_converted_state_check CHECK (
    status <> 'converted' OR converted_at IS NOT NULL
  ),
  UNIQUE(account_id, id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_leads_account_external_key
  ON public.leads(account_id, external_key);
CREATE INDEX IF NOT EXISTS idx_leads_account_status_owner
  ON public.leads(account_id, status, owner_id)
  WHERE archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_leads_account_contact
  ON public.leads(account_id, contact_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_leads_first_response_due
  ON public.leads(account_id, first_response_due_at)
  WHERE archived_at IS NULL AND status NOT IN ('converted', 'disqualified');

-- ============================================================
-- ACTIVITIES
-- ============================================================
CREATE TABLE IF NOT EXISTS public.activities (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  contact_id UUID NOT NULL,
  lead_id UUID,
  opportunity_id UUID,
  conversation_id UUID,
  activity_type crm_activity_type_enum NOT NULL,
  summary TEXT NOT NULL,
  outcome TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  performed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  source crm_activity_source_enum NOT NULL DEFAULT 'human',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  corrected_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  corrected_at TIMESTAMPTZ,
  correction_reason TEXT,
  legacy_source TEXT,
  legacy_id UUID,
  CONSTRAINT activities_contact_account_fkey
    FOREIGN KEY (account_id, contact_id)
    REFERENCES public.contacts(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT activities_lead_account_fkey
    FOREIGN KEY (account_id, lead_id)
    REFERENCES public.leads(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT activities_opportunity_account_fkey
    FOREIGN KEY (account_id, opportunity_id)
    REFERENCES public.deals(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT activities_conversation_account_fkey
    FOREIGN KEY (account_id, conversation_id)
    REFERENCES public.conversations(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT activities_correction_check CHECK (
    corrected_at IS NULL
    OR (corrected_by IS NOT NULL AND NULLIF(btrim(correction_reason), '') IS NOT NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_activities_legacy_source
  ON public.activities(account_id, legacy_source, legacy_id);
CREATE INDEX IF NOT EXISTS idx_activities_contact_occurred
  ON public.activities(account_id, contact_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_activities_lead_occurred
  ON public.activities(account_id, lead_id, occurred_at DESC)
  WHERE lead_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_activities_opportunity_occurred
  ON public.activities(account_id, opportunity_id, occurred_at DESC)
  WHERE opportunity_id IS NOT NULL;

-- ============================================================
-- TASKS
-- ============================================================
CREATE TABLE IF NOT EXISTS public.tasks (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  contact_id UUID NOT NULL,
  lead_id UUID,
  opportunity_id UUID,
  conversation_id UUID,
  assigned_to UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  task_type crm_task_type_enum NOT NULL DEFAULT 'follow_up',
  title TEXT NOT NULL,
  description TEXT,
  priority crm_priority_enum NOT NULL DEFAULT 'normal',
  status crm_task_status_enum NOT NULL DEFAULT 'open',
  due_at TIMESTAMPTZ NOT NULL,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  completion_outcome TEXT,
  cancellation_reason TEXT,
  recurrence_rule TEXT,
  parent_task_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  archived_at TIMESTAMPTZ,
  CONSTRAINT tasks_contact_account_fkey
    FOREIGN KEY (account_id, contact_id)
    REFERENCES public.contacts(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT tasks_lead_account_fkey
    FOREIGN KEY (account_id, lead_id)
    REFERENCES public.leads(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT tasks_opportunity_account_fkey
    FOREIGN KEY (account_id, opportunity_id)
    REFERENCES public.deals(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT tasks_conversation_account_fkey
    FOREIGN KEY (account_id, conversation_id)
    REFERENCES public.conversations(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT tasks_parent_account_fkey
    FOREIGN KEY (account_id, parent_task_id)
    REFERENCES public.tasks(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT tasks_completed_state_check CHECK (
    status <> 'completed' OR completed_at IS NOT NULL
  ),
  CONSTRAINT tasks_cancelled_state_check CHECK (
    status <> 'cancelled'
    OR (cancelled_at IS NOT NULL AND NULLIF(btrim(cancellation_reason), '') IS NOT NULL)
  ),
  UNIQUE(account_id, id)
);

CREATE INDEX IF NOT EXISTS idx_tasks_account_assignee_due
  ON public.tasks(account_id, assigned_to, due_at)
  WHERE archived_at IS NULL AND status IN ('open', 'in_progress');
CREATE INDEX IF NOT EXISTS idx_tasks_account_status_due
  ON public.tasks(account_id, status, due_at)
  WHERE archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_lead
  ON public.tasks(account_id, lead_id)
  WHERE lead_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_opportunity
  ON public.tasks(account_id, opportunity_id)
  WHERE opportunity_id IS NOT NULL;

-- ============================================================
-- DOMAIN EVENTS
-- ============================================================
CREATE TABLE IF NOT EXISTS public.domain_events (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  aggregate_type TEXT NOT NULL,
  aggregate_id UUID NOT NULL,
  event_type TEXT NOT NULL,
  actor_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  source domain_event_source_enum NOT NULL DEFAULT 'human',
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  correlation_id UUID,
  causation_id UUID,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_domain_events_aggregate
  ON public.domain_events(account_id, aggregate_type, aggregate_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_domain_events_event_type
  ON public.domain_events(account_id, event_type, occurred_at DESC);

-- ============================================================
-- OPPORTUNITY (DEALS) EXTENSION
-- ============================================================
ALTER TABLE public.deals
  ADD COLUMN IF NOT EXISTS lead_id UUID,
  ADD COLUMN IF NOT EXISTS probability SMALLINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS won_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS lost_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS loss_reason_id UUID,
  ADD COLUMN IF NOT EXISTS closed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_stage_changed_at TIMESTAMPTZ;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'deals_probability_check') THEN
    ALTER TABLE public.deals
      ADD CONSTRAINT deals_probability_check CHECK (probability BETWEEN 0 AND 100);
  END IF;
END $$;

UPDATE public.deals
SET won_at = COALESCE(won_at, updated_at, created_at)
WHERE status = 'won' AND won_at IS NULL;

UPDATE public.deals
SET lost_at = COALESCE(lost_at, updated_at, created_at)
WHERE status = 'lost' AND lost_at IS NULL;

-- ============================================================
-- DEFAULT CRM SETTINGS PER ACCOUNT
-- ============================================================
CREATE OR REPLACE FUNCTION public.seed_crm_account_defaults(target_account_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.lead_sources (account_id, code, name, is_system)
  VALUES
    (target_account_id, 'manual', 'Manual', true),
    (target_account_id, 'whatsapp', 'WhatsApp', true),
    (target_account_id, 'csv', 'CSV import', true),
    (target_account_id, 'api', 'API', true),
    (target_account_id, 'legacy', 'Legacy migration', true)
  ON CONFLICT (account_id, code) DO NOTHING;

  INSERT INTO public.lead_disqualification_reasons (account_id, code, name, is_system)
  VALUES
    (target_account_id, 'no_interest', 'No interest', true),
    (target_account_id, 'no_contact', 'Unable to contact', true),
    (target_account_id, 'invalid_data', 'Invalid contact data', true),
    (target_account_id, 'outside_profile', 'Outside target profile', true),
    (target_account_id, 'duplicate', 'Duplicate lead', true)
  ON CONFLICT (account_id, code) DO NOTHING;

  INSERT INTO public.opportunity_loss_reasons (account_id, code, name, is_system)
  VALUES
    (target_account_id, 'price', 'Price', true),
    (target_account_id, 'competitor', 'Competitor', true),
    (target_account_id, 'timing', 'Timing', true),
    (target_account_id, 'no_decision', 'No decision', true),
    (target_account_id, 'legacy_unspecified', 'Legacy / unspecified', true)
  ON CONFLICT (account_id, code) DO NOTHING;
END;
$$;

ALTER FUNCTION public.seed_crm_account_defaults(UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.seed_crm_account_defaults(UUID) FROM PUBLIC, authenticated;

SELECT public.seed_crm_account_defaults(id) FROM public.accounts;

CREATE OR REPLACE FUNCTION public.on_account_seed_crm_defaults()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.seed_crm_account_defaults(NEW.id);
  RETURN NEW;
END;
$$;

ALTER FUNCTION public.on_account_seed_crm_defaults() OWNER TO postgres;
DROP TRIGGER IF EXISTS seed_crm_defaults_after_account_insert ON public.accounts;
CREATE TRIGGER seed_crm_defaults_after_account_insert
  AFTER INSERT ON public.accounts
  FOR EACH ROW EXECUTE FUNCTION public.on_account_seed_crm_defaults();

-- ============================================================
-- LEGACY DATA MIGRATION
-- One converted lead per existing deal that still has a contact.
-- ============================================================
INSERT INTO public.leads (
  account_id, contact_id, source_id, owner_id, assigned_by, status,
  priority, first_contacted_at, converted_at, external_key, created_by,
  created_at, updated_at
)
SELECT
  d.account_id,
  d.contact_id,
  ls.id,
  COALESCE(d.assigned_to, d.user_id),
  d.user_id,
  'converted'::lead_status_enum,
  'normal'::crm_priority_enum,
  d.created_at,
  COALESCE(d.updated_at, d.created_at),
  'legacy-deal:' || d.id::text,
  d.user_id,
  d.created_at,
  COALESCE(d.updated_at, d.created_at)
FROM public.deals d
JOIN public.lead_sources ls
  ON ls.account_id = d.account_id AND ls.code = 'legacy'
WHERE d.contact_id IS NOT NULL
  AND d.lead_id IS NULL
ON CONFLICT (account_id, external_key) DO NOTHING;

UPDATE public.deals d
SET lead_id = l.id
FROM public.leads l
WHERE l.account_id = d.account_id
  AND l.external_key = 'legacy-deal:' || d.id::text
  AND d.lead_id IS NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'deals_lead_account_fkey') THEN
    ALTER TABLE public.deals
      ADD CONSTRAINT deals_lead_account_fkey
      FOREIGN KEY (account_id, lead_id)
      REFERENCES public.leads(account_id, id) ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'deals_loss_reason_account_fkey') THEN
    ALTER TABLE public.deals
      ADD CONSTRAINT deals_loss_reason_account_fkey
      FOREIGN KEY (account_id, loss_reason_id)
      REFERENCES public.opportunity_loss_reasons(account_id, id) ON DELETE RESTRICT;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_deals_account_lead
  ON public.deals(account_id, lead_id)
  WHERE lead_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_deals_account_status_close
  ON public.deals(account_id, status, expected_close_date)
  WHERE archived_at IS NULL;

-- Migrate commercial notes into the activity timeline. The original rows stay
-- in place for compatibility; the unique legacy key makes this re-runnable.
INSERT INTO public.activities (
  account_id, contact_id, activity_type, summary, occurred_at,
  performed_by, source, created_at, legacy_source, legacy_id
)
SELECT
  n.account_id,
  n.contact_id,
  'note'::crm_activity_type_enum,
  n.note_text,
  n.created_at,
  n.user_id,
  'human'::crm_activity_source_enum,
  n.created_at,
  'contact_notes',
  n.id
FROM public.contact_notes n
ON CONFLICT (account_id, legacy_source, legacy_id) DO NOTHING;

-- ============================================================
-- STATE / MEMBERSHIP GUARDS
-- ============================================================
CREATE OR REPLACE FUNCTION public.enforce_crm_assignee_membership()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row JSONB := to_jsonb(NEW);
  v_target UUID;
BEGIN
  v_target := CASE TG_TABLE_NAME
    WHEN 'leads' THEN NULLIF(v_row->>'owner_id', '')::uuid
    WHEN 'tasks' THEN NULLIF(v_row->>'assigned_to', '')::uuid
    ELSE NULL
  END;

  IF v_target IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.user_id = v_target AND p.account_id = NEW.account_id
  ) THEN
    RAISE EXCEPTION 'Assignee must be an account member'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  RETURN NEW;
END;
$$;

ALTER FUNCTION public.enforce_crm_assignee_membership() OWNER TO postgres;
DROP TRIGGER IF EXISTS enforce_lead_owner_membership ON public.leads;
CREATE TRIGGER enforce_lead_owner_membership
  BEFORE INSERT OR UPDATE OF owner_id, account_id ON public.leads
  FOR EACH ROW EXECUTE FUNCTION public.enforce_crm_assignee_membership();
DROP TRIGGER IF EXISTS enforce_task_assignee_membership ON public.tasks;
CREATE TRIGGER enforce_task_assignee_membership
  BEFORE INSERT OR UPDATE OF assigned_to, account_id ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.enforce_crm_assignee_membership();

CREATE OR REPLACE FUNCTION public.enforce_lead_status_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  allowed BOOLEAN := false;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  allowed := CASE OLD.status
    WHEN 'new' THEN NEW.status IN ('assigned', 'attempting_contact', 'disqualified')
    WHEN 'assigned' THEN NEW.status IN ('attempting_contact', 'nurturing', 'disqualified')
    WHEN 'attempting_contact' THEN NEW.status IN ('connected', 'nurturing', 'disqualified')
    WHEN 'connected' THEN NEW.status IN ('qualifying', 'nurturing', 'disqualified')
    WHEN 'qualifying' THEN NEW.status IN ('qualified', 'nurturing', 'disqualified')
    WHEN 'qualified' THEN NEW.status IN ('converted', 'disqualified')
    WHEN 'nurturing' THEN NEW.status IN ('attempting_contact', 'disqualified')
    WHEN 'disqualified' THEN NEW.status = 'reopened'
    WHEN 'reopened' THEN NEW.status IN ('attempting_contact', 'qualifying', 'disqualified')
    WHEN 'converted' THEN false
    ELSE false
  END;

  IF NOT allowed THEN
    RAISE EXCEPTION 'Invalid lead status transition: % -> %', OLD.status, NEW.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status = 'connected' AND NEW.first_contacted_at IS NULL THEN
    NEW.first_contacted_at := NOW();
  ELSIF NEW.status = 'qualified' AND NEW.qualified_at IS NULL THEN
    NEW.qualified_at := NOW();
  ELSIF NEW.status = 'disqualified' AND NEW.disqualified_at IS NULL THEN
    NEW.disqualified_at := NOW();
  ELSIF NEW.status = 'converted' AND NEW.converted_at IS NULL THEN
    NEW.converted_at := NOW();
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_lead_status_transition ON public.leads;
CREATE TRIGGER enforce_lead_status_transition
  BEFORE UPDATE OF status ON public.leads
  FOR EACH ROW EXECUTE FUNCTION public.enforce_lead_status_transition();

CREATE OR REPLACE FUNCTION public.enforce_task_status_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  allowed BOOLEAN := false;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  allowed := CASE OLD.status
    WHEN 'open' THEN NEW.status IN ('in_progress', 'completed', 'cancelled')
    WHEN 'in_progress' THEN NEW.status IN ('open', 'completed', 'cancelled')
    WHEN 'completed' THEN false
    WHEN 'cancelled' THEN NEW.status = 'open'
    ELSE false
  END;

  IF NOT allowed THEN
    RAISE EXCEPTION 'Invalid task status transition: % -> %', OLD.status, NEW.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status = 'in_progress' AND NEW.started_at IS NULL THEN
    NEW.started_at := NOW();
  ELSIF NEW.status = 'completed' AND NEW.completed_at IS NULL THEN
    NEW.completed_at := NOW();
  ELSIF NEW.status = 'cancelled' AND NEW.cancelled_at IS NULL THEN
    NEW.cancelled_at := NOW();
  ELSIF NEW.status = 'open' THEN
    NEW.completed_at := NULL;
    NEW.cancelled_at := NULL;
    NEW.cancellation_reason := NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_task_status_transition ON public.tasks;
CREATE TRIGGER enforce_task_status_transition
  BEFORE UPDATE OF status ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.enforce_task_status_transition();

CREATE OR REPLACE FUNCTION public.enforce_activity_correction()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.account_id IS DISTINCT FROM OLD.account_id
     OR NEW.contact_id IS DISTINCT FROM OLD.contact_id
     OR NEW.lead_id IS DISTINCT FROM OLD.lead_id
     OR NEW.opportunity_id IS DISTINCT FROM OLD.opportunity_id
     OR NEW.conversation_id IS DISTINCT FROM OLD.conversation_id
     OR NEW.activity_type IS DISTINCT FROM OLD.activity_type
     OR NEW.occurred_at IS DISTINCT FROM OLD.occurred_at
     OR NEW.performed_by IS DISTINCT FROM OLD.performed_by
     OR NEW.source IS DISTINCT FROM OLD.source
  THEN
    RAISE EXCEPTION 'Activity identity and attribution fields are immutable'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.summary IS DISTINCT FROM OLD.summary
     OR NEW.outcome IS DISTINCT FROM OLD.outcome
     OR NEW.metadata IS DISTINCT FROM OLD.metadata
  THEN
    IF NEW.corrected_at IS NULL OR NEW.corrected_by IS NULL
       OR NULLIF(btrim(NEW.correction_reason), '') IS NULL
    THEN
      RAISE EXCEPTION 'Activity corrections require corrected_at, corrected_by and correction_reason'
        USING ERRCODE = 'check_violation';
    END IF;
    IF current_user = 'authenticated' AND NEW.corrected_by IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'corrected_by must match the authenticated user'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_activity_correction ON public.activities;
CREATE TRIGGER enforce_activity_correction
  BEFORE UPDATE ON public.activities
  FOR EACH ROW EXECUTE FUNCTION public.enforce_activity_correction();

-- Force authenticated clients to use the audited archive/restore commands.
CREATE OR REPLACE FUNCTION public.enforce_contact_archival_command()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF current_user = 'authenticated'
     AND (
       NEW.archived_at IS DISTINCT FROM OLD.archived_at
       OR NEW.archived_by IS DISTINCT FROM OLD.archived_by
       OR NEW.archive_reason IS DISTINCT FROM OLD.archive_reason
     )
  THEN
    RAISE EXCEPTION 'Use archive_contact or restore_contact for archival changes'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_contact_archival_command ON public.contacts;
CREATE TRIGGER enforce_contact_archival_command
  BEFORE UPDATE OF archived_at, archived_by, archive_reason ON public.contacts
  FOR EACH ROW EXECUTE FUNCTION public.enforce_contact_archival_command();

-- ============================================================
-- UPDATED_AT TRIGGERS
-- ============================================================
DROP TRIGGER IF EXISTS set_updated_at ON public.lead_sources;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.lead_sources
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
DROP TRIGGER IF EXISTS set_updated_at ON public.lead_disqualification_reasons;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.lead_disqualification_reasons
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
DROP TRIGGER IF EXISTS set_updated_at ON public.opportunity_loss_reasons;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.opportunity_loss_reasons
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
DROP TRIGGER IF EXISTS set_updated_at ON public.leads;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.leads
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
DROP TRIGGER IF EXISTS set_updated_at ON public.tasks;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================================
-- AUDITED ARCHIVE / RESTORE COMMANDS
-- ============================================================
CREATE OR REPLACE FUNCTION public.archive_contact(
  p_contact_id UUID,
  p_reason TEXT
)
RETURNS public.contacts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_contact public.contacts%ROWTYPE;
  v_actor UUID := auth.uid();
BEGIN
  IF NULLIF(btrim(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Archive reason is required' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_contact
  FROM public.contacts
  WHERE id = p_contact_id
    AND public.is_account_member(account_id, 'agent')
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contact not found or access denied' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_contact.archived_at IS NOT NULL THEN
    RETURN v_contact;
  END IF;

  UPDATE public.contacts
  SET archived_at = NOW(), archived_by = v_actor, archive_reason = btrim(p_reason)
  WHERE id = p_contact_id
  RETURNING * INTO v_contact;

  UPDATE public.leads
  SET archived_at = COALESCE(archived_at, NOW()),
      archived_by = COALESCE(archived_by, v_actor),
      archive_reason = COALESCE(archive_reason, 'Contact archived: ' || btrim(p_reason))
  WHERE account_id = v_contact.account_id
    AND contact_id = p_contact_id
    AND archived_at IS NULL;

  UPDATE public.tasks
  SET status = 'cancelled',
      cancelled_at = COALESCE(cancelled_at, NOW()),
      cancellation_reason = COALESCE(cancellation_reason, 'Contact archived: ' || btrim(p_reason)),
      archived_at = COALESCE(archived_at, NOW())
  WHERE account_id = v_contact.account_id
    AND contact_id = p_contact_id
    AND status IN ('open', 'in_progress');

  INSERT INTO public.activities (
    account_id, contact_id, activity_type, summary, outcome,
    occurred_at, performed_by, source
  ) VALUES (
    v_contact.account_id, p_contact_id, 'system', 'Contact archived', btrim(p_reason),
    NOW(), v_actor, 'system'
  );

  RETURN v_contact;
END;
$$;

ALTER FUNCTION public.archive_contact(UUID, TEXT) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.archive_contact(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.archive_contact(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.restore_contact(p_contact_id UUID)
RETURNS public.contacts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_contact public.contacts%ROWTYPE;
  v_actor UUID := auth.uid();
BEGIN
  SELECT * INTO v_contact
  FROM public.contacts
  WHERE id = p_contact_id
    AND public.is_account_member(account_id, 'agent')
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contact not found or access denied' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE public.contacts
  SET archived_at = NULL, archived_by = NULL, archive_reason = NULL
  WHERE id = p_contact_id
  RETURNING * INTO v_contact;

  INSERT INTO public.activities (
    account_id, contact_id, activity_type, summary,
    occurred_at, performed_by, source
  ) VALUES (
    v_contact.account_id, p_contact_id, 'system', 'Contact restored',
    NOW(), v_actor, 'system'
  );

  RETURN v_contact;
END;
$$;

ALTER FUNCTION public.restore_contact(UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.restore_contact(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.restore_contact(UUID) TO authenticated;

-- ============================================================
-- DOMAIN EVENT CAPTURE
-- ============================================================
CREATE OR REPLACE FUNCTION public.capture_crm_domain_event()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new JSONB := to_jsonb(NEW);
  v_old JSONB := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
  v_account_id UUID := (v_new->>'account_id')::uuid;
  v_aggregate_type TEXT;
  v_event_type TEXT;
  v_source domain_event_source_enum := CASE
    WHEN auth.uid() IS NULL THEN 'system'::domain_event_source_enum
    ELSE 'human'::domain_event_source_enum
  END;
BEGIN
  v_aggregate_type := CASE TG_TABLE_NAME
    WHEN 'deals' THEN 'opportunity'
    WHEN 'activities' THEN 'activity'
    WHEN 'tasks' THEN 'task'
    WHEN 'leads' THEN 'lead'
    WHEN 'contacts' THEN 'contact'
    ELSE TG_TABLE_NAME
  END;

  IF TG_OP = 'INSERT' THEN
    v_event_type := v_aggregate_type || '.created';
  ELSIF (v_new->>'archived_at') IS DISTINCT FROM (v_old->>'archived_at') THEN
    v_event_type := v_aggregate_type || CASE
      WHEN v_new->>'archived_at' IS NULL THEN '.restored' ELSE '.archived' END;
  ELSIF (v_new->>'status') IS DISTINCT FROM (v_old->>'status') THEN
    v_event_type := v_aggregate_type || '.status_changed';
  ELSIF (v_new->>'owner_id') IS DISTINCT FROM (v_old->>'owner_id')
     OR (v_new->>'assigned_to') IS DISTINCT FROM (v_old->>'assigned_to') THEN
    v_event_type := v_aggregate_type || '.assigned';
  ELSIF (v_new->>'stage_id') IS DISTINCT FROM (v_old->>'stage_id') THEN
    v_event_type := v_aggregate_type || '.stage_changed';
  ELSE
    v_event_type := v_aggregate_type || '.updated';
  END IF;

  INSERT INTO public.domain_events (
    account_id, aggregate_type, aggregate_id, event_type,
    actor_user_id, source, payload
  ) VALUES (
    v_account_id,
    v_aggregate_type,
    (v_new->>'id')::uuid,
    v_event_type,
    auth.uid(),
    v_source,
    jsonb_build_object('operation', TG_OP, 'old', v_old, 'new', v_new)
  );

  RETURN NEW;
END;
$$;

ALTER FUNCTION public.capture_crm_domain_event() OWNER TO postgres;

DROP TRIGGER IF EXISTS capture_contact_domain_event ON public.contacts;
CREATE TRIGGER capture_contact_domain_event
  AFTER INSERT OR UPDATE ON public.contacts
  FOR EACH ROW EXECUTE FUNCTION public.capture_crm_domain_event();
DROP TRIGGER IF EXISTS capture_lead_domain_event ON public.leads;
CREATE TRIGGER capture_lead_domain_event
  AFTER INSERT OR UPDATE ON public.leads
  FOR EACH ROW EXECUTE FUNCTION public.capture_crm_domain_event();
DROP TRIGGER IF EXISTS capture_activity_domain_event ON public.activities;
CREATE TRIGGER capture_activity_domain_event
  AFTER INSERT OR UPDATE ON public.activities
  FOR EACH ROW EXECUTE FUNCTION public.capture_crm_domain_event();
DROP TRIGGER IF EXISTS capture_task_domain_event ON public.tasks;
CREATE TRIGGER capture_task_domain_event
  AFTER INSERT OR UPDATE ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.capture_crm_domain_event();
DROP TRIGGER IF EXISTS capture_deal_domain_event ON public.deals;
CREATE TRIGGER capture_deal_domain_event
  AFTER INSERT OR UPDATE ON public.deals
  FOR EACH ROW EXECUTE FUNCTION public.capture_crm_domain_event();

-- ============================================================
-- NOTIFICATION EXTENSION
-- ============================================================
ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS lead_id UUID REFERENCES public.leads(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS task_id UUID REFERENCES public.tasks(id) ON DELETE SET NULL;

ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_type_check CHECK (
    type IN ('conversation_assigned', 'lead_assigned', 'lead_sla_breached', 'task_assigned', 'task_due')
  );

CREATE INDEX IF NOT EXISTS idx_notifications_lead ON public.notifications(lead_id)
  WHERE lead_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_notifications_task ON public.notifications(task_id)
  WHERE task_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.notify_lead_assigned()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_contact_name TEXT;
BEGIN
  IF NEW.owner_id IS NULL
     OR (TG_OP = 'UPDATE' AND NEW.owner_id IS NOT DISTINCT FROM OLD.owner_id)
     OR (auth.uid() IS NOT NULL AND auth.uid() = NEW.owner_id)
  THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(NULLIF(name, ''), phone) INTO v_contact_name
  FROM public.contacts WHERE id = NEW.contact_id;

  INSERT INTO public.notifications (
    account_id, user_id, type, lead_id, contact_id,
    actor_user_id, title, body
  ) VALUES (
    NEW.account_id, NEW.owner_id, 'lead_assigned', NEW.id, NEW.contact_id,
    auth.uid(), 'New lead assigned', 'Lead for ' || COALESCE(v_contact_name, 'contact') || ' was assigned to you'
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Failed to create lead assignment notification for %: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_lead_assigned ON public.leads;
CREATE TRIGGER notify_lead_assigned
  AFTER INSERT OR UPDATE OF owner_id ON public.leads
  FOR EACH ROW EXECUTE FUNCTION public.notify_lead_assigned();

CREATE OR REPLACE FUNCTION public.notify_task_assigned()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.assigned_to IS NULL
     OR (TG_OP = 'UPDATE' AND NEW.assigned_to IS NOT DISTINCT FROM OLD.assigned_to)
     OR (auth.uid() IS NOT NULL AND auth.uid() = NEW.assigned_to)
  THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.notifications (
    account_id, user_id, type, task_id, lead_id, contact_id,
    actor_user_id, title, body
  ) VALUES (
    NEW.account_id, NEW.assigned_to, 'task_assigned', NEW.id, NEW.lead_id, NEW.contact_id,
    auth.uid(), 'New task assigned', NEW.title
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Failed to create task assignment notification for %: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_task_assigned ON public.tasks;
CREATE TRIGGER notify_task_assigned
  AFTER INSERT OR UPDATE OF assigned_to ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.notify_task_assigned();

-- ============================================================
-- RLS
-- ============================================================
ALTER TABLE public.lead_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lead_disqualification_reasons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.opportunity_loss_reasons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.leads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.domain_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lead_sources_select ON public.lead_sources;
DROP POLICY IF EXISTS lead_sources_insert ON public.lead_sources;
DROP POLICY IF EXISTS lead_sources_update ON public.lead_sources;
DROP POLICY IF EXISTS lead_sources_delete ON public.lead_sources;
CREATE POLICY lead_sources_select ON public.lead_sources FOR SELECT
  USING (public.is_account_member(account_id));
CREATE POLICY lead_sources_insert ON public.lead_sources FOR INSERT
  WITH CHECK (public.is_account_member(account_id, 'admin'));
CREATE POLICY lead_sources_update ON public.lead_sources FOR UPDATE
  USING (public.is_account_member(account_id, 'admin'))
  WITH CHECK (public.is_account_member(account_id, 'admin'));

DROP POLICY IF EXISTS lead_disqualification_reasons_select ON public.lead_disqualification_reasons;
DROP POLICY IF EXISTS lead_disqualification_reasons_insert ON public.lead_disqualification_reasons;
DROP POLICY IF EXISTS lead_disqualification_reasons_update ON public.lead_disqualification_reasons;
DROP POLICY IF EXISTS lead_disqualification_reasons_delete ON public.lead_disqualification_reasons;
CREATE POLICY lead_disqualification_reasons_select ON public.lead_disqualification_reasons FOR SELECT
  USING (public.is_account_member(account_id));
CREATE POLICY lead_disqualification_reasons_insert ON public.lead_disqualification_reasons FOR INSERT
  WITH CHECK (public.is_account_member(account_id, 'admin'));
CREATE POLICY lead_disqualification_reasons_update ON public.lead_disqualification_reasons FOR UPDATE
  USING (public.is_account_member(account_id, 'admin'))
  WITH CHECK (public.is_account_member(account_id, 'admin'));

DROP POLICY IF EXISTS opportunity_loss_reasons_select ON public.opportunity_loss_reasons;
DROP POLICY IF EXISTS opportunity_loss_reasons_insert ON public.opportunity_loss_reasons;
DROP POLICY IF EXISTS opportunity_loss_reasons_update ON public.opportunity_loss_reasons;
DROP POLICY IF EXISTS opportunity_loss_reasons_delete ON public.opportunity_loss_reasons;
CREATE POLICY opportunity_loss_reasons_select ON public.opportunity_loss_reasons FOR SELECT
  USING (public.is_account_member(account_id));
CREATE POLICY opportunity_loss_reasons_insert ON public.opportunity_loss_reasons FOR INSERT
  WITH CHECK (public.is_account_member(account_id, 'admin'));
CREATE POLICY opportunity_loss_reasons_update ON public.opportunity_loss_reasons FOR UPDATE
  USING (public.is_account_member(account_id, 'admin'))
  WITH CHECK (public.is_account_member(account_id, 'admin'));

DROP POLICY IF EXISTS leads_select ON public.leads;
DROP POLICY IF EXISTS leads_insert ON public.leads;
DROP POLICY IF EXISTS leads_update ON public.leads;
DROP POLICY IF EXISTS leads_delete ON public.leads;
CREATE POLICY leads_select ON public.leads FOR SELECT
  USING (public.is_account_member(account_id));
CREATE POLICY leads_insert ON public.leads FOR INSERT
  WITH CHECK (public.is_account_member(account_id, 'agent'));
CREATE POLICY leads_update ON public.leads FOR UPDATE
  USING (public.is_account_member(account_id, 'agent'))
  WITH CHECK (public.is_account_member(account_id, 'agent'));

DROP POLICY IF EXISTS activities_select ON public.activities;
DROP POLICY IF EXISTS activities_insert ON public.activities;
DROP POLICY IF EXISTS activities_update ON public.activities;
DROP POLICY IF EXISTS activities_delete ON public.activities;
CREATE POLICY activities_select ON public.activities FOR SELECT
  USING (public.is_account_member(account_id));
CREATE POLICY activities_insert ON public.activities FOR INSERT
  WITH CHECK (public.is_account_member(account_id, 'agent'));
CREATE POLICY activities_update ON public.activities FOR UPDATE
  USING (public.is_account_member(account_id, 'agent'))
  WITH CHECK (public.is_account_member(account_id, 'agent'));

DROP POLICY IF EXISTS tasks_select ON public.tasks;
DROP POLICY IF EXISTS tasks_insert ON public.tasks;
DROP POLICY IF EXISTS tasks_update ON public.tasks;
DROP POLICY IF EXISTS tasks_delete ON public.tasks;
CREATE POLICY tasks_select ON public.tasks FOR SELECT
  USING (public.is_account_member(account_id));
CREATE POLICY tasks_insert ON public.tasks FOR INSERT
  WITH CHECK (public.is_account_member(account_id, 'agent'));
CREATE POLICY tasks_update ON public.tasks FOR UPDATE
  USING (public.is_account_member(account_id, 'agent'))
  WITH CHECK (public.is_account_member(account_id, 'agent'));

DROP POLICY IF EXISTS domain_events_select ON public.domain_events;
DROP POLICY IF EXISTS domain_events_insert ON public.domain_events;
DROP POLICY IF EXISTS domain_events_update ON public.domain_events;
DROP POLICY IF EXISTS domain_events_delete ON public.domain_events;
CREATE POLICY domain_events_select ON public.domain_events FOR SELECT
  USING (public.is_account_member(account_id));

-- Explicit privileges: RLS determines row access; DELETE stays unavailable.
GRANT SELECT, INSERT, UPDATE ON public.lead_sources TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.lead_disqualification_reasons TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.opportunity_loss_reasons TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.leads TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.activities TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.tasks TO authenticated;
GRANT SELECT ON public.domain_events TO authenticated;
REVOKE DELETE ON public.lead_sources FROM authenticated;
REVOKE DELETE ON public.lead_disqualification_reasons FROM authenticated;
REVOKE DELETE ON public.opportunity_loss_reasons FROM authenticated;
REVOKE DELETE ON public.leads FROM authenticated;
REVOKE DELETE ON public.activities FROM authenticated;
REVOKE DELETE ON public.tasks FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.domain_events FROM authenticated;

COMMENT ON TABLE public.leads IS 'Commercial interest cycles. A durable contact may have multiple leads over time.';
COMMENT ON TABLE public.activities IS 'Commercial activity timeline; raw WhatsApp messages remain in messages.';
COMMENT ON TABLE public.tasks IS 'Future actionable work linked to a contact and optionally a lead/opportunity/conversation.';
COMMENT ON TABLE public.domain_events IS 'Append-only audit/event stream generated by domain changes.';

COMMIT;
