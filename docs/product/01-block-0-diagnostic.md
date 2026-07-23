# Baseline diagnostic

## Confirmed structural gaps in the original snapshot

- contacts, conversations and deals existed, but lead and task were not first-class domain entities;
- contact deletion was initiated directly by the browser and could cascade through conversations/messages;
- moving a deal to a stage named “Won” changed only `stage_id`;
- agent permissions included campaign and automation operations that should be separated;
- `/flows` and later modules were omitted from the explicit protected-route list;
- several multi-write workflows were performed without a single database transaction;
- dashboard aggregation downloaded operational rows to the client;
- the fork was substantially behind upstream security and WhatsApp fixes;
- there was no immutable domain audit feed or supervised dead-letter workflow.

## Baseline decisions

- use the validated upstream snapshot only as a technical baseline, not as the finished CRM domain;
- keep runtime work out of `main` until database rehearsal;
- replace destructive deletion with archival commands;
- separate contact, lead and opportunity lifecycles;
- model task/result/next-action explicitly;
- use capability checks plus account-scoped RLS;
- place external-event idempotency in the database;
- calculate management reports on the server;
- treat static SQL tests as supporting evidence, never as database execution evidence.
