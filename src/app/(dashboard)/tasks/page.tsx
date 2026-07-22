'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  CalendarClock,
  Check,
  CircleX,
  Clock3,
  ListTodo,
  Loader2,
  Plus,
  RefreshCw,
  RotateCcw,
  TriangleAlert,
} from 'lucide-react';
import { toast } from 'sonner';

import { Button } from '@/components/ui/button';
import { createClient } from '@/lib/supabase/client';
import { useAuth } from '@/hooks/use-auth';
import type {
  CrmTask,
  CrmTaskStatus,
  CrmTaskType,
  Lead,
  LeadPriority,
} from '@/types/crm';
import {
  isTaskDueToday,
  isTaskOverdue,
  LEAD_PRIORITY_LABELS,
} from '@/lib/crm/lifecycle';

interface TaskRow extends CrmTask {
  lead?: Pick<Lead, 'id' | 'title' | 'status' | 'priority'> | null;
  contact?: { id: string; name?: string | null; phone: string } | null;
  deal?: { id: string; title: string; status?: 'open' | 'won' | 'lost' } | null;
}

type QueueFilter = 'open' | 'overdue' | 'today' | 'completed' | 'all';

const TASK_TYPES: Array<{ value: CrmTaskType; label: string }> = [
  { value: 'call', label: 'Ligação' },
  { value: 'whatsapp', label: 'WhatsApp' },
  { value: 'email', label: 'E-mail' },
  { value: 'meeting', label: 'Reunião' },
  { value: 'follow_up', label: 'Retorno' },
  { value: 'qualification', label: 'Qualificação' },
  { value: 'other', label: 'Outra' },
];

function toLocalDateTimeInput(date: Date) {
  const offset = date.getTimezoneOffset();
  return new Date(date.getTime() - offset * 60_000).toISOString().slice(0, 16);
}

function formatDate(value: string) {
  return new Intl.DateTimeFormat('pt-BR', {
    dateStyle: 'short',
    timeStyle: 'short',
  }).format(new Date(value));
}

function statusLabel(status: CrmTaskStatus) {
  if (status === 'completed') return 'Concluída';
  if (status === 'cancelled') return 'Cancelada';
  return 'Aberta';
}

export default function TasksPage() {
  const supabase = createClient();
  const { user, accountId, canSendMessages, profileLoading } = useAuth();

  const [tasks, setTasks] = useState<TaskRow[]>([]);
  const [leads, setLeads] = useState<Lead[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [filter, setFilter] = useState<QueueFilter>('open');

  const [leadId, setLeadId] = useState('');
  const [title, setTitle] = useState('');
  const [taskType, setTaskType] = useState<CrmTaskType>('follow_up');
  const [priority, setPriority] = useState<LeadPriority>('medium');
  const [dueAt, setDueAt] = useState(() =>
    toLocalDateTimeInput(new Date(Date.now() + 60 * 60 * 1000)),
  );

  const fetchData = useCallback(async () => {
    if (!user?.id) return;
    setLoading(true);

    const [tasksResult, leadsResult] = await Promise.all([
      supabase
        .from('crm_tasks')
        .select(
          '*, lead:leads(id, title, status, priority), contact:contacts(id, name, phone), deal:deals(id, title, status)',
        )
        .eq('assigned_to', user.id)
        .order('due_at', { ascending: true }),
      supabase
        .from('leads')
        .select('*')
        .not('status', 'in', '(disqualified,converted,archived)')
        .order('created_at', { ascending: false }),
    ]);

    if (tasksResult.error) {
      toast.error('Não foi possível carregar as tarefas');
    } else {
      setTasks((tasksResult.data ?? []) as TaskRow[]);
    }

    if (leadsResult.error) {
      toast.error('Não foi possível carregar os leads ativos');
    } else {
      setLeads((leadsResult.data ?? []) as Lead[]);
    }

    setLoading(false);
  }, [supabase, user?.id]);

  useEffect(() => {
    if (profileLoading || !user?.id) return;
    void fetchData();
  }, [fetchData, profileLoading, user?.id]);

  useEffect(() => {
    if (!accountId || !user?.id) return;

    const channel = supabase
      .channel(`crm-tasks:${accountId}:${user.id}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'crm_tasks',
          filter: `account_id=eq.${accountId}`,
        },
        () => void fetchData(),
      )
      .subscribe();

    return () => {
      void supabase.removeChannel(channel);
    };
  }, [accountId, fetchData, supabase, user?.id]);

  const now = new Date();
  const metrics = useMemo(() => {
    const open = tasks.filter((task) => task.status === 'open');
    return {
      open: open.length,
      overdue: open.filter((task) => isTaskOverdue(task.due_at, task.status)).length,
      today: open.filter((task) => isTaskDueToday(task.due_at)).length,
      completed: tasks.filter((task) => task.status === 'completed').length,
    };
  }, [tasks]);

  const visibleTasks = useMemo(() => {
    return tasks.filter((task) => {
      if (filter === 'all') return true;
      if (filter === 'overdue') return isTaskOverdue(task.due_at, task.status, now);
      if (filter === 'today') return task.status === 'open' && isTaskDueToday(task.due_at, now);
      if (filter === 'completed') return task.status === 'completed';
      return task.status === 'open';
    });
  }, [filter, now, tasks]);

  async function createTask() {
    if (!leadId || !title.trim() || !dueAt || !accountId || !user?.id) {
      toast.error('Preencha lead, título e vencimento');
      return;
    }

    setSaving(true);
    const { error } = await supabase.from('crm_tasks').insert({
      account_id: accountId,
      lead_id: leadId,
      created_by_user_id: user.id,
      assigned_to: user.id,
      title: title.trim(),
      task_type: taskType,
      status: 'open',
      priority,
      due_at: new Date(dueAt).toISOString(),
    });
    setSaving(false);

    if (error) {
      toast.error('Não foi possível criar a tarefa');
      return;
    }

    toast.success('Tarefa criada e vinculada ao lead');
    setTitle('');
    setLeadId('');
    setTaskType('follow_up');
    setPriority('medium');
    setDueAt(toLocalDateTimeInput(new Date(Date.now() + 60 * 60 * 1000)));
    await fetchData();
  }

  async function setTaskStatus(task: TaskRow, status: CrmTaskStatus) {
    const { error } = await supabase
      .from('crm_tasks')
      .update({ status })
      .eq('id', task.id);

    if (error) {
      toast.error('Não foi possível atualizar a tarefa');
      return;
    }

    toast.success(
      status === 'completed'
        ? 'Tarefa concluída'
        : status === 'cancelled'
          ? 'Tarefa cancelada'
          : 'Tarefa reaberta',
    );
    await fetchData();
  }

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-foreground">Meu dia</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Uma fila única para atrasos, ações de hoje e próximos retornos.
          </p>
        </div>
        <Button variant="outline" onClick={() => void fetchData()} disabled={loading}>
          <RefreshCw className="mr-2 size-4" />
          Atualizar
        </Button>
      </div>

      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <QueueMetric label="Abertas" value={metrics.open} icon={ListTodo} />
        <QueueMetric label="Atrasadas" value={metrics.overdue} icon={TriangleAlert} />
        <QueueMetric label="Para hoje" value={metrics.today} icon={CalendarClock} />
        <QueueMetric label="Concluídas" value={metrics.completed} icon={Check} />
      </div>

      <section className="rounded-xl border border-border bg-card p-4 shadow-sm">
        <div className="mb-4">
          <h2 className="font-semibold text-foreground">Nova tarefa</h2>
          <p className="text-sm text-muted-foreground">
            Toda tarefa fica ligada a um lead e atualiza automaticamente sua próxima ação.
          </p>
        </div>

        <div className="grid gap-3 xl:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)_160px_160px_210px_auto]">
          <select
            value={leadId}
            onChange={(event) => setLeadId(event.target.value)}
            disabled={!canSendMessages}
            className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground outline-none focus:ring-2 focus:ring-ring"
          >
            <option value="">Selecione o lead</option>
            {leads.map((lead) => (
              <option key={lead.id} value={lead.id}>
                {lead.title}
              </option>
            ))}
          </select>

          <input
            value={title}
            onChange={(event) => setTitle(event.target.value)}
            disabled={!canSendMessages}
            placeholder="Ex.: Retornar proposta"
            className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground outline-none placeholder:text-muted-foreground focus:ring-2 focus:ring-ring"
          />

          <select
            value={taskType}
            onChange={(event) => setTaskType(event.target.value as CrmTaskType)}
            disabled={!canSendMessages}
            className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground outline-none focus:ring-2 focus:ring-ring"
          >
            {TASK_TYPES.map((item) => (
              <option key={item.value} value={item.value}>
                {item.label}
              </option>
            ))}
          </select>

          <select
            value={priority}
            onChange={(event) => setPriority(event.target.value as LeadPriority)}
            disabled={!canSendMessages}
            className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground outline-none focus:ring-2 focus:ring-ring"
          >
            {(['low', 'medium', 'high', 'urgent'] as LeadPriority[]).map((item) => (
              <option key={item} value={item}>
                {LEAD_PRIORITY_LABELS[item]}
              </option>
            ))}
          </select>

          <input
            type="datetime-local"
            value={dueAt}
            onChange={(event) => setDueAt(event.target.value)}
            disabled={!canSendMessages}
            className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground outline-none focus:ring-2 focus:ring-ring"
          />

          <Button onClick={() => void createTask()} disabled={!canSendMessages || saving}>
            {saving ? <Loader2 className="mr-2 size-4 animate-spin" /> : <Plus className="mr-2 size-4" />}
            Criar
          </Button>
        </div>
      </section>

      <section className="rounded-xl border border-border bg-card shadow-sm">
        <div className="flex flex-wrap gap-2 border-b border-border p-4">
          {(
            [
              ['open', `Abertas (${metrics.open})`],
              ['overdue', `Atrasadas (${metrics.overdue})`],
              ['today', `Hoje (${metrics.today})`],
              ['completed', `Concluídas (${metrics.completed})`],
              ['all', 'Todas'],
            ] as Array<[QueueFilter, string]>
          ).map(([value, label]) => (
            <Button
              key={value}
              size="sm"
              variant={filter === value ? 'default' : 'outline'}
              onClick={() => setFilter(value)}
            >
              {label}
            </Button>
          ))}
        </div>

        {loading ? (
          <div className="flex min-h-56 items-center justify-center text-muted-foreground">
            <Loader2 className="mr-2 size-5 animate-spin" /> Carregando tarefas...
          </div>
        ) : visibleTasks.length === 0 ? (
          <div className="flex min-h-56 flex-col items-center justify-center px-6 text-center">
            <Clock3 className="mb-3 size-8 text-muted-foreground" />
            <p className="font-medium text-foreground">Nenhuma tarefa nesta fila</p>
            <p className="mt-1 text-sm text-muted-foreground">
              Novos leads recebem automaticamente uma tarefa de primeiro contato.
            </p>
          </div>
        ) : (
          <div className="divide-y divide-border">
            {visibleTasks.map((task) => {
              const overdue = isTaskOverdue(task.due_at, task.status);
              const typeLabel = TASK_TYPES.find((item) => item.value === task.task_type)?.label ?? task.task_type;

              return (
                <article
                  key={task.id}
                  className="grid gap-4 p-4 xl:grid-cols-[minmax(0,1.4fr)_180px_190px_auto] xl:items-center"
                >
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <h3 className="truncate font-semibold text-foreground">{task.title}</h3>
                      <span className="rounded-full border border-border bg-muted px-2 py-0.5 text-xs text-muted-foreground">
                        {typeLabel}
                      </span>
                      <span className="rounded-full border border-border bg-background px-2 py-0.5 text-xs text-muted-foreground">
                        {LEAD_PRIORITY_LABELS[task.priority]}
                      </span>
                    </div>
                    <p className="mt-1 text-sm text-muted-foreground">
                      {task.lead?.title || task.deal?.title || task.contact?.name || 'Registro relacionado'}
                    </p>
                    {task.contact?.phone ? (
                      <p className="mt-0.5 text-xs text-muted-foreground">{task.contact.phone}</p>
                    ) : null}
                  </div>

                  <div>
                    <p className="text-xs uppercase tracking-wide text-muted-foreground">Vencimento</p>
                    <p className={`mt-1 text-sm font-medium ${overdue ? 'text-red-300' : 'text-foreground'}`}>
                      {formatDate(task.due_at)}
                    </p>
                  </div>

                  <div>
                    <p className="text-xs uppercase tracking-wide text-muted-foreground">Situação</p>
                    <p className="mt-1 text-sm font-medium text-foreground">{statusLabel(task.status)}</p>
                  </div>

                  <div className="flex flex-wrap justify-end gap-2">
                    {task.status === 'open' ? (
                      <>
                        <Button
                          size="sm"
                          disabled={!canSendMessages}
                          onClick={() => void setTaskStatus(task, 'completed')}
                        >
                          <Check className="mr-2 size-4" /> Concluir
                        </Button>
                        <Button
                          size="sm"
                          variant="ghost"
                          disabled={!canSendMessages}
                          onClick={() => void setTaskStatus(task, 'cancelled')}
                        >
                          <CircleX className="mr-2 size-4" /> Cancelar
                        </Button>
                      </>
                    ) : (
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={!canSendMessages}
                        onClick={() => void setTaskStatus(task, 'open')}
                      >
                        <RotateCcw className="mr-2 size-4" /> Reabrir
                      </Button>
                    )}
                  </div>
                </article>
              );
            })}
          </div>
        )}
      </section>
    </div>
  );
}

function QueueMetric({
  label,
  value,
  icon: Icon,
}: {
  label: string;
  value: number;
  icon: typeof ListTodo;
}) {
  return (
    <div className="rounded-xl border border-border bg-card p-4 shadow-sm">
      <div className="flex items-center justify-between">
        <p className="text-sm text-muted-foreground">{label}</p>
        <Icon className="size-4 text-muted-foreground" />
      </div>
      <p className="mt-2 text-2xl font-semibold text-foreground">{value}</p>
    </div>
  );
}
