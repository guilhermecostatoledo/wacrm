import type { CrmPriority, TaskStatus, TaskType } from "@/lib/crm/domain";

export type AgendaBucket = "overdue" | "today" | "upcoming" | "completed" | "cancelled";

export interface TaskCreateInput {
  contactId: string;
  leadId?: string;
  opportunityId?: string;
  conversationId?: string;
  assignedTo?: string;
  taskType: TaskType;
  title: string;
  description?: string;
  priority: CrmPriority;
  dueAt: string;
  recurrenceRule?: string;
}

export type TaskCreateParseResult =
  | { ok: true; value: TaskCreateInput }
  | { ok: false; error: string };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const TASK_TYPES: readonly TaskType[] = [
  "call",
  "whatsapp",
  "email",
  "meeting",
  "visit",
  "follow_up",
  "qualification",
  "proposal",
  "custom",
];
const PRIORITIES: readonly CrmPriority[] = ["low", "normal", "high", "urgent"];

function optionalUuid(value: unknown, field: string): string | undefined | { error: string } {
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value !== "string" || !UUID_RE.test(value)) {
    return { error: `'${field}' must be a UUID` };
  }
  return value;
}

function optionalText(value: unknown, maxLength: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = value.trim();
  return text ? text.slice(0, maxLength) : undefined;
}

function parseRelatedUuid(
  value: unknown,
  field: string,
): { ok: true; value?: string } | { ok: false; error: string } {
  const parsed = optionalUuid(value, field);
  if (parsed && typeof parsed !== "string") return { ok: false, error: parsed.error };
  return { ok: true, value: parsed };
}

export function parseTaskCreateInput(raw: unknown): TaskCreateParseResult {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return { ok: false, error: "Request body must be a JSON object" };
  }

  const input = raw as Record<string, unknown>;
  const contact = parseRelatedUuid(input.contact_id, "contact_id");
  if (!contact.ok) return contact;
  if (!contact.value) return { ok: false, error: "'contact_id' is required" };

  const lead = parseRelatedUuid(input.lead_id, "lead_id");
  if (!lead.ok) return lead;
  const opportunity = parseRelatedUuid(input.opportunity_id, "opportunity_id");
  if (!opportunity.ok) return opportunity;
  const conversation = parseRelatedUuid(input.conversation_id, "conversation_id");
  if (!conversation.ok) return conversation;
  const assignee = parseRelatedUuid(input.assigned_to, "assigned_to");
  if (!assignee.ok) return assignee;

  const taskType = optionalText(input.task_type, 32) ?? "follow_up";
  if (!(TASK_TYPES as readonly string[]).includes(taskType)) {
    return { ok: false, error: "'task_type' is invalid" };
  }

  const title = optionalText(input.title, 200);
  if (!title) return { ok: false, error: "'title' is required" };

  const priority = optionalText(input.priority, 16) ?? "normal";
  if (!(PRIORITIES as readonly string[]).includes(priority)) {
    return { ok: false, error: "'priority' is invalid" };
  }

  const dueAtRaw = optionalText(input.due_at, 64);
  if (!dueAtRaw) return { ok: false, error: "'due_at' is required" };
  const dueAt = new Date(dueAtRaw);
  if (!Number.isFinite(dueAt.getTime())) {
    return { ok: false, error: "'due_at' must be a valid ISO date" };
  }

  const recurrenceRule = optionalText(input.recurrence_rule, 500);
  if (recurrenceRule && !/^FREQ=(DAILY|WEEKLY|MONTHLY)(;INTERVAL=\d{1,3})?$/i.test(recurrenceRule)) {
    return {
      ok: false,
      error: "'recurrence_rule' supports FREQ=DAILY|WEEKLY|MONTHLY with optional INTERVAL",
    };
  }

  return {
    ok: true,
    value: {
      contactId: contact.value,
      leadId: lead.value,
      opportunityId: opportunity.value,
      conversationId: conversation.value,
      assignedTo: assignee.value,
      taskType: taskType as TaskType,
      title,
      description: optionalText(input.description, 4000),
      priority: priority as CrmPriority,
      dueAt: dueAt.toISOString(),
      recurrenceRule: recurrenceRule?.toUpperCase(),
    },
  };
}

export function agendaBucket(
  status: TaskStatus,
  dueAt: string | Date,
  now = new Date(),
): AgendaBucket {
  if (status === "completed") return "completed";
  if (status === "cancelled") return "cancelled";

  const due = dueAt instanceof Date ? dueAt : new Date(dueAt);
  const dayStart = new Date(now);
  dayStart.setHours(0, 0, 0, 0);
  const tomorrow = new Date(dayStart);
  tomorrow.setDate(tomorrow.getDate() + 1);

  if (due.getTime() < dayStart.getTime()) return "overdue";
  if (due.getTime() < tomorrow.getTime()) return "today";
  return "upcoming";
}

export function nextRecurrenceDueAt(currentDueAt: string | Date, recurrenceRule: string): Date {
  const due = currentDueAt instanceof Date ? new Date(currentDueAt) : new Date(currentDueAt);
  if (!Number.isFinite(due.getTime())) throw new Error("Invalid current due date");

  const match = /^FREQ=(DAILY|WEEKLY|MONTHLY)(?:;INTERVAL=(\d{1,3}))?$/i.exec(recurrenceRule);
  if (!match) throw new Error("Unsupported recurrence rule");
  const interval = Number(match[2] ?? 1);
  if (interval < 1) throw new Error("Recurrence interval must be positive");

  switch (match[1].toUpperCase()) {
    case "DAILY":
      due.setUTCDate(due.getUTCDate() + interval);
      break;
    case "WEEKLY":
      due.setUTCDate(due.getUTCDate() + interval * 7);
      break;
    case "MONTHLY":
      due.setUTCMonth(due.getUTCMonth() + interval);
      break;
  }
  return due;
}
