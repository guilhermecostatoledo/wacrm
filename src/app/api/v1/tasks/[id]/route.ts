// ============================================================
// PATCH /api/v1/tasks/{id} — task command endpoint (scope: tasks:write)
//
// Body actions:
//   { action: "start" }
//   { action: "complete", outcome: "...", create_next?: boolean }
//   { action: "cancel", reason: "..." }
//   { action: "reassign", assigned_to: "uuid", reason: "..." }
// ============================================================

import { requireApiKey } from '@/lib/auth/api-context';
import { fail, ok, toApiErrorResponse } from '@/lib/api/v1/respond';

interface RouteContext {
  params: Promise<{ id: string }>;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const ctx = await requireApiKey(request, 'tasks:write');
    const { id } = await context.params;
    if (!UUID_RE.test(id)) return fail('bad_request', 'Invalid task id', 400);

    const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
    if (!body || typeof body !== 'object') {
      return fail('bad_request', 'Request body must be a JSON object', 400);
    }

    const action = text(body.action);
    let rpcName:
      | 'start_crm_task'
      | 'complete_crm_task'
      | 'cancel_crm_task'
      | 'reassign_crm_task';
    let args: Record<string, unknown>;

    switch (action) {
      case 'start':
        rpcName = 'start_crm_task';
        args = { p_task_id: id };
        break;
      case 'complete': {
        const outcome = text(body.outcome);
        if (!outcome) return fail('bad_request', "'outcome' is required", 400);
        rpcName = 'complete_crm_task';
        args = {
          p_task_id: id,
          p_outcome: outcome,
          p_create_next: body.create_next !== false,
        };
        break;
      }
      case 'cancel': {
        const reason = text(body.reason);
        if (!reason) return fail('bad_request', "'reason' is required", 400);
        rpcName = 'cancel_crm_task';
        args = { p_task_id: id, p_reason: reason };
        break;
      }
      case 'reassign': {
        const assignedTo = text(body.assigned_to);
        const reason = text(body.reason);
        if (!UUID_RE.test(assignedTo)) {
          return fail('bad_request', "'assigned_to' must be a UUID", 400);
        }
        if (!reason) return fail('bad_request', "'reason' is required", 400);
        rpcName = 'reassign_crm_task';
        args = { p_task_id: id, p_assigned_to: assignedTo, p_reason: reason };
        break;
      }
      default:
        return fail(
          'bad_request',
          "'action' must be start, complete, cancel or reassign",
          400,
        );
    }

    const { data, error } = await ctx.supabase.rpc(rpcName, args);
    if (error) {
      console.error(`[api/v1/tasks/${id}] ${action} error:`, error);
      const validation = ['23514', '23503', '42501'].includes(error.code ?? '');
      return fail(
        validation ? 'bad_request' : 'internal',
        validation ? error.message : 'Failed to update task',
        validation ? 400 : 500,
      );
    }

    return ok(data);
  } catch (error) {
    return toApiErrorResponse(error);
  }
}
