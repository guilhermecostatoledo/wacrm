'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  AlertTriangle,
  Archive,
  CheckCircle2,
  Clock3,
  Loader2,
  Plus,
  RefreshCw,
  UserRound,
} from 'lucide-react';
import { toast } from 'sonner';

import { Button } from '@/components/ui/button';
import { createClient } from '@/lib/supabase/client';
import { useAuth } from '@/hooks/use-auth';
import type { Contact } from '@/types';
import type { Lead, LeadPriority, LeadStatus } from '@/types/crm';
import {
  getAvailableLeadStatuses,
  isClosedLeadStatus,
  LEAD_PRIORITY_LABELS,
  LEAD_STATUS_LABELS,
} from '@/lib/crm/lifecycle';

interface LeadRow extends Lead {
  contact?: Pick<Contact, 'id' | 'name' | 'phone' | 'email' | 'company'> | null;
  tasks?: Array<{
    id: string;
    status: 'open' | 'completed' | 'cancelled';
    due_at: string;
    title: string;
  }>;
}

const PRIORITIES: LeadPriority[] = ['low', 'medium', 'high', 'urgent'];

function formatDate(value?: string | null) {
  if (!value) return 'Sem próxima ação';
  return new Intl.DateTimeFormat('pt-BR', {
    dateStyle: 'short',
    timeStyle: 'short',
  }).format(new Date(value));
}

function priorityClass(priority: LeadPriority) {
  if (priority === 'urgent') return 'border-red-500/40 bg-red-500/10 text-red-300';
  if (priority === 'high') return 'border-amber-500/40 bg-amber-500/10 text-amber-300';
  if (priority === 'low') return 'border-border bg-muted text-muted-foreground';
  return 'border-primary/30 bg-primary/10 text-primary';
}

export default function LeadsPage() {
  const supabase = createClient();
  const { user, accountId, canSendMessages, profileLoading } = useAuth();

  const [leads, setLeads] = useState<LeadRow[]>([]);
  const [contacts, setContacts] = useState<Contact[]>([]);
  const [loading, setLoading] = useState(true);
  const [creating, setCreating] = useState(false);
  const [selectedContactId, setSelectedContactId] = useState('');
  const [priority, setPriority] = useState<LeadPriority>('medium');
  const [search, setSearch] = useState('');

  const fetchData = useCallback(async () => {
    setLoading(true);

    const [leadsResult, contactsResult] = await Promise.all([
      supabase
        .from('leads')
        .select(
          '*, contact:contacts(id, name, phone, email, company), tasks:crm_tasks(id, status, due_at, title)',
        )
        .order('created_at', { ascending: false }),
      supabase
        .from('contacts')
        .select('id, user_id, account_id, phone, name, email, company, avatar_url, created_at, updated_at')
        .order('name', { ascending: true }),
    ]);

    if (leadsResult.error) {
      toast.error('Não foi possível carregar os leads');
    } else {
      setLeads((leadsResult.data ?? []) as LeadRow[]);
    }

    if (contactsResult.error) {
      toast.error('Não foi possível carregar os contatos');
    } else {
      setContacts((contactsResult.data ?? []) as Contact[]);
    }

    setLoading(false);
  }, [supabase]);

  useEffect(() => {
    if (profileLoading) return;
    void fetchData();
  }, [fetchData, profileLoading]);

  const visibleLeads = useMemo(() => {
    const term = search.trim().toLocaleLowerCase('pt-BR');
    if (!term) return leads;

    return leads.filter((lead) => {
      const haystack = [
        lead.title,
        lead.contact?.name,
        lead.contact?.phone,
        lead.contact?.email,
        lead.contact?.company,
        lead.source,
      ]
        .filter(Boolean)
        .join(' ')
        .toLocaleLowerCase('pt-BR');
      return haystack.includes(term);
    });
  }, [leads, search]);

  const metrics = useMemo(() => {
    const active = leads.filter((lead) => !isClosedLeadStatus(lead.status));
    const now = Date.now();
    return {
      total: leads.length,
      active: active.length,
      withoutNextAction: active.filter((lead) => !lead.next_action_at).length,
      overdue: active.filter(
        (lead) => lead.next_action_at && new Date(lead.next_action_at).getTime() < now,
      ).length,
    };
  }, [leads]);

  async function createLead() {
    if (!selectedContactId || !accountId || !user?.id) {
      toast.error('Selecione um contato');
      return;
    }

    const contact = contacts.find((item) => item.id === selectedContactId);
    if (!contact) return;

    setCreating(true);
    const { error } = await supabase.from('leads').insert({
      account_id: accountId,
      contact_id: contact.id,
      created_by_user_id: user.id,
      assigned_to: user.id,
      title: contact.name?.trim() || contact.phone,
      source: 'manual',
      status: 'new',
      priority,
    });
    setCreating(false);

    if (error) {
      if (error.code === '23505') {
        toast.error('Este contato já possui um lead ativo');
      } else {
        toast.error('Não foi possível criar o lead');
      }
      return;
    }

    toast.success('Lead criado com a primeira tarefa automática');
    setSelectedContactId('');
    setPriority('medium');
    await fetchData();
  }

  async function updateStatus(lead: LeadRow, status: LeadStatus) {
    if (status === lead.status) return;

    let lossReason: string | null | undefined;
    if (status === 'disqualified') {
      lossReason = window.prompt('Informe o motivo da desqualificação:')?.trim();
      if (!lossReason) return;
    }

    const { error } = await supabase
      .from('leads')
      .update({ status, loss_reason: lossReason ?? lead.loss_reason ?? null })
      .eq('id', lead.id);

    if (error) {
      toast.error('Não foi possível alterar o status');
      return;
    }

    toast.success('Status atualizado');
    await fetchData();
  }

  async function archiveLead(lead: LeadRow) {
    const reason = window.prompt('Motivo do arquivamento (opcional):')?.trim() ?? null;
    const { error } = await supabase.rpc('crm_archive_lead', {
      p_lead_id: lead.id,
      p_reason: reason,
    });

    if (error) {
      toast.error('Não foi possível arquivar o lead');
      return;
    }

    toast.success('Lead arquivado e tarefas abertas canceladas');
    await fetchData();
  }

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-foreground">Leads</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Acompanhe a captação, qualificação e próxima ação de cada oportunidade.
          </p>
        </div>
        <Button variant="outline" onClick={() => void fetchData()} disabled={loading}>
          <RefreshCw className="mr-2 size-4" />
          Atualizar
        </Button>
      </div>

      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <MetricCard label="Total" value={metrics.total} icon={UserRound} />
        <MetricCard label="Ativos" value={metrics.active} icon={CheckCircle2} />
        <MetricCard label="Sem próxima ação" value={metrics.withoutNextAction} icon={Clock3} />
        <MetricCard label="Atrasados" value={metrics.overdue} icon={AlertTriangle} />
      </div>

      <section className="rounded-xl border border-border bg-card p-4 shadow-sm">
        <div className="mb-4">
          <h2 className="font-semibold text-foreground">Novo lead</h2>
          <p className="text-sm text-muted-foreground">
            Ao criar, o sistema gera automaticamente a tarefa de primeiro contato.
          </p>
        </div>
        <div className="grid gap-3 md:grid-cols-[minmax(0,1fr)_180px_auto]">
          <select
            value={selectedContactId}
            onChange={(event) => setSelectedContactId(event.target.value)}
            disabled={!canSendMessages}
            className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground outline-none focus:ring-2 focus:ring-ring"
          >
            <option value="">Selecione um contato</option>
            {contacts.map((contact) => (
              <option key={contact.id} value={contact.id}>
                {contact.name?.trim() || contact.phone} — {contact.phone}
              </option>
            ))}
          </select>

          <select
            value={priority}
            onChange={(event) => setPriority(event.target.value as LeadPriority)}
            disabled={!canSendMessages}
            className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground outline-none focus:ring-2 focus:ring-ring"
          >
            {PRIORITIES.map((item) => (
              <option key={item} value={item}>
                {LEAD_PRIORITY_LABELS[item]}
              </option>
            ))}
          </select>

          <Button onClick={() => void createLead()} disabled={!canSendMessages || creating}>
            {creating ? <Loader2 className="mr-2 size-4 animate-spin" /> : <Plus className="mr-2 size-4" />}
            Criar lead
          </Button>
        </div>
        {!canSendMessages ? (
          <p className="mt-3 text-xs text-muted-foreground">
            Seu perfil possui acesso somente para leitura.
          </p>
        ) : null}
      </section>

      <section className="rounded-xl border border-border bg-card shadow-sm">
        <div className="border-b border-border p-4">
          <input
            value={search}
            onChange={(event) => setSearch(event.target.value)}
            placeholder="Buscar por nome, telefone, empresa ou origem"
            className="h-10 w-full rounded-md border border-input bg-background px-3 text-sm text-foreground outline-none placeholder:text-muted-foreground focus:ring-2 focus:ring-ring"
          />
        </div>

        {loading ? (
          <div className="flex min-h-56 items-center justify-center text-muted-foreground">
            <Loader2 className="mr-2 size-5 animate-spin" /> Carregando leads...
          </div>
        ) : visibleLeads.length === 0 ? (
          <div className="flex min-h-56 flex-col items-center justify-center px-6 text-center">
            <UserRound className="mb-3 size-8 text-muted-foreground" />
            <p className="font-medium text-foreground">Nenhum lead encontrado</p>
            <p className="mt-1 max-w-md text-sm text-muted-foreground">
              Cadastre um contato ou aguarde uma nova mensagem recebida pelo WhatsApp.
            </p>
          </div>
        ) : (
          <div className="divide-y divide-border">
            {visibleLeads.map((lead) => {
              const openTasks = lead.tasks?.filter((task) => task.status === 'open') ?? [];
              const overdue =
                lead.next_action_at && new Date(lead.next_action_at).getTime() < Date.now();

              return (
                <article key={lead.id} className="grid gap-4 p-4 xl:grid-cols-[minmax(0,1.4fr)_180px_220px_auto] xl:items-center">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <h3 className="truncate font-semibold text-foreground">{lead.title}</h3>
                      <span className={`rounded-full border px-2 py-0.5 text-xs ${priorityClass(lead.priority)}`}>
                        {LEAD_PRIORITY_LABELS[lead.priority]}
                      </span>
                      <span className="rounded-full border border-border bg-muted px-2 py-0.5 text-xs text-muted-foreground">
                        {lead.source}
                      </span>
                    </div>
                    <p className="mt-1 text-sm text-muted-foreground">
                      {lead.contact?.name || 'Contato sem nome'} · {lead.contact?.phone || 'Sem telefone'}
                    </p>
                    {lead.contact?.company ? (
                      <p className="mt-0.5 text-xs text-muted-foreground">{lead.contact.company}</p>
                    ) : null}
                  </div>

                  <div>
                    <p className="text-xs uppercase tracking-wide text-muted-foreground">Status</p>
                    <select
                      value={lead.status}
                      disabled={!canSendMessages}
                      onChange={(event) => void updateStatus(lead, event.target.value as LeadStatus)}
                      className="mt-1 h-9 w-full rounded-md border border-input bg-background px-2 text-sm text-foreground outline-none focus:ring-2 focus:ring-ring disabled:opacity-60"
                    >
                      {getAvailableLeadStatuses(lead.status).map((status) => (
                        <option key={status} value={status}>
                          {LEAD_STATUS_LABELS[status]}
                        </option>
                      ))}
                    </select>
                  </div>

                  <div>
                    <p className="text-xs uppercase tracking-wide text-muted-foreground">Próxima ação</p>
                    <p className={`mt-1 text-sm font-medium ${overdue ? 'text-red-300' : 'text-foreground'}`}>
                      {formatDate(lead.next_action_at)}
                    </p>
                    <p className="mt-0.5 text-xs text-muted-foreground">
                      {openTasks.length} tarefa{openTasks.length === 1 ? '' : 's'} aberta{openTasks.length === 1 ? '' : 's'}
                    </p>
                  </div>

                  <div className="flex justify-end">
                    <Button
                      variant="ghost"
                      size="sm"
                      disabled={!canSendMessages || lead.status === 'archived'}
                      onClick={() => void archiveLead(lead)}
                    >
                      <Archive className="mr-2 size-4" />
                      Arquivar
                    </Button>
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

function MetricCard({
  label,
  value,
  icon: Icon,
}: {
  label: string;
  value: number;
  icon: typeof UserRound;
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
