import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const migration = readFileSync(
  join(process.cwd(), "supabase/migrations/052_safe_legacy_ui_compatibility.sql"),
  "utf8",
);

describe("legacy UI compatibility safety", () => {
  it("converts authenticated contact deletes into archival", () => {
    expect(migration).toContain("archive_contact_from_legacy_delete");
    expect(migration).toContain("lifecycle_status = 'archived'");
    expect(migration).toContain("RETURN NULL");
    expect(migration).toContain("contact.archived");
  });

  it("keeps supervised hard deletion separate from browser behavior", () => {
    expect(migration).toContain(
      "COALESCE(auth.jwt()->>'role', '') <> 'authenticated'",
    );
    expect(migration).toContain("RETURN OLD");
  });

  it("rejects direct moves to lost stages", () => {
    expect(migration).toContain(
      "Use the lost-opportunity command and provide a structured loss reason",
    );
  });

  it("maps direct won-stage movement to a real won lifecycle", () => {
    expect(migration).toContain("NEW.status := 'won'");
    expect(migration).toContain("NEW.probability := 100");
    expect(migration).toContain("cancellation_reason = 'Opportunity won'");
  });

  it("creates a next task for legacy open-stage moves when required", () => {
    expect(migration).toContain("v_stage.requires_next_task");
    expect(migration).toContain("Automatically created while moving the opportunity");
  });

  it("records compatibility-path history and activity", () => {
    expect(migration).toContain("record_legacy_opportunity_stage_change");
    expect(migration).toContain("INSERT INTO public.opportunity_stage_history");
    expect(migration).toContain("'compatibility_path', true");
  });
});
