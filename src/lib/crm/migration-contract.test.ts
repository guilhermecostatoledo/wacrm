import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const migration = readFileSync(
  join(process.cwd(), "supabase/migrations/038_crm_domain_foundation.sql"),
  "utf8",
);

describe("CRM domain migration contract", () => {
  it.each(["leads", "activities", "tasks", "domain_events"])(
    "creates and enables RLS for %s",
    (table) => {
      expect(migration).toContain(`CREATE TABLE IF NOT EXISTS public.${table}`);
      expect(migration).toContain(`ALTER TABLE public.${table} ENABLE ROW LEVEL SECURITY`);
    },
  );

  it("keeps authenticated hard deletes unavailable", () => {
    expect(migration).not.toMatch(/CREATE POLICY\s+leads_delete/i);
    expect(migration).not.toMatch(/CREATE POLICY\s+activities_delete/i);
    expect(migration).not.toMatch(/CREATE POLICY\s+tasks_delete/i);
    expect(migration).toContain("REVOKE DELETE ON public.leads FROM authenticated");
    expect(migration).toContain("REVOKE DELETE ON public.activities FROM authenticated");
    expect(migration).toContain("REVOKE DELETE ON public.tasks FROM authenticated");
  });

  it("uses account-scoped foreign keys without nulling the tenancy key", () => {
    expect(migration).toContain("FOREIGN KEY (account_id, contact_id)");
    expect(migration).toContain("FOREIGN KEY (account_id, lead_id)");
    expect(migration).not.toMatch(
      /FOREIGN KEY \(account_id, (?:source_id|disqualification_reason_id|loss_reason_id)\)[\s\S]{0,160}ON DELETE SET NULL/i,
    );
  });

  it("provides audited archival commands instead of direct archival writes", () => {
    expect(migration).toContain("CREATE OR REPLACE FUNCTION public.archive_contact");
    expect(migration).toContain("CREATE OR REPLACE FUNCTION public.restore_contact");
    expect(migration).toContain("enforce_contact_archival_command");
  });

  it("migrates legacy notes and deals idempotently", () => {
    expect(migration).toContain("'legacy-deal:' || d.id::text");
    expect(migration).toContain("ON CONFLICT (account_id, external_key) DO NOTHING");
    expect(migration).toContain("ON CONFLICT (account_id, legacy_source, legacy_id) DO NOTHING");
    expect(migration).toContain(
      "CREATE UNIQUE INDEX IF NOT EXISTS uq_activities_legacy_source\n  ON public.activities(account_id, legacy_source, legacy_id);",
    );
  });

  it("captures domain events for all central aggregates", () => {
    for (const trigger of [
      "capture_contact_domain_event",
      "capture_lead_domain_event",
      "capture_activity_domain_event",
      "capture_task_domain_event",
      "capture_deal_domain_event",
    ]) {
      expect(migration).toContain(trigger);
    }
  });
});
