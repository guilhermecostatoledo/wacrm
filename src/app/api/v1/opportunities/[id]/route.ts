// ============================================================
// PATCH /api/v1/opportunities/{id} — move/close/reopen/archive commands
// ============================================================

import { requireApiKey } from '@/lib/auth/api-context';
import { resolveAuditUserId } from '@/lib/api/v1/contacts';
import { fail, ok, toApiErrorResponse } from '@/lib/api/v1/respond';

type OpportunityAction = 'move' | 'win' | 'lose' | 'reopen' | 'archive';

interface RouteContext {
  params: Promise<{ id: string }>;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
    if (!body || typeof body !== 'object') {
      return fail('bad_request', 'Request body must be a JSON object', 400);
    }

    const action = text(body.action) as OpportunityAction;
    const closeAction = action === 'win' || action === 'lose' || action === 'reopen';
    const ctx = await requireApiKey(
      request,
      closeAction ? 'opportunities:close' : 'opportunities:write',
    );
    const { id } = await context.params;
    if (!UUID_RE.test(id)) return fail('bad_request', 'Invalid opportunity id', 400);

    const auditUserId = await resolveAuditUserId(ctx.supabase, ctx.accountId);
    let rpcName:
      | 'move_opportunity'
      | 'close_opportunity_lost'
      | 'reopen_opportunity'
      | 'archive_opportunity';
    let args: Record<string, unknown>;

    switch (action) {
      case 'move':
      case 'win': {
        const stageId = text(body.stage_id);
        if (!UUID_RE.test(stageId)) {
          return fail('bad_request', "'stage_id' is required and must be a UUID", 400);
        }
        const nextTaskDue = text(body.next_task_due_at);
        if (nextTaskDue && !Number.isFinite(new Date(nextTaskDue).getTime())) {
          return fail('bad_request', "'next_task_due_at' must be a valid ISO date", 400);
        }
        rpcName = 'move_opportunity';
        args = {
          p_opportunity_id: id,
          p_stage_id: stageId,
          p_next_task_title: text(body.next_task_title) || null,
          p_next_task_due_at: nextTaskDue ? new Date(nextTaskDue).toISOString() : null,
          p_actor: auditUserId,
        };
        break;
      }
      case 'lose': {
        const reasonId = text(body.loss_reason_id);
        const stageId = text(body.stage_id);
        if (!UUID_RE.test(reasonId)) {
          return fail('bad_request', "'loss_reason_id' is required and must be a UUID", 400);
        }
        if (stageId && !UUID_RE.test(stageId)) {
          return fail('bad_request', "'stage_id' must be a UUID", 400);
        }
        rpcName = 'close_opportunity_lost';
        args = {
          p_opportunity_id: id,
          p_loss_reason_id: reasonId,
          p_stage_id: stageId || null,
          p_notes: text(body.notes) || null,
          p_actor: auditUserId,
        };
        break;
      }
      case 'reopen': {
        const stageId = text(body.stage_id);
        const nextTaskTitle = text(body.next_task_title);
        const nextTaskDue = text(body.next_task_due_at);
        if (!UUID_RE.test(stageId)) {
          return fail('bad_request', "'stage_id' is required and must be a UUID", 400);
        }
        if (!nextTaskTitle) {
          return fail('bad_request', "'next_task_title' is required", 400);
        }
        if (!nextTaskDue || !Number.isFinite(new Date(nextTaskDue).getTime())) {
          return fail('bad_request', "'next_task_due_at' must be a valid ISO date", 400);
        }
        rpcName = 'reopen_opportunity';
        args = {
          p_opportunity_id: id,
          p_stage_id: stageId,
          p_next_task_title: nextTaskTitle,
          p_next_task_due_at: new Date(nextTaskDue).toISOString(),
          p_actor: auditUserId,
        };
        break;
      }
      case 'archive': {
        const reason = text(body.reason);
        if (!reason) return fail('bad_request', "'reason' is required", 400);
        rpcName = 'archive_opportunity';
        args = { p_opportunity_id: id, p_reason: reason, p_actor: auditUserId };
        break;
      }
      default:
        return fail(
          'bad_request',
          "'action' must be move, win, lose, reopen or archive",
          400,
        );
    }

    const { data, error } = await ctx.supabase.rpc(rpcName, args);
    if (error) {
      console.error(`[api/v1/opportunities/${id}] ${action} error:`, error);
      const validation = ['23514', '23503', '42501', '23505'].includes(error.code ?? '');
      return fail(
        validation ? 'bad_request' : 'internal',
        validation ? error.message : 'Failed to update opportunity',
        validation ? 400 : 500,
      );
    }
    return ok(data);
  } catch (error) {
    return toApiErrorResponse(error);
  }
}
