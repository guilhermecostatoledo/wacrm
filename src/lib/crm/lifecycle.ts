import type { LeadPriority, LeadStatus } from '@/types/crm';

export const LEAD_STATUS_LABELS: Record<LeadStatus, string> = {
  new: 'Novo',
  attempting_contact: 'Tentando contato',
  contacted: 'Contatado',
  qualified: 'Qualificado',
  disqualified: 'Desqualificado',
  converted: 'Convertido',
  archived: 'Arquivado',
};

export const LEAD_PRIORITY_LABELS: Record<LeadPriority, string> = {
  low: 'Baixa',
  medium: 'Média',
  high: 'Alta',
  urgent: 'Urgente',
};

const CLOSED_STATUSES = new Set<LeadStatus>([
  'disqualified',
  'converted',
  'archived',
]);

const TRANSITIONS: Record<LeadStatus, readonly LeadStatus[]> = {
  new: ['attempting_contact', 'contacted', 'disqualified', 'archived'],
  attempting_contact: ['contacted', 'disqualified', 'archived'],
  contacted: ['attempting_contact', 'qualified', 'disqualified', 'archived'],
  qualified: ['converted', 'disqualified', 'archived'],
  disqualified: ['new', 'archived'],
  converted: ['archived'],
  archived: ['new'],
};

export function isClosedLeadStatus(status: LeadStatus): boolean {
  return CLOSED_STATUSES.has(status);
}

export function canTransitionLead(
  current: LeadStatus,
  next: LeadStatus,
): boolean {
  return current === next || TRANSITIONS[current].includes(next);
}

export function getAvailableLeadStatuses(current: LeadStatus): LeadStatus[] {
  return [current, ...TRANSITIONS[current]];
}

export function isTaskOverdue(
  dueAt: string,
  status: 'open' | 'completed' | 'cancelled',
  now = new Date(),
): boolean {
  return status === 'open' && new Date(dueAt).getTime() < now.getTime();
}

export function isTaskDueToday(dueAt: string, now = new Date()): boolean {
  const due = new Date(dueAt);
  return (
    due.getFullYear() === now.getFullYear() &&
    due.getMonth() === now.getMonth() &&
    due.getDate() === now.getDate()
  );
}
