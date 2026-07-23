// ============================================================
// GET  /api/v1/tasks — list CRM tasks (scope: tasks:read)
// POST /api/v1/tasks — create a task transactionally (scope: tasks:write)
// ============================================================

import { requireApiKey } from '@/lib/auth/api-context';
import { resolveAuditUserId } from '@/lib/api/v1/contacts';
import {
  buildPage,
  keysetFilter,
  parseListParams,
} from '@/lib/api/v1/pagination';
import { fail, ok, okList, toApiErrorResponse } from '@/lib/api/v1/respond';
import { parseTaskCreateInput } from '@/lib/tasks/operations';

export async function GET(request: Request) {
  try {
    const ctx = await requireApiKey(request, 'tasks:read');
    const { limit, cursor } = parseListParams(request);
    const url = new URL(request.url);
    const status = url.searchParams.get('status');
    const assignee = url.searchParams.get('assignee');
    const dueBefore = url.searchParams.get('due_before');

    let query = ctx.supabase
      .from('tasks')
      .select(
        '*, contact:contacts(id,name,phone), lead:leads(id,status,priority), assignee:profiles!tasks_assigned_to_fkey(user_id,full_name,avatar_url)',
      )
      .eq('account_id', ctx.accountId)
      .is('archived_at', null)
      .order('created_at', { ascending: false })
      .order('id', { ascending: false })
      .limit(limit + 1);

    if (status) query = query.eq('status', status);
    if (assignee) query = query.eq('assigned_to', assignee);
    if (dueBefore) {
      const parsed = new Date(dueBefore);
      if (!Number.isFinite(parsed.getTime())) {
        return fail('bad_request', "'due_before' must be a valid ISO date", 400);
      }
      query = query.lte('due_at', parsed.toISOString());
    }

    const filter = keysetFilter(cursor);
    if (filter) query = query.or(filter);

    const { data, error } = await query;
    if (error) {
      console.error('[api/v1/tasks] list error:', error);
      return fail('internal', 'Failed to list tasks', 500);
    }

    const { items, nextCursor } = buildPage(
      (data ?? []) as unknown as Array<{ created_at: string; id: string }>,
      limit,
    );
    return okList(items, nextCursor);
  } catch (error) {
    return toApiErrorResponse(error);
  }
}

export async function POST(request: Request) {
  try {
    const ctx = await requireApiKey(request, 'tasks:write');
    const parsed = parseTaskCreateInput(await request.json().catch(() => null));
    if (!parsed.ok) return fail('bad_request', parsed.error, 400);

    const input = parsed.value;
    const auditUserId = await resolveAuditUserId(ctx.supabase, ctx.accountId);
    const { data, error } = await ctx.supabase.rpc('create_crm_task', {
      p_account_id: ctx.accountId,
      p_contact_id: input.contactId,
      p_title: input.title,
      p_due_at: input.dueAt,
      p_assigned_to: input.assignedTo ?? auditUserId,
      p_lead_id: input.leadId ?? null,
      p_opportunity_id: input.opportunityId ?? null,
      p_conversation_id: input.conversationId ?? null,
      p_task_type: input.taskType,
      p_description: input.description ?? null,
      p_priority: input.priority,
      p_recurrence_rule: input.recurrenceRule ?? null,
      p_created_by: auditUserId,
    });

    if (error) {
      console.error('[api/v1/tasks] create error:', error);
      const validation = ['23514', '23503', '42501'].includes(error.code ?? '');
      return fail(
        validation ? 'bad_request' : 'internal',
        validation ? error.message : 'Failed to create task',
        validation ? 400 : 500,
      );
    }

    return ok(data, 201);
  } catch (error) {
    return toApiErrorResponse(error);
  }
}
