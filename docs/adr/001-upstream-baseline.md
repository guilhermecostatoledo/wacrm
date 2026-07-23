# ADR-001: Controlled upstream baseline

## Status

Accepted for evaluation and stacked development; not approved for direct production merge.

## Context

The original fork lacked later upstream fixes for profile privilege escalation, conversation deduplication, notifications and WhatsApp behavior. The upstream snapshot also introduced AI, MCP and partial internationalization that are not required for the initial commercial CRM scope.

## Decision

1. Use the CI-green upstream snapshot as the technical starting point for `integration/product-baseline`.
2. Do not merge the full upstream evaluation PR directly to `main`.
3. Add CRM domain/security/operations as stacked blocks.
4. Keep optional AI/MCP surfaces disabled or remove them before product promotion when they are outside the approved scope.
5. Promote only after migrations run on a clean database and a restored existing database.

## Consequences

- upstream security and WhatsApp fixes are preserved;
- the product avoids rebuilding on an older vulnerable base;
- migration dependencies must be reviewed as one ordered sequence;
- runtime changes remain isolated from `main` during development;
- release requires a deliberate baseline promotion PR with rollback evidence.
