import { requireApiKey } from '@/lib/auth/api-context';
import { fail, ok, toApiErrorResponse } from '@/lib/api/v1/respond';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function GET(request: Request) {
  try {
    const ctx = await requireApiKey(request, 'audit:read');
    const url = new URL(request.url);
    const limitRaw = Number(url.searchParams.get('limit') ?? 100);
    const limit = Math.min(Math.max(Number.isFinite(limitRaw) ? Math.trunc(limitRaw) : 100, 1), 500);
    const beforeRaw = url.searchParams.get('before');
    const before = beforeRaw ? new Date(beforeRaw) : null;
    if (beforeRaw && (!before || !Number.isFinite(before.getTime()))) {
      return fail('bad_request', "'before' must be a valid ISO date", 400);
    }

    const actor = url.searchParams.get('actor');
    if (actor && !UUID_RE.test(actor)) {
      return fail('bad_request', "'actor' must be a UUID", 400);
    }

    const { data, error } = await ctx.supabase.rpc('crm_audit_feed', {
      p_account_id: ctx.accountId,
      p_limit: limit,
      p_before: before?.toISOString() ?? null,
      p_event_type: url.searchParams.get('event_type') || null,
      p_aggregate_type: url.searchParams.get('aggregate_type') || null,
      p_actor_user_id: actor || null,
    });

    if (error) {
      console.error('[api/v1/audit/events] feed error:', error);
      const validation = ['23514', '42501'].includes(error.code ?? '');
      return fail(
        validation ? 'bad_request' : 'internal',
        validation ? error.message : 'Failed to load audit feed',
        validation ? 400 : 500,
      );
    }

    return ok(data);
  } catch (error) {
    return toApiErrorResponse(error);
  }
}
