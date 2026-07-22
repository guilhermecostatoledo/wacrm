# CRM Finalization Program

This document is the execution contract for finishing the CRM safely. Work must advance block by block. A block is complete only when its acceptance criteria pass; otherwise the next block must not start.

## Operating rules

1. Never develop directly on `main`.
2. Every block must have a small, reviewable change set.
3. Database changes require reversible migrations.
4. Every bug fix must include a regression test whenever technically possible.
5. Account isolation and RLS must be tested before UI polish.
6. Destructive deletion is forbidden for records with commercial history; archive them instead.
7. Active leads and deals must never remain without an owner or next action.
8. Webhook processing must be idempotent.
9. CI must pass typecheck, lint, tests, and production build before merge.
10. Layout redesign starts only after domain and data integrity are stable.

## Block sequence

### Block 0 — Technical baseline and inventory

Deliverables:

- architecture inventory;
- route and API inventory;
- database and migration inventory;
- roles and permission matrix;
- external integration inventory;
- known-risk register;
- critical-flow test matrix;
- production-readiness checklist.

Acceptance criteria:

- all runtime modules are mapped;
- all persistent entities and relations are mapped;
- all privileged server paths are identified;
- all external entry points are identified;
- current CI commands are documented;
- no product behavior is changed in this block.

### Block 1 — Domain model

Define and enforce the difference between contact, conversation, lead, deal, task, activity, customer, owner, and assignee.

Acceptance criteria:

- entity lifecycle states are documented;
- ownership rules are unambiguous;
- conversion and reopening rules are defined;
- duplicate handling is defined;
- deletion versus archival behavior is defined.

### Block 2 — Database integrity

Implement foreign keys, archival, indexes, constraints, transaction boundaries, webhook idempotency, audit events, and orphan cleanup.

Acceptance criteria:

- deleting or archiving a parent cannot leave actionable orphan records;
- tenant isolation remains intact;
- migrations run from an empty database and from the previous release;
- rollback or compensating procedure is documented;
- integrity regression tests pass.

### Block 3 — Roles, visibility, and portfolios

Define owner, admin, manager, seller, support agent, and viewer scopes, including temporary portfolio delegation.

Acceptance criteria:

- each role has explicit read/write permissions;
- cross-account access tests fail closed;
- vacation/delegation flow works without granting admin;
- reassignment is audited.

### Block 4 — Lead intake and qualification

Create a consistent lead lifecycle for WhatsApp, manual entry, CSV, forms, API, and campaigns.

Acceptance criteria:

- every new active lead receives an owner;
- every new active lead receives a first action or enters a controlled queue;
- qualification and disqualification reasons are recorded;
- duplicate leads are prevented or explicitly merged;
- conversion to deal is traceable.

### Block 5 — Tasks and daily work queue

Create a compact operational queue for overdue, today, new leads, callbacks, meetings, waiting conversations, and records without next action.

Acceptance criteria:

- completed, cancelled, or archived parent records do not leave active notifications;
- each active commercial record has a next action;
- task reassignment and rescheduling are audited;
- stale-task regression tests pass.

### Block 6 — Pipeline

Make the pipeline a trustworthy representation of deals, not a disconnected visual board.

Acceptance criteria:

- stages have configurable required fields;
- movement creates history;
- won/lost closes or cancels incompatible open actions;
- stalled-stage alerts are deterministic;
- deal value, probability, expected date, owner, and next action are available.

### Block 7 — WhatsApp operations

Stabilize inbox assignment, text, audio, video, documents, delivery states, retries, linking, and webhook replay.

Acceptance criteria:

- duplicate webhook deliveries do not duplicate messages;
- delayed media can be recovered without manual database edits;
- messages received while users are offline appear correctly;
- conversation and commercial ownership are shown separately;
- failed processing is observable and retryable.

### Block 8 — Automation governance

Add versioned automations, execution history, loop prevention, dry-run/testing, limits, and safe enable/disable controls.

Acceptance criteria:

- every execution is attributable to a version;
- loops and duplicate actions are prevented;
- failures are visible and retry policy is defined;
- human conversation activity can suppress conflicting automation.

### Block 9 — UX and visual redesign

Redesign after the operational model is stable. Prioritize density, clear hierarchy, predictable navigation, useful empty states, responsive behavior, and contextual side panels.

Acceptance criteria:

- critical workflows require fewer unnecessary page changes;
- task and lead screens fit common desktop resolutions without clipping;
- filters and actions use consistent patterns;
- keyboard and accessibility checks pass;
- usability scenarios are tested with representative data.

### Block 10 — Release hardening

Complete unit, integration, permission, webhook, migration, concurrency, and UI tests; document deployment, backup, rollback, and clean installation.

Acceptance criteria:

- CI is green;
- clean production build passes;
- clean database installation passes;
- upgrade migration passes;
- backup and restore are tested;
- smoke tests pass in a production-like environment;
- release checklist is signed off.

## Global definition of done

The CRM is not finished until all conditions below are true:

- no active lead lacks an owner;
- no active lead or deal lacks a next action;
- no task or notification references an unavailable actionable parent;
- no cross-account data leak is possible through UI, API, server action, storage, or realtime channels;
- duplicate webhook delivery is safe;
- critical changes are auditable;
- migrations are reproducible;
- production deployment and rollback are documented;
- critical flows have automated regression coverage.
