"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { CalendarClock, CheckCircle2, CirclePlay, Plus, Search, XCircle } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { EmptyState, ErrorState, LoadingState } from "@/components/crm/page-state";
import { StatusPill } from "@/components/crm/status-pill";
import { createClient } from "@/lib/supabase/client";
import { useAuth } from "@/hooks/use-auth";
import type { CrmTask, TaskType } from "@/lib/crm/domain";
import { agendaBucket, type AgendaBucket } from "@/lib/tasks/operations";
import { cn } from "@/lib/utils";

interface TaskRow extends CrmTask {
  contact: { id: string; name: string | null; phone: string } | null;
  lead: { id: string; status: string; priority: string } | null;
}

interface ContactOption {
  id: string;
  name: string | null;
  phone: string;
}

type ActionType = "complete" | "cancel" | null;

const BUCKET_LABELS: Record<AgendaBucket | "all", string> = {
  all: "Todas",
  overdue: "Atrasadas",
  today: "Hoje",
  upcoming: "Próximas",
  completed: "Concluídas",
  cancelled: "Canceladas",
};

function formatDue(value: string): string {
  return new Intl.DateTimeFormat("pt-BR", {
    weekday: "short",
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(value));
}

function toLocalInput(date: Date): string {
  const offset = date.getTimezoneOffset() * 60_000;
  return new Date(date.getTime() - offset).toISOString().slice(0, 16);
}

export default function TasksPage() {
  const { accountId, profile } = useAuth();
  const [tasks, setTasks] = useState<TaskRow[]>([]);
  const [contacts, setContacts] = useState<ContactOption[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [bucket, setBucket] = useState<AgendaBucket | "all">("today");
  const [search, setSearch] = useState("");
  const [onlyMine, setOnlyMine] = useState(true);
  const [createOpen, setCreateOpen] = useState(false);
  const [creating, setCreating] = useState(false);
  const [contactId, setContactId] = useState("");
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [taskType, setTaskType] = useState<TaskType>("follow_up");
  const [dueAt, setDueAt] = useState(() => toLocalInput(new Date(Date.now() + 60 * 60 * 1000)));
  const [actionTask, setActionTask] = useState<TaskRow | null>(null);
  const [actionType, setActionType] = useState<ActionType>(null);
  const [actionText, setActionText] = useState("");
  const [acting, setActing] = useState(false);

  const loadTasks = useCallback(async () => {
    if (!accountId) return;
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const [taskResult, contactResult] = await Promise.all([
      supabase
        .from("tasks")
        .select("*, contact:contacts(id,name,phone), lead:leads(id,status,priority)")
        .eq("account_id", accountId)
        .is("archived_at", null)
        .order("due_at", { ascending: true })
        .limit(1000),
      supabase
        .from("contacts")
        .select("id,name,phone")
        .eq("account_id", accountId)
        .is("archived_at", null)
        .order("name")
        .limit(500),
    ]);

    if (taskResult.error) {
      setError(taskResult.error.message);
      setTasks([]);
    } else {
      setTasks((taskResult.data ?? []) as unknown as TaskRow[]);
    }
    if (!contactResult.error) setContacts((contactResult.data ?? []) as ContactOption[]);
    setLoading(false);
  }, [accountId]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void loadTasks();
  }, [loadTasks]);

  const counts = useMemo(() => {
    const result: Record<AgendaBucket, number> = {
      overdue: 0,
      today: 0,
      upcoming: 0,
      completed: 0,
      cancelled: 0,
    };
    for (const task of tasks) result[agendaBucket(task.status, task.due_at)] += 1;
    return result;
  }, [tasks]);

  const filtered = useMemo(() => {
    const term = search.trim().toLowerCase();
    return tasks.filter((task) => {
      if (onlyMine && profile?.user_id && task.assigned_to !== profile.user_id) return false;
      if (bucket !== "all" && agendaBucket(task.status, task.due_at) !== bucket) return false;
      if (!term) return true;
      return [task.title, task.description, task.contact?.name, task.contact?.phone]
        .filter(Boolean)
        .some((value) => String(value).toLowerCase().includes(term));
    });
  }, [tasks, onlyMine, profile?.user_id, bucket, search]);

  async function createTask() {
    if (!accountId || !profile?.user_id || !contactId || !title.trim()) return;
    setCreating(true);
    const supabase = createClient();
    const { error: rpcError } = await supabase.rpc("create_crm_task", {
      p_account_id: accountId,
      p_contact_id: contactId,
      p_title: title.trim(),
      p_due_at: new Date(dueAt).toISOString(),
      p_assigned_to: profile.user_id,
      p_lead_id: null,
      p_opportunity_id: null,
      p_conversation_id: null,
      p_task_type: taskType,
      p_description: description.trim() || null,
      p_priority: "normal",
      p_recurrence_rule: null,
      p_created_by: profile.user_id,
    });

    if (rpcError) {
      toast.error(rpcError.message || "Não foi possível criar a tarefa");
    } else {
      toast.success("Tarefa criada");
      setCreateOpen(false);
      setContactId("");
      setTitle("");
      setDescription("");
      setTaskType("follow_up");
      setDueAt(toLocalInput(new Date(Date.now() + 60 * 60 * 1000)));
      await loadTasks();
    }
    setCreating(false);
  }

  async function startTask(task: TaskRow) {
    const supabase = createClient();
    const { error: rpcError } = await supabase.rpc("start_crm_task", { p_task_id: task.id });
    if (rpcError) toast.error(rpcError.message || "Não foi possível iniciar a tarefa");
    else {
      toast.success("Tarefa iniciada");
      await loadTasks();
    }
  }

  function openAction(task: TaskRow, type: Exclude<ActionType, null>) {
    setActionTask(task);
    setActionType(type);
    setActionText("");
  }

  async function submitAction() {
    if (!actionTask || !actionType || !actionText.trim()) return;
    setActing(true);
    const supabase = createClient();
    const result =
      actionType === "complete"
        ? await supabase.rpc("complete_crm_task", {
            p_task_id: actionTask.id,
            p_outcome: actionText.trim(),
            p_create_next: true,
          })
        : await supabase.rpc("cancel_crm_task", {
            p_task_id: actionTask.id,
            p_reason: actionText.trim(),
          });

    if (result.error) {
      toast.error(result.error.message || "Não foi possível atualizar a tarefa");
    } else {
      toast.success(actionType === "complete" ? "Tarefa concluída" : "Tarefa cancelada");
      setActionTask(null);
      setActionType(null);
      setActionText("");
      await loadTasks();
    }
    setActing(false);
  }

  return (
    <div className="space-y-5">
      <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.16em] text-primary">Execução diária</p>
          <h1 className="mt-1 text-2xl font-bold tracking-tight text-foreground">Tarefas</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Agenda compacta com prazos, resultados e recorrências rastreáveis.
          </p>
        </div>
        <Button onClick={() => setCreateOpen(true)}>
          <Plus className="h-4 w-4" />
          Nova tarefa
        </Button>
      </div>

      <div className="flex gap-2 overflow-x-auto pb-1">
        {(["today", "overdue", "upcoming", "completed", "cancelled", "all"] as const).map(
          (item) => (
            <button
              key={item}
              type="button"
              onClick={() => setBucket(item)}
              className={cn(
                "inline-flex shrink-0 items-center gap-2 rounded-lg border px-3 py-2 text-sm transition-colors",
                bucket === item
                  ? "border-primary/40 bg-primary/10 text-primary"
                  : "border-border bg-card text-muted-foreground hover:bg-muted hover:text-foreground",
              )}
            >
              {BUCKET_LABELS[item]}
              {item !== "all" ? (
                <span className="rounded-full bg-background/70 px-1.5 text-[11px] tabular-nums">
                  {counts[item]}
                </span>
              ) : null}
            </button>
          ),
        )}
      </div>

      <div className="flex flex-col gap-2 rounded-xl border border-border bg-card p-3 sm:flex-row sm:items-center">
        <div className="relative min-w-0 flex-1">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={search}
            onChange={(event) => setSearch(event.target.value)}
            placeholder="Buscar tarefa ou contato"
            className="pl-9"
          />
        </div>
        <label className="inline-flex min-h-9 items-center gap-2 rounded-md border border-border px-3 text-sm text-muted-foreground">
          <input
            type="checkbox"
            checked={onlyMine}
            onChange={(event) => setOnlyMine(event.target.checked)}
            className="accent-primary"
          />
          Somente minhas
        </label>
      </div>

      {loading ? (
        <LoadingState label="Carregando tarefas..." />
      ) : error ? (
        <ErrorState message={error} onRetry={loadTasks} />
      ) : filtered.length === 0 ? (
        <EmptyState
          icon={CalendarClock}
          title="Nenhuma tarefa nesta visão"
          description="Altere o período, retire o filtro de responsável ou crie uma nova tarefa."
          actionLabel="Criar tarefa"
          onAction={() => setCreateOpen(true)}
        />
      ) : (
        <div className="space-y-2">
          {filtered.map((task) => {
            const taskBucket = agendaBucket(task.status, task.due_at);
            return (
              <article
                key={task.id}
                className={cn(
                  "grid gap-3 rounded-xl border bg-card px-4 py-3 md:grid-cols-[minmax(0,1fr)_auto_auto] md:items-center",
                  taskBucket === "overdue" ? "border-destructive/35" : "border-border",
                )}
              >
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <StatusPill status={task.status} />
                    <span className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
                      {task.task_type.replaceAll("_", " ")}
                    </span>
                  </div>
                  <h2 className="mt-1.5 truncate text-sm font-semibold text-foreground">{task.title}</h2>
                  <p className="mt-0.5 truncate text-xs text-muted-foreground">
                    {task.contact?.name || task.contact?.phone || "Contato"}
                    {task.description ? ` · ${task.description}` : ""}
                  </p>
                </div>
                <div
                  className={cn(
                    "text-xs font-medium",
                    taskBucket === "overdue" ? "text-destructive" : "text-muted-foreground",
                  )}
                >
                  {formatDue(task.due_at)}
                </div>
                <div className="flex items-center gap-1.5">
                  {task.status === "open" ? (
                    <Button size="sm" variant="outline" onClick={() => startTask(task)}>
                      <CirclePlay className="h-3.5 w-3.5" />
                      Iniciar
                    </Button>
                  ) : null}
                  {task.status === "open" || task.status === "in_progress" ? (
                    <>
                      <Button size="sm" onClick={() => openAction(task, "complete")}>
                        <CheckCircle2 className="h-3.5 w-3.5" />
                        Concluir
                      </Button>
                      <Button
                        size="icon-sm"
                        variant="ghost"
                        aria-label="Cancelar tarefa"
                        onClick={() => openAction(task, "cancel")}
                      >
                        <XCircle className="h-4 w-4" />
                      </Button>
                    </>
                  ) : null}
                </div>
              </article>
            );
          })}
        </div>
      )}

      <Dialog open={createOpen} onOpenChange={setCreateOpen}>
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>Nova tarefa</DialogTitle>
            <DialogDescription>Registre uma ação futura vinculada a um contato.</DialogDescription>
          </DialogHeader>
          <div className="grid gap-4 py-2 sm:grid-cols-2">
            <div className="space-y-1.5 sm:col-span-2">
              <Label htmlFor="task-contact">Contato *</Label>
              <select
                id="task-contact"
                value={contactId}
                onChange={(event) => setContactId(event.target.value)}
                className="h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
              >
                <option value="">Selecione</option>
                {contacts.map((contact) => (
                  <option key={contact.id} value={contact.id}>
                    {contact.name || contact.phone} · {contact.phone}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-1.5 sm:col-span-2">
              <Label htmlFor="task-title">Título *</Label>
              <Input id="task-title" value={title} onChange={(event) => setTitle(event.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="task-type">Tipo</Label>
              <select
                id="task-type"
                value={taskType}
                onChange={(event) => setTaskType(event.target.value as TaskType)}
                className="h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
              >
                <option value="follow_up">Follow-up</option>
                <option value="call">Ligação</option>
                <option value="whatsapp">WhatsApp</option>
                <option value="email">E-mail</option>
                <option value="meeting">Reunião</option>
                <option value="visit">Visita</option>
                <option value="qualification">Qualificação</option>
                <option value="proposal">Proposta</option>
                <option value="custom">Personalizada</option>
              </select>
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="task-due">Prazo *</Label>
              <Input
                id="task-due"
                type="datetime-local"
                value={dueAt}
                onChange={(event) => setDueAt(event.target.value)}
              />
            </div>
            <div className="space-y-1.5 sm:col-span-2">
              <Label htmlFor="task-description">Descrição</Label>
              <Textarea
                id="task-description"
                value={description}
                onChange={(event) => setDescription(event.target.value)}
                rows={3}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setCreateOpen(false)}>Cancelar</Button>
            <Button disabled={creating || !contactId || !title.trim() || !dueAt} onClick={createTask}>
              {creating ? "Criando..." : "Criar tarefa"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog
        open={Boolean(actionTask && actionType)}
        onOpenChange={(open) => {
          if (!open) {
            setActionTask(null);
            setActionType(null);
            setActionText("");
          }
        }}
      >
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{actionType === "complete" ? "Concluir tarefa" : "Cancelar tarefa"}</DialogTitle>
            <DialogDescription>{actionTask?.title}</DialogDescription>
          </DialogHeader>
          <div className="space-y-1.5 py-2">
            <Label htmlFor="task-action-text">
              {actionType === "complete" ? "Resultado *" : "Motivo *"}
            </Label>
            <Textarea
              id="task-action-text"
              value={actionText}
              onChange={(event) => setActionText(event.target.value)}
              rows={4}
            />
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setActionTask(null)}>Voltar</Button>
            <Button
              variant={actionType === "cancel" ? "destructive" : "default"}
              disabled={acting || !actionText.trim()}
              onClick={submitAction}
            >
              {acting ? "Salvando..." : actionType === "complete" ? "Concluir" : "Cancelar tarefa"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
