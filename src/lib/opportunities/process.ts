export type OpportunityStatus = "open" | "won" | "lost" | "cancelled";
export type PipelineStageKind = "open" | "won" | "lost";

export interface OpportunityCloseInput {
  action: "win" | "lose" | "reopen";
  lossReasonId?: string;
  reopenStageId?: string;
  nextTaskTitle?: string;
  nextTaskDueAt?: string;
}

export type OpportunityCloseParseResult =
  | { ok: true; value: OpportunityCloseInput }
  | { ok: false; error: string };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function optionalText(value: unknown, maxLength: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = value.trim();
  return text ? text.slice(0, maxLength) : undefined;
}

export function canMoveOpportunity(
  status: OpportunityStatus,
  targetStageKind: PipelineStageKind,
): boolean {
  if (status !== "open") return false;
  return targetStageKind === "open" || targetStageKind === "won";
}

export function probabilityForStage(
  stageKind: PipelineStageKind,
  defaultProbability: number,
): number {
  if (stageKind === "won") return 100;
  if (stageKind === "lost") return 0;
  return Math.max(0, Math.min(99, Math.round(defaultProbability)));
}

export function parseOpportunityCloseInput(raw: unknown): OpportunityCloseParseResult {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return { ok: false, error: "Request body must be a JSON object" };
  }
  const input = raw as Record<string, unknown>;
  const action = optionalText(input.action, 16);
  if (action !== "win" && action !== "lose" && action !== "reopen") {
    return { ok: false, error: "'action' must be win, lose or reopen" };
  }

  const lossReasonId = optionalText(input.loss_reason_id, 36);
  if (action === "lose" && (!lossReasonId || !UUID_RE.test(lossReasonId))) {
    return { ok: false, error: "'loss_reason_id' is required and must be a UUID" };
  }

  const reopenStageId = optionalText(input.reopen_stage_id, 36);
  if (action === "reopen" && reopenStageId && !UUID_RE.test(reopenStageId)) {
    return { ok: false, error: "'reopen_stage_id' must be a UUID" };
  }

  const nextTaskDueAt = optionalText(input.next_task_due_at, 64);
  if (action === "reopen") {
    if (!nextTaskDueAt || !Number.isFinite(new Date(nextTaskDueAt).getTime())) {
      return { ok: false, error: "'next_task_due_at' is required and must be a valid ISO date" };
    }
  }

  return {
    ok: true,
    value: {
      action,
      lossReasonId,
      reopenStageId,
      nextTaskTitle: optionalText(input.next_task_title, 200),
      nextTaskDueAt: nextTaskDueAt ? new Date(nextTaskDueAt).toISOString() : undefined,
    },
  };
}
