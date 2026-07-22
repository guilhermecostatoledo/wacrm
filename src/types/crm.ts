import type { Contact, Deal } from '@/types';

export type LeadStatus =
  | 'new'
  | 'attempting_contact'
  | 'contacted'
  | 'qualified'
  | 'disqualified'
  | 'converted'
  | 'archived';

export type LeadPriority = 'low' | 'medium' | 'high' | 'urgent';

export type CrmTaskStatus = 'open' | 'completed' | 'cancelled';

export type CrmTaskType =
  | 'call'
  | 'whatsapp'
  | 'email'
  | 'meeting'
  | 'follow_up'
  | 'qualification'
  | 'other';

export interface Lead {
  id: string;
  account_id: string;
  contact_id: string;
  created_by_user_id: string;
  assigned_to: string;
  title: string;
  source: string;
  status: LeadStatus;
  priority: LeadPriority;
  notes?: string | null;
  loss_reason?: string | null;
  next_action_at?: string | null;
  first_contact_at?: string | null;
  qualified_at?: string | null;
  closed_at?: string | null;
  archived_at?: string | null;
  created_at: string;
  updated_at: string;
  contact?: Pick<Contact, 'id' | 'name' | 'phone' | 'email' | 'company'> | null;
  tasks?: CrmTask[];
}

export interface CrmTask {
  id: string;
  account_id: string;
  lead_id?: string | null;
  deal_id?: string | null;
  contact_id?: string | null;
  created_by_user_id: string;
  assigned_to: string;
  title: string;
  description?: string | null;
  task_type: CrmTaskType;
  status: CrmTaskStatus;
  priority: LeadPriority;
  due_at: string;
  completed_at?: string | null;
  cancelled_at?: string | null;
  created_at: string;
  updated_at: string;
  lead?: Pick<Lead, 'id' | 'title' | 'status' | 'priority'> | null;
  contact?: Pick<Contact, 'id' | 'name' | 'phone'> | null;
  deal?: Pick<Deal, 'id' | 'title' | 'status'> | null;
}

export interface CrmActivity {
  id: string;
  account_id: string;
  actor_user_id?: string | null;
  contact_id?: string | null;
  lead_id?: string | null;
  deal_id?: string | null;
  task_id?: string | null;
  activity_type: string;
  description: string;
  metadata: Record<string, unknown>;
  created_at: string;
}

export interface CrmNotification {
  id: string;
  account_id: string;
  user_id: string;
  task_id: string;
  lead_id?: string | null;
  kind: 'task_due' | 'task_overdue' | string;
  title: string;
  read_at?: string | null;
  dismissed_at?: string | null;
  created_at: string;
}
