import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const migration = readFileSync(
  join(process.cwd(), "supabase/migrations/050_governance_audit_retention.sql"),
  "utf8",
);
const releaseCheck = readFileSync(
  join(process.cwd(), "scripts/check-release-readiness.mjs"),
  "utf8",
);

describe("governance database contract", () => {
  it("creates account-specific retention settings", () => {
    expect(migration).toContain("CREATE TABLE IF NOT EXISTS public.account_governance_settings");
    expect(migration).toContain("domain_event_retention_days");
    expect(migration).toContain("successful_integration_log_retention_days");
    expect(migration).toContain("failed_integration_log_retention_days");
  });

  it("keeps the audit feed bounded and capability-gated", () => {
    expect(migration).toContain("v_limit INTEGER := LEAST(GREATEST");
    expect(migration).toContain("'audit.read'");
    expect(migration).toContain("LIMIT v_limit + 1");
  });

  it("requires notes and records dead-letter resolution", () => {
    expect(migration).toContain("Resolution notes are required");
    expect(migration).toContain("integration.dead_letter_resolved");
    expect(migration).toContain("INSERT INTO public.domain_events");
  });

  it("keeps retention cleanup service-only", () => {
    expect(migration).toContain("current_user NOT IN ('service_role', 'postgres')");
    expect(migration).toContain("Operational retention is service-only");
    expect(migration).toContain("TO service_role");
  });

  it("makes static release gates deterministic", () => {
    expect(releaseCheck).toContain("Duplicate migration version");
    expect(releaseCheck).toContain("Missing product migration");
    expect(releaseCheck).toContain("Release readiness static checks passed");
  });
});
