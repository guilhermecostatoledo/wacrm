"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { AlertTriangle, CheckCircle2, ChevronDown, RefreshCw, Search, ShieldCheck } from "lucide-react";
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
import { createClient } from "@/lib/supabase/client";
import { useAuth } from "@/hooks/use-auth";
import { cn } from "@/lib/utils";

interface AuditItem {
  occurred_at: string;
  id: string;
  record_type: "domain_event" | "integration_dead_letter";
  event_type: string;
  aggregate_type: string;
  aggregate_id: string;
  actor_user_id: string | null;
  actor_name: string | null;
  source: string;
  payload: Record<string, unknown>;
  severity: string | null;
  error_message: string | null;
  resolved_at: string | null;
}

interface AuditFeed {
  data: AuditItem[];
  next_before: string | null;
}

function formatDate(value: string): string {
  return new Intl.DateTimeFormat("pt-BR", {
    dateStyle: "short",
    timeStyle: "medium",
  }).format(new Date(value));
}

function describeEvent(item: AuditItem): string {
  if (item.record_type === "integration_dead_letter") {
    return item.error_message || "Falha de integração sem mensagem detalhada";
  }
  const payload = item.payload ?? {};
  const next = payload.new as Record<string, unknown> | undefined;
  const title = next?.title ?? next?.name ?? next?.summary;
  return title ? String(title) : `${item.aggregate_type} · ${item.aggregate_id.slice(0, 8)}…`;
}

export default function AuditPage() {
  const { accountId } = useAuth();
  const [items, setItems] = useState<AuditItem[]>([]);
  const [nextBefore, setNextBefore] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [aggregateType, setAggregateType] = useState("");
  const [onlyFailures, setOnlyFailures] = useState(false);
  const [resolveItem, setResolveItem] = useState<AuditItem | null>(null);
  const [resolutionNotes, setResolutionNotes] = useState("");
  const [resolving, setResolving] = useState(false);

  const loadFeed = useCallback(
    async (options?: { append?: boolean; before?: string | null }) => {
      if (!accountId) return;
      const append = options?.append === true;
      append ? setLoadingMore(true) : setLoading(true);
      setError(null);
      const supabase = createClient();
      const { data, error: rpcError } = await supabase.rpc("crm_audit_feed", {
        p_account_id: accountId,
        p_limit: 100,
        p_before: options?.before ?? null,
        p_event_type: onlyFailures ? "whatsapp.dead_letter" : null,
        p_aggregate_type: aggregateType || null,
        p_actor_user_id: null,
      });

      if (rpcError) {
        setError(rpcError.message);
      } else {
        const feed = data as AuditFeed;
        setItems((previous) => (append ? [...previous, ...(feed.data ?? [])] : feed.data ?? []));
        setNextBefore(feed.next_before ?? null);
      }
      setLoading(false);
      setLoadingMore(false);
    },
    [accountId, aggregateType, onlyFailures],
  );

  useEffect(() => {
    void loadFeed();
  }, [loadFeed]);

  const filtered = useMemo(() => {
    const term = search.trim().toLowerCase();
    if (!term) return items;
    return items.filter((item) =>
      [
        item.event_type,
        item.aggregate_type,
        item.actor_name,
        item.error_message,
        item.aggregate_id,
        describeEvent(item),
      ]
        .filter(Boolean)
        .some((value) => String(value).toLowerCase().includes(term)),
    );
  }, [items, search]);

  const counts = useMemo(
    () => ({
      events: items.filter((item) => item.record_type === "domain_event").length,
      openFailures: items.filter(
        (item) => item.record_type === "integration_dead_letter" && !item.resolved_at,
      ).length,
      resolvedFailures: items.filter(
        (item) => item.record_type === "integration_dead_letter" && item.resolved_at,
      ).length,
    }),
    [items],
  );

  async function resolveDeadLetter() {
    if (!resolveItem || !resolutionNotes.trim()) return;
    setResolving(true);
    const supabase = createClient();
    const { error: rpcError } = await supabase.rpc("resolve_integration_dead_letter", {
      p_dead_letter_id: resolveItem.id,
      p_notes: resolutionNotes.trim(),
    });
    if (rpcError) {
      toast.error(rpcError.message || "Não foi possível resolver a falha");
    } else {
      toast.success("Dead letter marcada como resolvida");
      setResolveItem(null);
      setResolutionNotes("");
      await loadFeed();
    }
    setResolving(false);
  }

  return (
    <div className="space-y-5">
      <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.16em] text-primary">Governança e rastreabilidade</p>
          <h1 className="mt-1 text-2xl font-bold tracking-tight text-foreground">Auditoria</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Alterações de domínio e falhas de integração em uma linha do tempo imutável.
          </p>
        </div>
        <Button variant="outline" onClick={() => loadFeed()}>
          <RefreshCw className="h-4 w-4" />
          Atualizar
        </Button>
      </div>

      <div className="grid gap-3 sm:grid-cols-3">
        {[
          ["Eventos carregados", counts.events],
          ["Falhas abertas", counts.openFailures],
          ["Falhas resolvidas", counts.resolvedFailures],
        ].map(([label, value]) => (
          <div key={String(label)} className="rounded-xl border border-border bg-card px-4 py-3">
            <p className="text-xs text-muted-foreground">{label}</p>
            <p className="mt-1 text-xl font-semibold tabular-nums text-foreground">{value}</p>
          </div>
        ))}
      </div>

      <div className="grid gap-2 rounded-xl border border-border bg-card p-3 md:grid-cols-[minmax(0,1fr)_220px_auto] md:items-center">
        <div className="relative min-w-0">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={search}
            onChange={(event) => setSearch(event.target.value)}
            placeholder="Buscar evento, ator, entidade ou erro"
            className="pl-9"
          />
        </div>
        <select
          value={aggregateType}
          onChange={(event) => setAggregateType(event.target.value)}
          className="h-9 rounded-md border border-input bg-background px-3 text-sm text-foreground"
        >
          <option value="">Todas as entidades</option>
          <option value="contact">Contatos</option>
          <option value="lead">Leads</option>
          <option value="task">Tarefas</option>
          <option value="opportunity">Oportunidades</option>
          <option value="activity">Atividades</option>
          <option value="integration_dead_letter">Integrações</option>
        </select>
        <label className="inline-flex min-h-9 items-center gap-2 rounded-md border border-border px-3 text-sm text-muted-foreground">
          <input
            type="checkbox"
            checked={onlyFailures}
            onChange={(event) => setOnlyFailures(event.target.checked)}
            className="accent-primary"
          />
          Somente falhas
        </label>
      </div>

      {loading ? (
        <LoadingState label="Carregando auditoria..." />
      ) : error ? (
        <ErrorState message={error} onRetry={() => loadFeed()} />
      ) : filtered.length === 0 ? (
        <EmptyState
          icon={ShieldCheck}
          title="Nenhum registro encontrado"
          description="Ajuste os filtros ou aguarde novas alterações de domínio."
        />
      ) : (
        <div className="space-y-2">
          {filtered.map((item) => {
            const failure = item.record_type === "integration_dead_letter";
            const openFailure = failure && !item.resolved_at;
            return (
              <article
                key={`${item.record_type}-${item.id}-${item.occurred_at}`}
                className={cn(
                  "grid gap-3 rounded-xl border bg-card px-4 py-3 lg:grid-cols-[180px_minmax(0,1fr)_180px_auto] lg:items-center",
                  openFailure ? "border-destructive/35" : "border-border",
                )}
              >
                <div className="text-xs tabular-nums text-muted-foreground">
                  {formatDate(item.occurred_at)}
                </div>
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    {failure ? (
                      openFailure ? (
                        <AlertTriangle className="h-4 w-4 text-destructive" />
                      ) : (
                        <CheckCircle2 className="h-4 w-4 text-emerald-500" />
                      )
                    ) : (
                      <ShieldCheck className="h-4 w-4 text-primary" />
                    )}
                    <span className="truncate text-sm font-semibold text-foreground">
                      {item.event_type}
                    </span>
                    <span className="rounded-full bg-muted px-2 py-0.5 text-[10px] font-medium text-muted-foreground">
                      {item.aggregate_type}
                    </span>
                  </div>
                  <p className="mt-1 truncate text-xs text-muted-foreground">{describeEvent(item)}</p>
                </div>
                <div className="text-xs text-muted-foreground">
                  <p className="truncate">{item.actor_name || item.source || "Sistema"}</p>
                  <p className="mt-0.5 font-mono text-[10px]">{item.aggregate_id.slice(0, 12)}…</p>
                </div>
                <div className="flex justify-end">
                  {openFailure ? (
                    <Button size="sm" variant="outline" onClick={() => setResolveItem(item)}>
                      Resolver
                    </Button>
                  ) : null}
                </div>
              </article>
            );
          })}

          {nextBefore ? (
            <div className="flex justify-center pt-2">
              <Button
                variant="outline"
                disabled={loadingMore}
                onClick={() => loadFeed({ append: true, before: nextBefore })}
              >
                <ChevronDown className="h-4 w-4" />
                {loadingMore ? "Carregando..." : "Carregar mais"}
              </Button>
            </div>
          ) : null}
        </div>
      )}

      <Dialog
        open={Boolean(resolveItem)}
        onOpenChange={(open) => {
          if (!open) {
            setResolveItem(null);
            setResolutionNotes("");
          }
        }}
      >
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>Resolver falha de integração</DialogTitle>
            <DialogDescription>
              A resolução não apaga o registro. Ela adiciona responsável, data e justificativa ao histórico.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3 py-2">
            <div className="rounded-lg border border-destructive/25 bg-destructive/5 p-3 text-xs text-muted-foreground">
              {resolveItem?.error_message}
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="resolution-notes">Ação executada e evidência *</Label>
              <Textarea
                id="resolution-notes"
                value={resolutionNotes}
                onChange={(event) => setResolutionNotes(event.target.value)}
                rows={5}
                placeholder="Descreva a causa, a correção e como foi validada."
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setResolveItem(null)}>Cancelar</Button>
            <Button disabled={resolving || !resolutionNotes.trim()} onClick={resolveDeadLetter}>
              {resolving ? "Salvando..." : "Marcar como resolvida"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
