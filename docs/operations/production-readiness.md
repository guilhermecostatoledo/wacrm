# Production readiness

This document is a release gate. A release is not production-ready because CI is green alone.

## Required evidence

Before promoting `integration/product-baseline` to `main`, attach evidence for every item below to the promotion PR.

### 1. Source and CI

- `npm ci`
- `npm run lint`
- `npm run typecheck`
- `npm test`
- `npm run release:check`
- `npm run build`
- no unresolved P0/P1 review comments
- no runtime PR merged directly into `main`; all runtime changes must pass through the product baseline

### 2. Database

Execute the migration runbook twice:

1. against a new empty Supabase/PostgreSQL project;
2. against a restored copy of the current production database.

Required evidence:

- migration start/end timestamps;
- row counts before and after for contacts, conversations, messages, deals, broadcasts and automations;
- row counts after for leads, tasks, activities, domain events and new governance tables;
- orphan checks for every new foreign key;
- RLS checks with owner, admin, agent and viewer sessions;
- service-role checks for supervised jobs;
- rollback point and backup identifier.

A static SQL contract test is not a substitute for executing migrations.

### 3. Critical business flows

Validate end-to-end with screenshots/log IDs:

- lead intake deduplicates the contact and external event;
- lead assignment observes capacity and vacation delegation;
- first-response SLA and first task are created together;
- task completion requires an outcome and recurring work creates one next task;
- qualified lead converts once into an opportunity;
- open pipeline movement requires a next activity;
- lost opportunity requires an active loss reason;
- won/lost opportunity closes related open tasks;
- contact and opportunity hard delete are unavailable to authenticated clients;
- WhatsApp webhook replay does not duplicate conversations/messages;
- delivery status does not regress from read/delivered to sent;
- failed WhatsApp work reaches dead-letter and can be resolved with notes;
- marketing broadcast rejects opted-out/unknown marketing consent;
- first-touch and last-touch attribution match the test dataset;
- reports match manual SQL control totals;
- audit feed shows actor, entity, event and timestamp.

### 4. Security

- verify migration 034 prevents editing `profiles.account_id` and `profiles.account_role` from the browser;
- verify member capability overrides cannot self-elevate an admin;
- verify owner-only account transfer/delete capabilities;
- rotate test credentials and confirm no real secret exists in Git history or CI logs;
- verify webhook signatures and host allow-list configuration;
- verify `/leads`, `/tasks`, `/campaigns`, `/reports`, `/audit`, `/flows`, `/agents` and `/notifications` redirect anonymous users;
- verify audit and integration failure details require `audit.read`;
- verify retention cleanup is executable only by `service_role`/postgres.

### 5. Performance and resilience

- run `EXPLAIN (ANALYZE, BUFFERS)` for the management report at 7, 30, 90 and 370 days using representative data;
- concurrency-test duplicate lead intake and duplicate WhatsApp webhook events;
- concurrency-test task completion/recurrence and opportunity conversion;
- simulate provider timeout, 429, 5xx and malformed webhook payloads;
- confirm dead-letter counts and retry delay;
- confirm dashboard, leads, tasks, pipeline and inbox remain usable on mobile viewport.

### 6. Operations

- canonical production URL configured;
- Supabase service-role, token encryption and Meta app secrets configured outside source control;
- WhatsApp health endpoint monitored;
- automation/task notification cron configured and authenticated;
- backup schedule and restore drill completed;
- incident owner and escalation channel recorded;
- release notes and user-facing behavior changes prepared;
- rollback decision-maker identified.

## Promotion decision

Promotion is allowed only when:

- all CI and static gates are green;
- both database migration rehearsals succeeded;
- no P0/P1 defect remains open;
- rollback has been rehearsed or demonstrated on the restored copy;
- the promotion PR names the exact migration range and backup identifier.

If any condition is missing, keep the release in the baseline branch and continue remediation.
