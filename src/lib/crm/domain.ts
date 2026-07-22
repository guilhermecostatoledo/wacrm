export const LEAD_STATUSES = [
  "new",
  "assigned",
  "attempting_contact",
  "connected",
  "qualifying",
  "qualified",
  "nurturing",
  "disqualified",
  "reopened",
  "converted",
] as const;

export type LeadStatus = (typeof LEAD_STATUSES)[number];

export const TASK_STATUSES = [
  "open",
  "in_progress",
  "completed",
  "cancelled",
] as const;

export type TaskStatus = (typeof TASK_STATUSES)[number];

export const OPPORTUNITY_STATUSES = ["open", "won", "lost"] as const;
export type OpportunityStatus = (typeof OPPORTUNITY_STATUSES)[number];

export type CrmPriority = "low" | "normal" | "high" | "urgent";

const LEAD_TRANSITIONS: Readonly<Record<LeadStatus, readonly LeadStatus[]>> = {
  new: ["assigned", "attempting_contact", "disqualified"],
  assigned: ["attempting_contact", "nurturing", "disqualified"],
  attempting_contact: ["connected", "nurturing", "disqualified"],
  connected: ["qualifying", "nurturing", "disqualified"],
  qualifying: ["qualified", "nurturing", "disqualified"],
  qualified: ["converted", "disqualified"],
  nurturing: ["attempting_contact", "disqualified"],
  disqualified: ["reopened"],
  reopened: ["attempting_contact", "qualifying", "disqualified"],
  converted: [],
};

const TASK_TRANSITIONS: Readonly<Record<TaskStatus, readonly TaskStatus[]>> = {
  open: ["in_progress", "completed", "cancelled"],
  in_progress: ["open", "completed", "cancelled"],
  completed: [],
  cancelled: ["open"],
};

export function canTransitionLead(from: LeadStatus, to: LeadStatus): boolean {
  return from === to || LEAD_TRANSITIONS[from].includes(to);
}

export function assertLeadTransition(from: LeadStatus, to: LeadStatus): void {
  if (!canTransitionLead(from, to)) {
    throw new Error(`Invalid lead status transition: ${from} -> ${to}`);
  }
}

export function canTransitionTask(from: TaskStatus, to: TaskStatus): boolean {
  return from === to || TASK_TRANSITIONS[from].includes(to);
}

export function assertTaskTransition(from: TaskStatus, to: TaskStatus): void {
  if (!canTransitionTask(from, to)) {
    throw new Error(`Invalid task status transition: ${from} -> ${to}`);
  }
}

export function isTerminalLeadStatus(status: LeadStatus): boolean {
  return status === "converted" || status === "disqualified";
}

export function isActionableTaskStatus(status: TaskStatus): boolean {
  return status === "open" || status === "in_progress";
}

export interface Lead {
  id: string;
  account_id: string;
  contact_id: string;
  source_id: string | null;
  owner_id: string | null;
  assigned_by: string | null;
  queue_key: string | null;
  status: LeadStatus;
  priority: CrmPriority;
  qualification_score: number | null;
  source_detail: Record<string, unknown>;
  first_response_due_at: string | null;
  first_contacted_at: string | null;
  qualified_at: string | null;
  disqualified_at: string | null;
  converted_at: string | null;
  disqualification_reason_id: string | null;
  external_key: string | null;
  created_by: string | null;
  created_at: string;
  updated_at: string;
  archived_at: string | null;
  archived_by: string | null;
  archive_reason: string | null;
}

export type ActivityType =
  | "call"
  | "whatsapp"
  | "email"
  | "meeting"
  | "visit"
  | "note"
  | "stage_change"
  | "assignment"
  | "proposal_sent"
  | "qualification"
  | "system";

export type ActivitySource = "human" | "system" | "integration" | "automation";

export interface Activity {
  id: string;
  account_id: string;
  contact_id: string;
  lead_id: string | null;
  opportunity_id: string | null;
  conversation_id: string | null;
  activity_type: ActivityType;
  summary: string;
  outcome: string | null;
  metadata: Record<string, unknown>;
  occurred_at: string;
  performed_by: string | null;
  source: ActivitySource;
  created_at: string;
  corrected_by: string | null;
  corrected_at: string | null;
  correction_reason: string | null;
}

export type TaskType =
  | "call"
  | "whatsapp"
  | "email"
  | "meeting"
  | "visit"
  | "follow_up"
  | "qualification"
  | "proposal"
  | "custom";

export interface CrmTask {
  id: string;
  account_id: string;
  contact_id: string;
  lead_id: string | null;
  opportunity_id: string | null;
  conversation_id: string | null;
  assigned_to: string;
  created_by: string | null;
  task_type: TaskType;
  title: string;
  description: string | null;
  priority: CrmPriority;
  status: TaskStatus;
  due_at: string;
  started_at: string | null;
  completed_at: string | null;
  cancelled_at: string | null;
  completion_outcome: string | null;
  cancellation_reason: string | null;
  recurrence_rule: string | null;
  parent_task_id: string | null;
  created_at: string;
  updated_at: string;
  archived_at: string | null;
}

export interface DomainEvent {
  id: string;
  account_id: string;
  aggregate_type: string;
  aggregate_id: string;
  event_type: string;
  actor_user_id: string | null;
  source: "human" | "system" | "integration" | "automation" | "migration";
  payload: Record<string, unknown>;
  correlation_id: string | null;
  causation_id: string | null;
  occurred_at: string;
}
