import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const processMigration = readFileSync(
  join(process.cwd(), "supabase/migrations/045_opportunity_process_commands.sql"),
  "utf8",
);
const conversionMigration = readFileSync(
  join(process.cwd(), "supabase/migrations/046_convert_lead_to_opportunity.sql"),
  "utf8",
);

describe("opportunity process database contract", () => {
  it("separates stage kind from opportunity status", () => {
    expect(processMigration).toContain(
      "CREATE TYPE pipeline_stage_kind_enum AS ENUM ('open', 'won', 'lost')",
    );
    expect(processMigration).toContain("ADD COLUMN IF NOT EXISTS stage_kind");
    expect(processMigration).toContain("deals_status_check");
  });

  it.each([
    "move_opportunity",
    "close_opportunity_lost",
    "reopen_opportunity",
    "archive_opportunity",
  ])("defines the %s command", (name) => {
    expect(processMigration).toContain(`CREATE OR REPLACE FUNCTION public.${name}`);
  });

  it("requires a loss reason and a next task on reopen", () => {
    expect(processMigration).toContain("A valid active loss reason is required");
    expect(processMigration).toContain("Reopening requires a next task and due date");
  });

  it("requires a next action in open stages", () => {
    expect(processMigration).toContain("Open opportunity stages require a next task");
    expect(processMigration).toContain("requires_next_task");
  });

  it("cancels open tasks when an opportunity is won or lost", () => {
    expect(processMigration.match(/UPDATE public\.tasks/g)?.length).toBeGreaterThanOrEqual(3);
    expect(processMigration).toContain("cancellation_reason = 'Opportunity won'");
    expect(processMigration).toContain("cancellation_reason = 'Opportunity lost'");
  });

  it("records immutable stage history and blocks hard delete", () => {
    expect(processMigration).toContain("CREATE TABLE IF NOT EXISTS public.opportunity_stage_history");
    expect(processMigration).toContain("REVOKE INSERT, UPDATE, DELETE ON public.opportunity_stage_history");
    expect(processMigration).toContain("REVOKE DELETE ON public.deals FROM authenticated");
  });

  it("blocks browser lifecycle patches", () => {
    expect(processMigration).toContain("enforce_opportunity_command_columns");
    expect(processMigration).toContain(
      "Use opportunity process commands for stage and lifecycle changes",
    );
  });

  it("converts each qualified lead at most once", () => {
    expect(conversionMigration).toContain("uq_deals_one_active_per_lead");
    expect(conversionMigration).toContain("Only qualified leads can be converted");
    expect(conversionMigration).toContain("UPDATE public.leads");
    expect(conversionMigration).toContain("status = 'converted'");
    expect(conversionMigration).toContain("INSERT INTO public.tasks");
  });
});
