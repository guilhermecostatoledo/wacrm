// ============================================================
// GET  /api/v1/opportunities — list opportunities
// POST /api/v1/opportunities — convert a qualified lead
// ============================================================

import { requireApiKey } from '@/lib/auth/api-context';
import { resolveAuditUserId } from '@/lib/api/v1/contacts';
import {
  buildPage,
  keysetFilter,
  parseListParams,
} from '@/lib/api/v1/pagination';
import { fail, ok, okList, toApiErrorResponse } from '@/lib/api/v1/respond';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function requiredText(body: Record<string, unknown>, field: string): string | null {
  const value = body[field];
  return typeof value === 'string' && value.trim() ? value.trim() : null;
}

export async function GET(request: Request) {
  try {
    const ctx = await requireApiKey(request, 'opportunities:read');
    const { limit, cursor } = parseListParams(request);
    const url = new URL(request.url);
    const status = url.searchParams.get('status');
    const pipeline = url.searchParams.get('pipeline');
    const owner = url.searchParams.get('owner');

    let query = ctx.supabase
      .from('deals')
      .select(
        '*, contact:contacts(id,name,phone,email,company), lead:leads(id,status,priority), stage:pipeline_stages(id,name,stage_kind,default_probability), assignee:profiles!deals_assigned_to_fkey(user_id,full_name,avatar_url)',
      )
      .eq('account_id', ctx.accountId)
      .is('archived_at', null)
      .order('created_at', { ascending: false })
      .order('id', { ascending: false })
      .limit(limit + 1);

    if (status) query = query.eq('status', status);
    if (pipeline) query = query.eq('pipeline_id', pipeline);
    if (owner) query = query.eq('assigned_to', owner);

    const filter = keysetFilter(cursor);
    if (filter) query = query.or(filter);

    const { data, error } = await query;
    if (error) {
      console.error('[api/v1/opportunities] list error:', error);
      return fail('internal', 'Failed to list opportunities', 500);
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
    const ctx = await requireApiKey(request, 'opportunities:write');
    const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
    if (!body || typeof body !== 'object') {
      return fail('bad_request', 'Request body must be a JSON object', 400);
    }

    const leadId = requiredText(body, 'lead_id');
    const pipelineId = requiredText(body, 'pipeline_id');
    const stageId = requiredText(body, 'stage_id');
    const title = requiredText(body, 'title');
    const nextTaskTitle = requiredText(body, 'next_task_title');
    const nextTaskDueRaw = requiredText(body, 'next_task_due_at');

    for (const [field, value] of [
      ['lead_id', leadId],
      ['pipeline_id', pipelineId],
      ['stage_id', stageId],
    ] as const) {
      if (!value || !UUID_RE.test(value)) {
        return fail('bad_request', `'${field}' is required and must be a UUID`, 400);
      }
    }
    if (!title) return fail('bad_request', "'title' is required", 400);
    if (!nextTaskTitle) return fail('bad_request', "'next_task_title' is required", 400);
    if (!nextTaskDueRaw || !Number.isFinite(new Date(nextTaskDueRaw).getTime())) {
      return fail('bad_request', "'next_task_due_at' must be a valid ISO date", 400);
    }

    const numericValue = typeof body.value === 'number' ? body.value : Number(body.value ?? 0);
    if (!Number.isFinite(numericValue) || numericValue < 0) {
      return fail('bad_request', "'value' must be a non-negative number", 400);
    }

    const expectedClose = requiredText(body, 'expected_close_date');
    if (expectedClose && !/^\d{4}-\d{2}-\d{2}$/.test(expectedClose)) {
      return fail('bad_request', "'expected_close_date' must use YYYY-MM-DD", 400);
    }

    const auditUserId = await resolveAuditUserId(ctx.supabase, ctx.accountId);
    const { data, error } = await ctx.supabase.rpc('convert_lead_to_opportunity', {
      p_lead_id: leadId,
      p_pipeline_id: pipelineId,
      p_stage_id: stageId,
      p_title: title,
      p_value: numericValue,
      p_currency: requiredText(body, 'currency') ?? 'BRL',
      p_expected_close_date: expectedClose ?? null,
      p_next_task_title: nextTaskTitle,
      p_next_task_due_at: new Date(nextTaskDueRaw).toISOString(),
      p_actor: auditUserId,
    });

    if (error) {
      console.error('[api/v1/opportunities] conversion error:', error);
      const validation = ['23514', '23503', '42501', '23505'].includes(error.code ?? '');
      return fail(
        validation ? 'bad_request' : 'internal',
        validation ? error.message : 'Failed to convert lead',
        validation ? 400 : 500,
      );
    }

    return ok(data, 201);
  } catch (error) {
    return toApiErrorResponse(error);
  }
}
