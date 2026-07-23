import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const migration = readFileSync(
  join(process.cwd(), "supabase/migrations/047_whatsapp_reliability_ledger.sql"),
  "utf8",
);

describe("WhatsApp reliability database contract", () => {
  it("supports Meta and Evolution behind one provider enum", () => {
    expect(migration).toContain(
      "CREATE TYPE whatsapp_provider_enum AS ENUM ('meta_cloud', 'evolution')",
    );
    expect(migration).toContain("ADD COLUMN IF NOT EXISTS provider whatsapp_provider_enum");
  });

  it("deduplicates provider events by account, provider and event id", () => {
    expect(migration).toContain("UNIQUE(account_id, provider, provider_event_id)");
    expect(migration).toContain(
      "ON CONFLICT (account_id, provider, provider_event_id) DO NOTHING",
    );
  });

  it("claims work safely under concurrency", () => {
    expect(migration).toContain("FOR UPDATE SKIP LOCKED");
    expect(migration).toContain("attempt_count = attempt_count + 1");
  });

  it("moves exhausted receipts to a dead-letter ledger", () => {
    expect(migration).toContain("status = CASE WHEN v_dead THEN 'dead_letter' ELSE 'failed' END");
    expect(migration).toContain("INSERT INTO public.integration_dead_letters");
  });

  it("keeps writes service-only and audit reads capability-gated", () => {
    expect(migration).toContain("TO service_role");
    expect(migration).toContain("public.has_account_capability(account_id, 'audit.read')");
    expect(migration).toContain(
      "REVOKE INSERT, UPDATE, DELETE ON public.whatsapp_webhook_receipts FROM authenticated",
    );
  });

  it("tracks outbound attempts without storing raw credentials", () => {
    expect(migration).toContain("CREATE TABLE IF NOT EXISTS public.whatsapp_delivery_attempts");
    expect(migration).toContain("request_summary JSONB");
    expect(migration).not.toContain("access_token TEXT");
  });
});
