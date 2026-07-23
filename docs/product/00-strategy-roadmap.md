# CRM completion roadmap

The product is completed through a controlled stack rather than direct edits to `main`.

## Sequence

0. Baseline, upstream evaluation and destructive-operation containment.
1. CRM domain: contacts, leads, activities, tasks and domain events.
2. Capabilities, teams and temporary delegation.
3. Transactional lead intake, deduplication, assignment and SLA.
4. Task commands, agenda, outcomes, recurrence and due notifications.
5. Opportunity process, conversion, win/loss and stage history.
6. WhatsApp provider adapter, idempotency, retries and dead letters.
7. Campaigns, consent, marketing touchpoints and revenue attribution.
8. Operational UX for leads, tasks and campaigns.
9. Server-side management reports.
10. Audit, retention, release gates and rollback operations.

## Promotion rule

Runtime work accumulates in stacked `block/**` branches and is promoted to `integration/product-baseline` only after CI. The baseline is promoted to `main` only after migrations pass on both an empty database and a restored copy of the current database.

## Non-negotiable gates

- no authenticated hard delete for core CRM records;
- no direct browser patch of lifecycle/state columns;
- account-scoped foreign keys and RLS;
- idempotency for external events and transactional commands;
- auditable actor, timestamp and reason for sensitive changes;
- CI plus real PostgreSQL/Supabase migration rehearsals;
- documented backup and rollback evidence.
