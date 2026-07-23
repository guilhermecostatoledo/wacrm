import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const migration = readFileSync(
  join(process.cwd(), "supabase/migrations/048_marketing_campaigns_attribution_consent.sql"),
  "utf8",
);

describe("marketing database contract", () => {
  it("creates campaigns, consent, touchpoints and attribution", () => {
    for (const table of [
      "marketing_campaigns",
      "contact_channel_consents",
      "marketing_touchpoints",
      "opportunity_attributions",
    ]) {
      expect(migration).toContain(`CREATE TABLE IF NOT EXISTS public.${table}`);
      expect(migration).toContain(`ALTER TABLE public.${table} ENABLE ROW LEVEL SECURITY`);
    }
  });

  it("requires marketing opt-in for broadcast recipients", () => {
    expect(migration).toContain("enforce_broadcast_recipient_consent");
    expect(migration).toContain("'whatsapp', 'marketing'");
    expect(migration).toContain("Contact has not opted in to WhatsApp marketing");
  });

  it("deduplicates external marketing events", () => {
    expect(migration).toContain("uq_marketing_touchpoint_external_event");
    expect(migration).toContain("ON CONFLICT (account_id, channel, external_event_id)");
  });

  it("materializes first-touch and last-touch revenue attribution", () => {
    expect(migration).toContain("'first_touch'");
    expect(migration).toContain("'last_touch'");
    expect(migration).toContain("attributed_revenue");
    expect(migration).toContain("refresh_attribution_on_opportunity_won");
  });

  it("keeps touchpoints and attribution immutable to browser clients", () => {
    expect(migration).toContain(
      "REVOKE UPDATE, DELETE ON public.marketing_touchpoints FROM authenticated",
    );
    expect(migration).toContain(
      "REVOKE INSERT, UPDATE, DELETE ON public.opportunity_attributions FROM authenticated",
    );
  });
});
