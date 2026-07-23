# Target CRM domain model

## Core entities

- **Account** — tenant boundary.
- **Profile / Membership** — person, account role and capability overrides.
- **Team / Delegation** — shared visibility and temporary coverage for absence.
- **Contact** — durable person/company identity and channel details.
- **Lead** — one commercial interest cycle for a contact, with source, owner, queue, SLA and qualification state.
- **Activity** — immutable business interaction/outcome timeline.
- **Task** — future action with assignee, due date, outcome, cancellation reason and optional recurrence.
- **Opportunity** — forecastable commercial value converted from a qualified lead.
- **Pipeline / Stage** — configurable commercial process; stage kind is open, won or lost.
- **Conversation / Message** — customer communication history.
- **Campaign / Touchpoint / Attribution** — acquisition plan, interaction evidence and first/last-touch revenue.
- **Domain Event** — append-only record of meaningful state changes.
- **Notification** — user-facing projection of actionable events; never the source of truth.
- **Integration Receipt / Delivery Attempt / Dead Letter** — provider-neutral reliability records.

## Lifecycle boundaries

A contact may have multiple historical leads. A lead may create at most one active opportunity. Lead qualification does not close the opportunity; opportunity win/loss does not delete the contact. Tasks and activities reference the relevant contact plus optional lead, opportunity and conversation.

## Integrity rules

- every domain row is account-scoped;
- composite foreign keys prevent cross-account relationships;
- browser clients do not directly change lifecycle/status/assignment columns;
- commands validate legal state transitions and write related history atomically;
- core entities are archived rather than hard-deleted;
- external event keys and active-record unique indexes enforce idempotency;
- sensitive operations require reason/outcome and actor identity;
- reports read authoritative domain tables, not notification projections.
