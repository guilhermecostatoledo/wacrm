import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const REQUIRED_ENV = [
  "NEXT_PUBLIC_SUPABASE_URL",
  "NEXT_PUBLIC_SUPABASE_ANON_KEY",
  "SUPABASE_SERVICE_ROLE_KEY",
  "ENCRYPTION_KEY",
  "META_APP_SECRET",
] as const;

export function GET() {
  const missing = REQUIRED_ENV.filter((name) => !process.env[name]);
  const healthy = missing.length === 0;

  return NextResponse.json(
    {
      status: healthy ? "ok" : "misconfigured",
      service: "wacrm",
      release: process.env.APP_RELEASE ?? "unknown",
      uptime_seconds: Math.floor(process.uptime()),
      checks: {
        environment: healthy ? "ok" : "missing_required_variables",
      },
      // Variable names are safe operational metadata. Values are never returned.
      missing_variables: missing,
      timestamp: new Date().toISOString(),
    },
    {
      status: healthy ? 200 : 503,
      headers: {
        "Cache-Control": "no-store",
      },
    },
  );
}
