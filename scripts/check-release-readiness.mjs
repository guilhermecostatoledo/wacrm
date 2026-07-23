import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const root = process.cwd();
const migrationsDir = join(root, "supabase", "migrations");
const failures = [];
const warnings = [];

function fail(message) {
  failures.push(message);
}

function warn(message) {
  warnings.push(message);
}

function read(relativePath) {
  const absolutePath = join(root, relativePath);
  if (!existsSync(absolutePath)) {
    fail(`Missing required file: ${relativePath}`);
    return "";
  }
  return readFileSync(absolutePath, "utf8");
}

if (!existsSync(migrationsDir)) {
  fail("Missing supabase/migrations directory");
} else {
  const files = readdirSync(migrationsDir)
    .filter((file) => file.endsWith(".sql"))
    .sort();

  const versions = new Map();
  for (const file of files) {
    const match = /^(\d{3})_[a-z0-9_]+\.sql$/.exec(file);
    if (!match) {
      fail(`Migration name must use NNN_snake_case.sql: ${file}`);
      continue;
    }
    const version = match[1];
    const previous = versions.get(version);
    if (previous) fail(`Duplicate migration version ${version}: ${previous}, ${file}`);
    versions.set(version, file);

    const sql = readFileSync(join(migrationsDir, file), "utf8");
    const numericVersion = Number(version);
    if (numericVersion >= 37) {
      if (!/\bBEGIN\s*;/i.test(sql)) fail(`${file} must start a transaction with BEGIN`);
      if (!/\bCOMMIT\s*;/i.test(sql)) fail(`${file} must finish the transaction with COMMIT`);
    }
  }

  const highest = Math.max(...[...versions.keys()].map(Number));
  if (highest < 52) fail(`Expected compatibility migration 052; highest migration is ${highest}`);

  for (let version = 37; version <= 52; version += 1) {
    const key = String(version).padStart(3, "0");
    if (!versions.has(key)) fail(`Missing product migration ${key}`);
  }
}

const packageJson = JSON.parse(read("package.json") || "{}");
for (const script of ["lint", "typecheck", "test", "build", "release:check", "docker:build", "docker:up"]) {
  if (!packageJson.scripts?.[script]) fail(`Missing npm script: ${script}`);
}

for (const path of [
  "docs/product/00-strategy-roadmap.md",
  "docs/product/01-block-0-diagnostic.md",
  "docs/product/02-target-domain-model.md",
  "docs/adr/001-upstream-baseline.md",
  "docs/operations/production-readiness.md",
  "docs/operations/migration-runbook.md",
  "docs/operations/docker-deployment.md",
  ".github/pull_request_template.md",
]) {
  read(path);
}

const contactContainment = read("supabase/migrations/037_disable_contact_hard_delete.sql");
if (!/DROP POLICY IF EXISTS contacts_delete/i.test(contactContainment)) {
  fail("Migration 037 must remove contacts_delete policy");
}
if (!/REVOKE DELETE ON (public\.)?contacts FROM authenticated/i.test(contactContainment)) {
  fail("Migration 037 must revoke authenticated contact DELETE");
}

const domainFoundation = read("supabase/migrations/038_crm_domain_foundation.sql");
for (const table of ["leads", "activities", "tasks", "domain_events"]) {
  if (!domainFoundation.includes(`CREATE TABLE IF NOT EXISTS public.${table}`)) {
    fail(`Migration 038 must create ${table}`);
  }
}

const opportunityProcess = read("supabase/migrations/045_opportunity_process_commands.sql");
if (!/REVOKE DELETE ON public\.deals FROM authenticated/i.test(opportunityProcess)) {
  fail("Migration 045 must revoke authenticated opportunity DELETE");
}

const governance = read("supabase/migrations/050_governance_audit_retention.sql");
for (const token of [
  "crm_audit_feed",
  "resolve_integration_dead_letter",
  "purge_expired_operational_logs",
]) {
  if (!governance.includes(token)) fail(`Migration 050 must define ${token}`);
}

const securityFix = read("supabase/migrations/051_security_definer_authorization_fix.sql");
for (const token of [
  "auth.jwt()->>'role'",
  "intake_lead_unchecked",
  "create_crm_task_unchecked",
  "record_marketing_touchpoint_unchecked",
]) {
  if (!securityFix.includes(token)) fail(`Migration 051 must contain ${token}`);
}
if (/current_user\s*=\s*'authenticated'/i.test(securityFix)) {
  fail("Migration 051 must not authorize SECURITY DEFINER functions through current_user");
}

const compatibility = read("supabase/migrations/052_safe_legacy_ui_compatibility.sql");
for (const token of [
  "archive_contact_from_legacy_delete",
  "record_legacy_opportunity_stage_change",
  "Use the lost-opportunity command and provide a structured loss reason",
  "compatibility_path",
]) {
  if (!compatibility.includes(token)) fail(`Migration 052 must contain ${token}`);
}
if (!/BEFORE DELETE ON public\.contacts/i.test(compatibility)) {
  fail("Migration 052 must intercept legacy contact DELETE before data loss");
}

const envExample = read(".env.local.example");
for (const key of [
  "NEXT_PUBLIC_SUPABASE_URL",
  "NEXT_PUBLIC_SUPABASE_ANON_KEY",
  "SUPABASE_SERVICE_ROLE_KEY",
  "ENCRYPTION_KEY",
  "META_APP_SECRET",
]) {
  if (!envExample.includes(key)) fail(`.env.local.example is missing ${key}`);
}

const dockerEnv = read(".env.docker.example");
for (const key of [
  "NEXT_PUBLIC_SUPABASE_URL",
  "NEXT_PUBLIC_SUPABASE_ANON_KEY",
  "SUPABASE_SERVICE_ROLE_KEY",
  "ENCRYPTION_KEY",
  "META_APP_SECRET",
]) {
  if (!dockerEnv.includes(key)) fail(`.env.docker.example is missing ${key}`);
}

const nextConfig = read("next.config.ts");
if (!/output:\s*["']standalone["']/.test(nextConfig)) {
  fail("next.config.ts must enable standalone output for the runtime image");
}

const dockerfile = read("Dockerfile");
for (const token of [
  "FROM node:20-alpine AS builder",
  "FROM node:20-alpine AS runner",
  "/app/.next/standalone",
  "USER nextjs",
  "HEALTHCHECK",
]) {
  if (!dockerfile.includes(token)) fail(`Dockerfile must contain ${token}`);
}
if (/ARG\s+(SUPABASE_SERVICE_ROLE_KEY|ENCRYPTION_KEY|META_APP_SECRET)/.test(dockerfile)) {
  fail("Runtime secrets must not be accepted as Docker build arguments");
}

const dockerIgnore = read(".dockerignore");
if (!/^\.env$/m.test(dockerIgnore) || !/^\.env\.\*$/m.test(dockerIgnore)) {
  fail(".dockerignore must exclude local environment files");
}

const compose = read("compose.yaml");
for (const token of ["read_only: true", "no-new-privileges:true", "/api/health", "SUPABASE_SERVICE_ROLE_KEY"]) {
  if (!compose.includes(token)) fail(`compose.yaml must contain ${token}`);
}

const healthRoute = read("src/app/api/health/route.ts");
if (!healthRoute.includes('missing_variables') || !healthRoute.includes('Cache-Control')) {
  fail("Health route must report configuration status without exposing values and disable caching");
}

if (!process.env.CI) {
  warn("Database execution is not verified by this static check. Run the migration runbook against clean and restored databases.");
  warn("Docker runtime execution is not verified by this static check. Run the container smoke test before promotion.");
}

for (const message of warnings) console.warn(`WARN: ${message}`);
if (failures.length > 0) {
  for (const message of failures) console.error(`FAIL: ${message}`);
  console.error(`Release readiness failed with ${failures.length} issue(s).`);
  process.exit(1);
}

console.log("Release readiness static checks passed.");
