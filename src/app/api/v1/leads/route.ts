// ============================================================
// GET  /api/v1/leads — list account leads (scope: leads:read)
// POST /api/v1/leads — transactional lead intake (scope: leads:write)
// ============================================================

import { requireApiKey } from '@/lib/auth/api-context';
import { resolveAuditUserId } from '@/lib/api/v1/contacts';
import {
  buildPage,
  keysetFilter,
  parseListParams,
} from '@/lib/api/v1/pagination';
import { fail, ok, okList, toApiErrorResponse } from '@/lib/api/v1/respond';
import { parseLeadIntakeInput } from '@/lib/leads/intake';

export async function GET(request: Request) {
  try {
    const ctx = await requireApiKey(request, 'leads:read');
    const { limit, cursor } = parseListParams(request);
    const url = new URL(request.url);
    const status = url.searchParams.get('status');
    const owner = url.searchParams.get('owner');

    let query = ctx.supabase
      .from('leads')
      .select(
        '*, contact:contacts(id,name,phone,email,company,archived_at), source:lead_sources(id,code,name)',
      )
      .eq('account_id', ctx.accountId)
      .is('archived_at', null)
      .order('created_at', { ascending: false })
      .order('id', { ascending: false })
      .limit(limit + 1);

    if (status) query = query.eq('status', status);
    if (owner === 'unassigned') query = query.is('owner_id', null);
    else if (owner) query = query.eq('owner_id', owner);

    const filter = keysetFilter(cursor);
    if (filter) query = query.or(filter);

    const { data, error } = await query;
    if (error) {
      console.error('[api/v1/leads] list error:', error);
      return fail('internal', 'Failed to list leads', 500);
    }

    const { items, nextCursor } = buildPage(
      (data ?? []) as Array<{ created_at: string; id: string }>,
      limit,
    );
    return okList(items, nextCursor);
  } catch (error) {
    return toApiErrorResponse(error);
  }
}

export async function POST(request: Request) {
  try {
    const ctx = await requireApiKey(request, 'leads:write');
    const parsed = parseLeadIntakeInput(await request.json().catch(() => null));
    if (!parsed.ok) return fail('bad_request', parsed.error, 400);

    const input = parsed.value;
    const auditUserId = await resolveAuditUserId(ctx.supabase, ctx.accountId);

    const { data, error } = await ctx.supabase.rpc('intake_lead', {
      p_account_id: ctx.accountId,
      p_phone: input.phone,
      p_name: input.name ?? null,
      p_email: input.email ?? null,
      p_company: input.company ?? null,
      p_source_code: input.sourceCode,
      p_external_key: input.externalKey ?? null,
      p_requested_owner_id: input.requestedOwnerId ?? null,
      p_source_detail: input.sourceDetail,
      p_first_response_minutes: input.firstResponseMinutes,
      p_create_first_task: input.createFirstTask,
      p_reopen_disqualified: input.reopenDisqualified,
      p_created_by: auditUserId,
    });

    if (error) {
      console.error('[api/v1/leads] intake error:', error);
      const isValidation =
        error.code === '23514' ||
        error.code === '23503' ||
        error.code === '42501';
      return fail(
        isValidation ? 'bad_request' : 'internal',
        isValidation ? error.message : 'Failed to capture lead',
        isValidation ? 400 : 500,
      );
    }

    const result = data as Record<string, unknown>;
    return ok(result, result.lead_created === true ? 201 : 200);
  } catch (error) {
    return toApiErrorResponse(error);
  }
}
