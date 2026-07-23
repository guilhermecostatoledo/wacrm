import { requireApiKey } from '@/lib/auth/api-context';
import { fail, ok, toApiErrorResponse } from '@/lib/api/v1/respond';

function parseDate(value: string | null, fallback: Date): Date | null {
  if (!value) return fallback;
  const date = new Date(value);
  return Number.isFinite(date.getTime()) ? date : null;
}

export async function GET(request: Request) {
  try {
    const ctx = await requireApiKey(request, 'reports:read');
    const url = new URL(request.url);
    const now = new Date();
    const defaultFrom = new Date(now);
    defaultFrom.setUTCDate(defaultFrom.getUTCDate() - 30);

    const from = parseDate(url.searchParams.get('from'), defaultFrom);
    const to = parseDate(url.searchParams.get('to'), now);
    if (!from || !to || to.getTime() <= from.getTime()) {
      return fail('bad_request', "'from' and 'to' must define a valid ISO period", 400);
    }

    const { data, error } = await ctx.supabase.rpc('crm_management_report', {
      p_account_id: ctx.accountId,
      p_from: from.toISOString(),
      p_to: to.toISOString(),
    });

    if (error) {
      console.error('[api/v1/reports/management] report error:', error);
      const validation = ['23514', '42501'].includes(error.code ?? '');
      return fail(
        validation ? 'bad_request' : 'internal',
        validation ? error.message : 'Failed to generate management report',
        validation ? 400 : 500,
      );
    }

    return ok(data);
  } catch (error) {
    return toApiErrorResponse(error);
  }
}
