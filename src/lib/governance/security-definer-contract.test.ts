import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const migration = readFileSync(
  join(process.cwd(), "supabase/migrations/051_security_definer_authorization_fix.sql"),
  "utf8",
);

describe("SECURITY DEFINER authorization repair", () => {
  it("uses the JWT role for supervised service execution", () => {
    expect(migration).toContain("auth.jwt()->>'role'");
    expect(migration).toContain("v_jwt_role = 'service_role'");
  });

  it("does not use current_user to identify authenticated callers", () => {
    expect(migration).not.toMatch(/current_user\s*=\s*'authenticated'/i);
    expect(migration).not.toMatch(/current_user\s*<>\s*'authenticated'/i);
  });

  it("keeps original command bodies private behind authorized wrappers", () => {
    for (const name of [
      "intake_lead_unchecked",
      "create_crm_task_unchecked",
      "record_marketing_touchpoint_unchecked",
    ]) {
      expect(migration).toContain(name);
      expect(migration).toContain(`REVOKE ALL ON FUNCTION public.${name}`);
    }
  });

  it("checks every wrapped command capability unconditionally", () => {
    expect(migration).toContain(
      "IF NOT public.has_account_capability(p_account_id, 'lead.create')",
    );
    expect(migration).toContain(
      "IF NOT public.has_account_capability(p_account_id, 'task.create')",
    );
    expect(migration).toContain(
      "IF NOT public.has_account_capability(p_account_id, 'broadcast.create')",
    );
  });

  it("uses auth.uid for self-escalation checks", () => {
    expect(migration).toContain("v_actor UUID := auth.uid()");
    expect(migration).toContain(
      "Non-owner members cannot modify their own capability overrides",
    );
  });
});
