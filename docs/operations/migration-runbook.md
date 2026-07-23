# Database migration runbook

Target range for the CRM completion stack: `037` through `050`.

## Principles

- Never test the first migration run against the only copy of production data.
- Never apply a partial range without recording exactly which migrations committed.
- Application deployment and database migration are separate decisions.
- Take a restorable backup before schema changes.
- Use a maintenance window for the restored-production rehearsal and production promotion.
- Do not delete the old application artifact until rollback validation is complete.

## Environment preparation

Record:

- environment name;
- PostgreSQL/Supabase project reference;
- current application commit;
- target application commit;
- current highest migration;
- target migration range;
- backup identifier and storage location;
- operator and reviewer;
- start time.

Confirm that environment variables are configured without printing secret values:

- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `ENCRYPTION_KEY`
- `META_APP_SECRET`
- optional cron and host allow-list variables used by the deployment

## Baseline snapshot

Capture counts before migration:

```sql
select 'profiles' as table_name, count(*) from public.profiles
union all select 'contacts', count(*) from public.contacts
union all select 'conversations', count(*) from public.conversations
union all select 'messages', count(*) from public.messages
union all select 'deals', count(*) from public.deals
union all select 'broadcasts', count(*) from public.broadcasts
union all select 'automations', count(*) from public.automations
union all select 'flows', count(*) from public.flows;
```

Capture duplicate controls:

```sql
select account_id, phone_normalized, count(*)
from public.contacts
group by account_id, phone_normalized
having count(*) > 1;

select account_id, contact_id, count(*)
from public.conversations
group by account_id, contact_id
having count(*) > 1;
```

Export any result rows before continuing.

## Empty-database rehearsal

1. Create a disposable PostgreSQL/Supabase project.
2. Apply migrations from `001` in filename order through `050`.
3. Stop on the first error; do not skip a migration.
4. Run `npm run release:check` against the same commit.
5. Create owner, admin, agent and viewer test users.
6. Execute the RLS and workflow matrix from `production-readiness.md`.
7. Drop the disposable project only after attaching results to the promotion PR.

## Restored-production rehearsal

1. Restore the production backup to an isolated project.
2. Point no public webhook or scheduled job at the restored project.
3. Record baseline counts and duplicate controls.
4. Apply only migrations after the restored database's current version, in filename order.
5. Record each migration start, finish and outcome.
6. Run post-migration validation below.
7. Start the target application against the restored database.
8. Execute the critical business flow matrix.
9. Run the management report with 7, 30, 90 and 370-day ranges.
10. Record query plans for slow paths.

## Post-migration validation

### New domain counts

```sql
select 'leads' as table_name, count(*) from public.leads
union all select 'activities', count(*) from public.activities
union all select 'tasks', count(*) from public.tasks
union all select 'domain_events', count(*) from public.domain_events
union all select 'teams', count(*) from public.teams
union all select 'delegations', count(*) from public.delegations
union all select 'marketing_campaigns', count(*) from public.marketing_campaigns
union all select 'marketing_touchpoints', count(*) from public.marketing_touchpoints
union all select 'whatsapp_webhook_receipts', count(*) from public.whatsapp_webhook_receipts;
```

### Tenant isolation and orphan checks

```sql
select count(*) as invalid_lead_contacts
from public.leads l
left join public.contacts c
  on c.account_id = l.account_id and c.id = l.contact_id
where c.id is null;

select count(*) as invalid_task_contacts
from public.tasks t
left join public.contacts c
  on c.account_id = t.account_id and c.id = t.contact_id
where c.id is null;

select count(*) as invalid_opportunity_leads
from public.deals d
left join public.leads l
  on l.account_id = d.account_id and l.id = d.lead_id
where d.lead_id is not null and l.id is null;

select count(*) as invalid_assignees
from public.tasks t
left join public.profiles p
  on p.account_id = t.account_id and p.user_id = t.assigned_to
where p.user_id is null;
```

Every result must be zero.

### Destructive access controls

As an authenticated agent/viewer session, verify failure:

```sql
-- Execute through the same PostgREST/JWT path used by the browser.
delete from public.contacts where id = '<test-contact-id>';
delete from public.deals where id = '<test-opportunity-id>';
update public.profiles
set account_role = 'owner'
where user_id = auth.uid();
```

Then verify supervised service-role maintenance still works only where intended.

### Idempotency

- Call `intake_lead` twice with the same `external_key`; IDs must match.
- Register the same WhatsApp provider event twice; `is_new` must be false on replay.
- Convert the same qualified lead twice; only one active opportunity may exist.
- Complete a recurring task under concurrent calls; only one next task may remain. If this fails, block release and add an idempotency guard before promotion.

## Production execution

1. Announce the maintenance window.
2. Pause webhook delivery, automation cron, scheduled broadcasts and background workers.
3. Confirm the latest restorable backup completed.
4. Record live pre-migration counts.
5. Apply the approved migration range in order.
6. Run critical orphan/security checks before starting the new application.
7. Deploy the exact commit approved in the promotion PR.
8. Resume workers one class at a time:
   - inbound WhatsApp;
   - outbound message workers;
   - task/automation cron;
   - broadcasts.
9. Observe health endpoint, dead letters, error logs and core flow smoke tests.
10. Keep the maintenance bridge open through the agreed observation period.

## Rollback decision

Rollback immediately for:

- data loss or unexplained count decrease;
- cross-account visibility;
- inability to receive/store WhatsApp messages;
- duplicate creation that grows under replay;
- failed login/session refresh for existing users;
- inability to create or complete core commercial work;
- migration that remains partially applied without a proven forward fix.

## Rollback procedure

The migrations contain forward data transformations, so rollback means restore, not ad-hoc reverse SQL.

1. Pause all writes and workers.
2. Preserve logs and the failed database for investigation.
3. Redeploy the previous application artifact only against the previous schema.
4. Restore the pre-migration backup to the production project or switch traffic to the verified restored instance.
5. Validate counts, login, inbox and message processing.
6. Resume traffic gradually.
7. Record the incident, failed migration/commit and decision timeline in the audit/release record.

## Completion record

Attach to the promotion PR:

- before/after counts;
- all orphan query results;
- RLS test evidence;
- business-flow test evidence;
- performance evidence;
- backup identifier;
- release commit;
- migration range;
- operator, reviewer and completion time.
