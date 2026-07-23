-- ============================================================
-- 048_marketing_campaigns_attribution_consent.sql
-- ============================================================

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'marketing_campaign_status_enum') THEN
    CREATE TYPE marketing_campaign_status_enum AS ENUM ('draft', 'active', 'paused', 'completed', 'archived');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'channel_consent_status_enum') THEN
    CREATE TYPE channel_consent_status_enum AS ENUM ('unknown', 'opted_in', 'transactional_only', 'opted_out');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'marketing_touchpoint_event_enum') THEN
    CREATE TYPE marketing_touchpoint_event_enum AS ENUM (
      'impression', 'click', 'form_submission', 'message_sent',
      'delivered', 'read', 'reply', 'conversion', 'opt_out'
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'attribution_model_enum') THEN
    CREATE TYPE attribution_model_enum AS ENUM ('first_touch', 'last_touch');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.marketing_campaigns (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  objective TEXT,
  channel TEXT NOT NULL DEFAULT 'whatsapp',
  status marketing_campaign_status_enum NOT NULL DEFAULT 'draft',
  budget NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (budget >= 0),
  currency TEXT NOT NULL DEFAULT 'BRL',
  starts_at TIMESTAMPTZ,
  ends_at TIMESTAMPTZ,
  utm_source TEXT,
  utm_medium TEXT,
  utm_campaign TEXT,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  archived_at TIMESTAMPTZ,
  UNIQUE(account_id, name),
  UNIQUE(account_id, id),
  CONSTRAINT marketing_campaign_period_check CHECK (
    ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at
  )
);

CREATE TABLE IF NOT EXISTS public.contact_channel_consents (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  contact_id UUID NOT NULL,
  channel TEXT NOT NULL CHECK (channel IN ('whatsapp', 'email', 'sms', 'phone')),
  status channel_consent_status_enum NOT NULL DEFAULT 'unknown',
  source TEXT,
  proof JSONB NOT NULL DEFAULT '{}'::jsonb,
  consented_at TIMESTAMPTZ,
  opted_out_at TIMESTAMPTZ,
  updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT contact_consents_contact_fkey
    FOREIGN KEY (account_id, contact_id)
    REFERENCES public.contacts(account_id, id) ON DELETE CASCADE,
  UNIQUE(account_id, contact_id, channel)
);

CREATE TABLE IF NOT EXISTS public.marketing_touchpoints (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  campaign_id UUID NOT NULL,
  contact_id UUID NOT NULL,
  lead_id UUID,
  opportunity_id UUID,
  event_type marketing_touchpoint_event_enum NOT NULL,
  channel TEXT NOT NULL,
  external_event_id TEXT,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT marketing_touchpoints_campaign_fkey
    FOREIGN KEY (account_id, campaign_id)
    REFERENCES public.marketing_campaigns(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT marketing_touchpoints_contact_fkey
    FOREIGN KEY (account_id, contact_id)
    REFERENCES public.contacts(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT marketing_touchpoints_lead_fkey
    FOREIGN KEY (account_id, lead_id)
    REFERENCES public.leads(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT marketing_touchpoints_opportunity_fkey
    FOREIGN KEY (account_id, opportunity_id)
    REFERENCES public.deals(account_id, id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_marketing_touchpoint_external_event
  ON public.marketing_touchpoints(account_id, channel, external_event_id)
  WHERE external_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_marketing_touchpoints_contact_time
  ON public.marketing_touchpoints(account_id, contact_id, occurred_at);
CREATE INDEX IF NOT EXISTS idx_marketing_touchpoints_campaign_time
  ON public.marketing_touchpoints(account_id, campaign_id, occurred_at);

CREATE TABLE IF NOT EXISTS public.opportunity_attributions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  opportunity_id UUID NOT NULL,
  model attribution_model_enum NOT NULL,
  campaign_id UUID NOT NULL,
  touchpoint_id UUID NOT NULL REFERENCES public.marketing_touchpoints(id) ON DELETE RESTRICT,
  attributed_revenue NUMERIC(14,2) NOT NULL DEFAULT 0,
  calculated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT opportunity_attributions_deal_fkey
    FOREIGN KEY (account_id, opportunity_id)
    REFERENCES public.deals(account_id, id) ON DELETE RESTRICT,
  CONSTRAINT opportunity_attributions_campaign_fkey
    FOREIGN KEY (account_id, campaign_id)
    REFERENCES public.marketing_campaigns(account_id, id) ON DELETE RESTRICT,
  UNIQUE(account_id, opportunity_id, model)
);

ALTER TABLE public.broadcasts
  ADD COLUMN IF NOT EXISTS campaign_id UUID;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'broadcasts_campaign_account_fkey') THEN
    ALTER TABLE public.broadcasts
      ADD CONSTRAINT broadcasts_campaign_account_fkey
      FOREIGN KEY (account_id, campaign_id)
      REFERENCES public.marketing_campaigns(account_id, id) ON DELETE RESTRICT;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.can_contact_channel(
  p_account_id UUID,
  p_contact_id UUID,
  p_channel TEXT,
  p_purpose TEXT DEFAULT 'transactional'
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_purpose = 'marketing' THEN COALESCE(c.status = 'opted_in', false)
    ELSE COALESCE(c.status IN ('opted_in', 'transactional_only'), true)
  END
  FROM (SELECT 1) seed
  LEFT JOIN public.contact_channel_consents c
    ON c.account_id = p_account_id
   AND c.contact_id = p_contact_id
   AND c.channel = p_channel;
$$;

ALTER FUNCTION public.can_contact_channel(UUID, UUID, TEXT, TEXT) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.can_contact_channel(UUID, UUID, TEXT, TEXT)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.enforce_broadcast_recipient_consent()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id UUID;
BEGIN
  SELECT b.account_id INTO v_account_id
  FROM public.broadcasts b WHERE b.id = NEW.broadcast_id;

  IF v_account_id IS NULL OR NOT public.can_contact_channel(
    v_account_id, NEW.contact_id, 'whatsapp', 'marketing'
  ) THEN
    RAISE EXCEPTION 'Contact has not opted in to WhatsApp marketing'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_broadcast_recipient_consent ON public.broadcast_recipients;
CREATE TRIGGER enforce_broadcast_recipient_consent
  BEFORE INSERT ON public.broadcast_recipients
  FOR EACH ROW EXECUTE FUNCTION public.enforce_broadcast_recipient_consent();

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
DECLARE
  v_touchpoint public.marketing_touchpoints%ROWTYPE;
BEGIN
  IF current_user = 'authenticated'
     AND NOT public.has_account_capability(p_account_id, 'broadcast.create')
  THEN
    RAISE EXCEPTION 'Missing campaign write capability'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  INSERT INTO public.marketing_touchpoints (
    account_id, campaign_id, contact_id, lead_id, opportunity_id,
    event_type, channel, external_event_id, occurred_at, metadata
  ) VALUES (
    p_account_id, p_campaign_id, p_contact_id, p_lead_id, p_opportunity_id,
    p_event_type, p_channel, p_external_event_id, p_occurred_at,
    COALESCE(p_metadata, '{}'::jsonb)
  )
  ON CONFLICT (account_id, channel, external_event_id)
    WHERE external_event_id IS NOT NULL
  DO UPDATE SET opportunity_id = COALESCE(EXCLUDED.opportunity_id, public.marketing_touchpoints.opportunity_id)
  RETURNING * INTO v_touchpoint;

  RETURN v_touchpoint;
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

CREATE OR REPLACE FUNCTION public.refresh_opportunity_attribution(p_opportunity_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deal public.deals%ROWTYPE;
  v_first public.marketing_touchpoints%ROWTYPE;
  v_last public.marketing_touchpoints%ROWTYPE;
BEGIN
  SELECT * INTO v_deal FROM public.deals WHERE id = p_opportunity_id;
  IF NOT FOUND OR v_deal.status <> 'won' OR v_deal.contact_id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_first
  FROM public.marketing_touchpoints t
  WHERE t.account_id = v_deal.account_id
    AND t.contact_id = v_deal.contact_id
    AND t.occurred_at <= COALESCE(v_deal.won_at, NOW())
  ORDER BY t.occurred_at ASC, t.id ASC
  LIMIT 1;

  SELECT * INTO v_last
  FROM public.marketing_touchpoints t
  WHERE t.account_id = v_deal.account_id
    AND t.contact_id = v_deal.contact_id
    AND t.occurred_at <= COALESCE(v_deal.won_at, NOW())
  ORDER BY t.occurred_at DESC, t.id DESC
  LIMIT 1;

  IF v_first.id IS NOT NULL THEN
    INSERT INTO public.opportunity_attributions (
      account_id, opportunity_id, model, campaign_id, touchpoint_id,
      attributed_revenue, calculated_at
    ) VALUES (
      v_deal.account_id, v_deal.id, 'first_touch', v_first.campaign_id,
      v_first.id, v_deal.value, NOW()
    )
    ON CONFLICT (account_id, opportunity_id, model) DO UPDATE
    SET campaign_id = EXCLUDED.campaign_id,
        touchpoint_id = EXCLUDED.touchpoint_id,
        attributed_revenue = EXCLUDED.attributed_revenue,
        calculated_at = EXCLUDED.calculated_at;
  END IF;

  IF v_last.id IS NOT NULL THEN
    INSERT INTO public.opportunity_attributions (
      account_id, opportunity_id, model, campaign_id, touchpoint_id,
      attributed_revenue, calculated_at
    ) VALUES (
      v_deal.account_id, v_deal.id, 'last_touch', v_last.campaign_id,
      v_last.id, v_deal.value, NOW()
    )
    ON CONFLICT (account_id, opportunity_id, model) DO UPDATE
    SET campaign_id = EXCLUDED.campaign_id,
        touchpoint_id = EXCLUDED.touchpoint_id,
        attributed_revenue = EXCLUDED.attributed_revenue,
        calculated_at = EXCLUDED.calculated_at;
  END IF;
END;
$$;

ALTER FUNCTION public.refresh_opportunity_attribution(UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.refresh_opportunity_attribution(UUID)
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_opportunity_attribution(UUID) TO service_role;

CREATE OR REPLACE FUNCTION public.on_opportunity_won_refresh_attribution()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'won' AND (OLD.status IS DISTINCT FROM NEW.status OR OLD.value IS DISTINCT FROM NEW.value) THEN
    PERFORM public.refresh_opportunity_attribution(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS refresh_attribution_on_opportunity_won ON public.deals;
CREATE TRIGGER refresh_attribution_on_opportunity_won
  AFTER UPDATE OF status, value ON public.deals
  FOR EACH ROW EXECUTE FUNCTION public.on_opportunity_won_refresh_attribution();

ALTER TABLE public.marketing_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contact_channel_consents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketing_touchpoints ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.opportunity_attributions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS marketing_campaigns_select ON public.marketing_campaigns;
DROP POLICY IF EXISTS marketing_campaigns_insert ON public.marketing_campaigns;
DROP POLICY IF EXISTS marketing_campaigns_update ON public.marketing_campaigns;
CREATE POLICY marketing_campaigns_select ON public.marketing_campaigns FOR SELECT
  USING (public.is_account_member(account_id));
CREATE POLICY marketing_campaigns_insert ON public.marketing_campaigns FOR INSERT
  WITH CHECK (public.has_account_capability(account_id, 'broadcast.create'));
CREATE POLICY marketing_campaigns_update ON public.marketing_campaigns FOR UPDATE
  USING (public.has_account_capability(account_id, 'broadcast.create'))
  WITH CHECK (public.has_account_capability(account_id, 'broadcast.create'));

DROP POLICY IF EXISTS contact_consents_select ON public.contact_channel_consents;
DROP POLICY IF EXISTS contact_consents_insert ON public.contact_channel_consents;
DROP POLICY IF EXISTS contact_consents_update ON public.contact_channel_consents;
CREATE POLICY contact_consents_select ON public.contact_channel_consents FOR SELECT
  USING (public.is_account_member(account_id));
CREATE POLICY contact_consents_insert ON public.contact_channel_consents FOR INSERT
  WITH CHECK (public.has_account_capability(account_id, 'contact.write'));
CREATE POLICY contact_consents_update ON public.contact_channel_consents FOR UPDATE
  USING (public.has_account_capability(account_id, 'contact.write'))
  WITH CHECK (public.has_account_capability(account_id, 'contact.write'));

DROP POLICY IF EXISTS marketing_touchpoints_select ON public.marketing_touchpoints;
DROP POLICY IF EXISTS marketing_touchpoints_insert ON public.marketing_touchpoints;
CREATE POLICY marketing_touchpoints_select ON public.marketing_touchpoints FOR SELECT
  USING (public.is_account_member(account_id));
CREATE POLICY marketing_touchpoints_insert ON public.marketing_touchpoints FOR INSERT
  WITH CHECK (public.has_account_capability(account_id, 'broadcast.create'));

DROP POLICY IF EXISTS opportunity_attributions_select ON public.opportunity_attributions;
CREATE POLICY opportunity_attributions_select ON public.opportunity_attributions FOR SELECT
  USING (public.has_account_capability(account_id, 'report.view'));

GRANT SELECT, INSERT, UPDATE ON public.marketing_campaigns TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.contact_channel_consents TO authenticated;
GRANT SELECT, INSERT ON public.marketing_touchpoints TO authenticated;
GRANT SELECT ON public.opportunity_attributions TO authenticated;
REVOKE DELETE ON public.marketing_campaigns FROM authenticated;
REVOKE DELETE ON public.contact_channel_consents FROM authenticated;
REVOKE UPDATE, DELETE ON public.marketing_touchpoints FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.opportunity_attributions FROM authenticated;

DROP TRIGGER IF EXISTS set_updated_at ON public.marketing_campaigns;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.marketing_campaigns
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
DROP TRIGGER IF EXISTS set_updated_at ON public.contact_channel_consents;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.contact_channel_consents
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

COMMIT;
