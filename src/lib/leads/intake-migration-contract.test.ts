import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const distribution = readFileSync(
  join(process.cwd(), "supabase/migrations/041_lead_intake_distribution.sql"),
  "utf8",
);
const reopenFix = readFileSync(
  join(process.cwd(), "supabase/migrations/042_fix_lead_intake_reopen.sql"),
  "utf8",
);

describe("lead intake database contract", () => {
  it("serializes concurrent intake by account and normalized phone", () => {
    expect(distribution).toContain(
      "pg_advisory_xact_lock(hashtext(p_account_id::TEXT || ':' || v_phone_normalized))",
    );
  });

  it("enforces one active lead per contact", () => {
    expect(distribution).toContain("CREATE UNIQUE INDEX IF NOT EXISTS uq_leads_one_active_per_contact");
    expect(distribution).toContain("status NOT IN ('converted', 'disqualified')");
  });

  it("uses an external key for idempotent retries", () => {
    expect(distribution).toContain("WHERE account_id = p_account_id AND external_key = p_external_key");
    expect(distribution).toContain("'idempotent_replay', true");
  });

  it("creates SLA and first task in the same database function", () => {
    expect(distribution).toContain("v_now + make_interval(mins => p_first_response_minutes)");
    expect(distribution).toContain("INSERT INTO public.tasks");
    expect(distribution).toContain("'First contact'");
  });

  it("supports queue, fixed and round-robin strategies", () => {
    expect(distribution).toContain("strategy IN ('round_robin', 'fixed', 'queue')");
    expect(distribution).toContain("IF v_rule.strategy = 'queue' THEN");
    expect(distribution).toContain("IF v_rule.strategy = 'fixed' THEN");
    expect(distribution).toContain("lead_assignment_counters");
  });

  it("applies vacation delegation before assignment", () => {
    expect(distribution).toContain("public.resolve_delegated_user(");
    expect(distribution).toContain("'new_leads'");
  });

  it("keeps assignment rules non-destructive", () => {
    expect(distribution).not.toMatch(/CREATE POLICY\s+lead_distribution_rules_delete/i);
    expect(distribution).toContain(
      "REVOKE DELETE ON public.lead_distribution_rules FROM authenticated",
    );
  });

  it("preserves active-lead detection across later SELECT statements", () => {
    expect(reopenFix).toContain("v_active_lead_found BOOLEAN := false");
    expect(reopenFix).toContain("v_active_lead_found := FOUND");
    expect(reopenFix).toContain("IF NOT v_active_lead_found AND p_reopen_disqualified THEN");
  });
});
