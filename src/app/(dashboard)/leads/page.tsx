"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { Clock3, Filter, Plus, Search, UserRoundSearch } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { EmptyState, ErrorState, LoadingState } from "@/components/crm/page-state";
import { StatusPill } from "@/components/crm/status-pill";
import { createClient } from "@/lib/supabase/client";
import { useAuth } from "@/hooks/use-auth";
import type { Lead, LeadStatus } from "@/lib/crm/domain";

interface LeadRow extends Lead {
  contact: {
    id: string;
    name: string | null;
    phone: string;
    email: string | null;
    company: string | null;
  } | null;
  source: { id: string; code: string; name: string } | null;
}

const ACTIVE_STATUSES: LeadStatus[] = [
  "new",
  "assigned",
  "attempting_contact",
  "connected",
  "qualifying",
  "qualified",
  "nurturing",
  "reopened",
];

function formatDate(value: string | null): string {
  if (!value) return "—";
  return new Intl.DateTimeFormat("pt-BR", {
    dateStyle: "short",
    timeStyle: "short",
  }).format(new Date(value));
}

function remainingSla(value: string | null): { label: string; overdue: boolean } {
  if (!value) return { label: "Sem SLA", overdue: false };
  const minutes = Math.round((new Date(value).getTime() - Date.now()) / 60_000);
  if (minutes < 0) return { label: `${Math.abs(minutes)} min atrasado`, overdue: true };
  if (minutes < 60) return { label: `${minutes} min`, overdue: false };
  return { label: `${Math.floor(minutes / 60)}h ${minutes % 60}min`, overdue: false };
}

export default function LeadsPage() {
  const { accountId, profile } = useAuth();
  const [leads, setLeads] = useState<LeadRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState<string>("active");
  const [createOpen, setCreateOpen] = useState(false);
  const [creating, setCreating] = useState(false);
  const [phone, setPhone] = useState("");
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [company, setCompany] = useState("");
  const [sourceCode, setSourceCode] = useState("manual");

  const loadLeads = useCallback(async () => {
    if (!accountId) return;
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const { data, error: queryError } = await supabase
      .from("leads")
      .select(
        "*, contact:contacts(id,name,phone,email,company), source:lead_sources(id,code,name)",
      )
      .eq("account_id", accountId)
      .is("archived_at", null)
      .order("created_at", { ascending: false })
      .limit(500);

    if (queryError) {
      setError(queryError.message);
      setLeads([]);
    } else {
      setLeads((data ?? []) as unknown as LeadRow[]);
    }
    setLoading(false);
  }, [accountId]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void loadLeads();
  }, [loadLeads]);

  const filtered = useMemo(() => {
    const term = search.trim().toLowerCase();
    return leads.filter((lead) => {
      const matchesStatus =
        status === "all"
          ? true
          : status === "active"
            ? ACTIVE_STATUSES.includes(lead.status)
            : lead.status === status;
      if (!matchesStatus) return false;
      if (!term) return true;
      const contact = lead.contact;
      return [contact?.name, contact?.phone, contact?.email, contact?.company, lead.queue_key]
        .filter(Boolean)
        .some((value) => String(value).toLowerCase().includes(term));
    });
  }, [leads, search, status]);

  const metrics = useMemo(() => {
    const active = leads.filter((lead) => ACTIVE_STATUSES.includes(lead.status));
    return {
      active: active.length,
      unassigned: active.filter((lead) => !lead.owner_id).length,
      overdue: active.filter(
        (lead) => lead.first_response_due_at && new Date(lead.first_response_due_at).getTime() < Date.now(),
      ).length,
      qualified: leads.filter((lead) => lead.status === "qualified").length,
    };
  }, [leads]);

  async function createLead() {
    if (!accountId || !profile?.user_id || !phone.trim()) return;
    setCreating(true);
    const supabase = createClient();
    const { error: rpcError } = await supabase.rpc("intake_lead", {
      p_account_id: accountId,
      p_phone: phone.trim(),
      p_name: name.trim() || null,
      p_email: email.trim() || null,
      p_company: company.trim() || null,
      p_source_code: sourceCode.trim() || "manual",
      p_external_key: null,
      p_requested_owner_id: null,
      p_source_detail: { captured_from: "crm_ui" },
      p_first_response_minutes: 60,
      p_create_first_task: true,
      p_reopen_disqualified: false,
      p_created_by: profile.user_id,
    });

    if (rpcError) {
      toast.error(rpcError.message || "Não foi possível criar o lead");
    } else {
      toast.success("Lead capturado e distribuído");
      setCreateOpen(false);
      setPhone("");
      setName("");
      setEmail("");
      setCompany("");
      setSourceCode("manual");
      await loadLeads();
    }
    setCreating(false);
  }

  return (
    <div className="space-y-5">
      <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.16em] text-primary">Operação comercial</p>
          <h1 className="mt-1 text-2xl font-bold tracking-tight text-foreground">Leads</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Entrada, SLA, responsável e avanço de qualificação em uma única fila.
          </p>
        </div>
        <Button onClick={() => setCreateOpen(true)}>
          <Plus className="h-4 w-4" />
          Novo lead
        </Button>
      </div>

      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        {[
          ["Ativos", metrics.active],
          ["Sem responsável", metrics.unassigned],
          ["SLA vencido", metrics.overdue],
          ["Qualificados", metrics.qualified],
        ].map(([label, value]) => (
          <div key={String(label)} className="rounded-xl border border-border bg-card px-4 py-3">
            <p className="text-xs text-muted-foreground">{label}</p>
            <p className="mt-1 text-xl font-semibold tabular-nums text-foreground">{value}</p>
          </div>
        ))}
      </div>

      <div className="flex flex-col gap-2 rounded-xl border border-border bg-card p-3 sm:flex-row sm:items-center">
        <div className="relative min-w-0 flex-1">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={search}
            onChange={(event) => setSearch(event.target.value)}
            placeholder="Buscar por nome, telefone, e-mail ou empresa"
            className="pl-9"
          />
        </div>
        <div className="flex items-center gap-2">
          <Filter className="h-4 w-4 text-muted-foreground" />
          <select
            value={status}
            onChange={(event) => setStatus(event.target.value)}
            className="h-9 rounded-md border border-input bg-background px-3 text-sm text-foreground"
          >
            <option value="active">Ativos</option>
            <option value="all">Todos</option>
            <option value="new">Novos</option>
            <option value="assigned">Atribuídos</option>
            <option value="attempting_contact">Tentando contato</option>
            <option value="qualifying">Qualificando</option>
            <option value="qualified">Qualificados</option>
            <option value="nurturing">Nutrição</option>
            <option value="converted">Convertidos</option>
            <option value="disqualified">Desqualificados</option>
          </select>
        </div>
      </div>

      {loading ? (
        <LoadingState label="Carregando leads..." />
      ) : error ? (
        <ErrorState message={error} onRetry={loadLeads} />
      ) : filtered.length === 0 ? (
        <EmptyState
          icon={UserRoundSearch}
          title={leads.length === 0 ? "Nenhum lead capturado" : "Nenhum lead encontrado"}
          description={
            leads.length === 0
              ? "Cadastre o primeiro lead. O sistema criará SLA e tarefa inicial automaticamente."
              : "Ajuste a busca ou o filtro de status."
          }
          actionLabel={leads.length === 0 ? "Criar primeiro lead" : undefined}
          onAction={leads.length === 0 ? () => setCreateOpen(true) : undefined}
        />
      ) : (
        <div className="overflow-hidden rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow className="hover:bg-transparent">
                <TableHead>Contato</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="hidden md:table-cell">Origem</TableHead>
                <TableHead className="hidden lg:table-cell">Responsável</TableHead>
                <TableHead>SLA inicial</TableHead>
                <TableHead className="hidden xl:table-cell">Entrada</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {filtered.map((lead) => {
                const sla = remainingSla(lead.first_response_due_at);
                return (
                  <TableRow key={lead.id} className="h-14">
                    <TableCell>
                      <div className="min-w-0">
                        <p className="truncate text-sm font-medium text-foreground">
                          {lead.contact?.name || "Contato sem nome"}
                        </p>
                        <p className="truncate text-xs text-muted-foreground">
                          {lead.contact?.phone || "—"}
                          {lead.contact?.company ? ` · ${lead.contact.company}` : ""}
                        </p>
                      </div>
                    </TableCell>
                    <TableCell><StatusPill status={lead.status} /></TableCell>
                    <TableCell className="hidden text-sm text-muted-foreground md:table-cell">
                      {lead.source?.name || "—"}
                    </TableCell>
                    <TableCell className="hidden text-sm text-muted-foreground lg:table-cell">
                      {lead.owner_id ? `${lead.owner_id.slice(0, 8)}…` : lead.queue_key || "Fila"}
                    </TableCell>
                    <TableCell>
                      <span
                        className={
                          sla.overdue
                            ? "inline-flex items-center gap-1 text-xs font-medium text-destructive"
                            : "inline-flex items-center gap-1 text-xs text-muted-foreground"
                        }
                      >
                        <Clock3 className="h-3.5 w-3.5" />
                        {sla.label}
                      </span>
                    </TableCell>
                    <TableCell className="hidden text-xs text-muted-foreground xl:table-cell">
                      {formatDate(lead.created_at)}
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      )}

      <Dialog open={createOpen} onOpenChange={setCreateOpen}>
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>Novo lead</DialogTitle>
            <DialogDescription>
              O contato será deduplicado e o lead receberá responsável, SLA e tarefa inicial.
            </DialogDescription>
          </DialogHeader>
          <div className="grid gap-4 py-2 sm:grid-cols-2">
            <div className="space-y-1.5 sm:col-span-2">
              <Label htmlFor="lead-phone">Telefone *</Label>
              <Input id="lead-phone" value={phone} onChange={(event) => setPhone(event.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="lead-name">Nome</Label>
              <Input id="lead-name" value={name} onChange={(event) => setName(event.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="lead-company">Empresa</Label>
              <Input id="lead-company" value={company} onChange={(event) => setCompany(event.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="lead-email">E-mail</Label>
              <Input id="lead-email" type="email" value={email} onChange={(event) => setEmail(event.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="lead-source">Código da origem</Label>
              <Input id="lead-source" value={sourceCode} onChange={(event) => setSourceCode(event.target.value)} />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setCreateOpen(false)}>Cancelar</Button>
            <Button disabled={creating || !phone.trim()} onClick={createLead}>
              {creating ? "Criando..." : "Criar lead"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
