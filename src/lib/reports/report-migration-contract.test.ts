import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const migration = readFileSync(
  join(process.cwd(), "supabase/migrations/049_management_reporting.sql"),
  "utf8",
);

describe("management reporting database contract", () => {
  it("keeps the report server-side and bounded", () => {
    expect(migration).toContain("CREATE OR REPLACE FUNCTION public.crm_management_report");
    expect(migration).toContain("Reporting period cannot exceed 370 days");
    expect(migration).toContain("RETURNS JSONB");
  });

  it("requires report capability", () => {
    expect(migration).toContain("public.has_account_capability(p_account_id, 'report.view')");
    expect(migration).toContain("Missing report.view capability");
  });

  it("covers commercial, operational, marketing and integration signals", () => {
    for (const key of [
      "lead_metrics",
      "task_metrics",
      "opportunity_metrics",
      "marketing_metrics",
      "whatsapp_metrics",
      "pipeline_breakdown",
      "owner_performance",
    ]) {
      expect(migration).toContain(key);
    }
  });

  it("calculates SLA, forecast, win rate and ROI", () => {
    expect(migration).toContain("avg_first_response_minutes");
    expect(migration).toContain("weighted_value");
    expect(migration).toContain("win_rate");
    expect(migration).toContain("roi_percent");
  });

  it("returns a bounded daily time series", () => {
    expect(migration).toContain("generate_series(");
    expect(migration).toContain("'won_revenue'");
  });
});
