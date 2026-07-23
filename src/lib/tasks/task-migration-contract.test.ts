import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const commands = readFileSync(
  join(process.cwd(), "supabase/migrations/043_task_commands_and_due_notifications.sql"),
  "utf8",
);
const serviceRole = readFileSync(
  join(process.cwd(), "supabase/migrations/044_service_role_capability_resolution.sql"),
  "utf8",
);

describe("task command database contract", () => {
  it.each([
    "create_crm_task",
    "start_crm_task",
    "complete_crm_task",
    "cancel_crm_task",
    "reassign_crm_task",
  ])("defines the %s command", (name) => {
    expect(commands).toContain(`CREATE OR REPLACE FUNCTION public.${name}`);
  });

  it("blocks direct lifecycle and assignment updates from browser clients", () => {
    expect(commands).toContain("enforce_task_command_columns");
    expect(commands).toContain(
      "Use CRM task commands for state, assignment and archival changes",
    );
  });

  it("requires completion and cancellation outcomes", () => {
    expect(commands).toContain("Completion outcome is required");
    expect(commands).toContain("Cancellation reason is required");
  });

  it("creates an activity when work is completed or reassigned", () => {
    expect(commands.match(/INSERT INTO public\.activities/g)?.length).toBeGreaterThanOrEqual(2);
    expect(commands).toContain("jsonb_build_object('task_id', v_task.id)");
  });

  it("creates the next recurring task in the same command", () => {
    expect(commands).toContain("public.next_crm_recurrence_due_at");
    expect(commands).toContain("parent_task_id");
    expect(commands).toContain("p_create_next AND v_task.recurrence_rule IS NOT NULL");
  });

  it("deduplicates due notifications", () => {
    expect(commands).toContain("uq_notifications_account_dedupe_key");
    expect(commands).toContain("'task-due:' || t.id::TEXT");
    expect(commands).toContain("ON CONFLICT (account_id, dedupe_key)");
  });

  it("keeps due notification enqueue service-only", () => {
    expect(commands).toContain(
      "REVOKE ALL ON FUNCTION public.enqueue_due_task_notifications(TIMESTAMPTZ, INTERVAL)",
    );
    expect(commands).toContain("TO service_role");
  });

  it("lets only trusted backend roles bypass browser capability lookup", () => {
    expect(serviceRole).toContain("current_user IN ('service_role', 'postgres')");
    expect(serviceRole).toContain("capability_definitions");
    expect(serviceRole).toContain("IF auth.uid() IS NULL THEN");
  });
});
