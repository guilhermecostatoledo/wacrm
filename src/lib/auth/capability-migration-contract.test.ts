import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const foundation = readFileSync(
  join(process.cwd(), "supabase/migrations/039_capabilities_teams_delegations.sql"),
  "utf8",
);
const guard = readFileSync(
  join(process.cwd(), "supabase/migrations/040_capability_grant_guard.sql"),
  "utf8",
);

describe("capability database contract", () => {
  it("creates capability, team and delegation entities with RLS", () => {
    for (const table of [
      "role_capability_grants",
      "member_capability_grants",
      "teams",
      "team_members",
      "delegations",
    ]) {
      expect(foundation).toContain(`CREATE TABLE IF NOT EXISTS public.${table}`);
      expect(foundation).toContain(`ALTER TABLE public.${table} ENABLE ROW LEVEL SECURITY`);
    }
  });

  it("resolves explicit overrides before role presets", () => {
    const memberLookup = foundation.indexOf("FROM public.member_capability_grants");
    const roleLookup = foundation.indexOf("FROM public.role_capability_grants", memberLookup + 1);
    expect(memberLookup).toBeGreaterThan(-1);
    expect(roleLookup).toBeGreaterThan(memberLookup);
  });

  it("keeps teams and delegations non-destructive", () => {
    expect(foundation).not.toMatch(/CREATE POLICY\s+teams_delete/i);
    expect(foundation).not.toMatch(/CREATE POLICY\s+team_members_delete/i);
    expect(foundation).not.toMatch(/CREATE POLICY\s+delegations_delete/i);
    expect(foundation).toContain("REVOKE DELETE ON public.teams FROM authenticated");
    expect(foundation).toContain("REVOKE DELETE ON public.delegations FROM authenticated");
  });

  it("prevents overlapping delegation scopes", () => {
    expect(foundation).toContain("prevent_overlapping_delegations");
    expect(foundation).toContain("d.scopes && NEW.scopes");
    expect(foundation).toContain("tstzrange(d.starts_at, d.ends_at, '[)')");
  });

  it("prevents non-owner self escalation", () => {
    expect(guard).toContain("Non-owner members cannot modify their own capability overrides");
    expect(guard).toContain("NEW.capability IN ('account.transfer', 'account.delete')");
    expect(guard).toContain("Only the owner can modify owner capability overrides");
  });
});
