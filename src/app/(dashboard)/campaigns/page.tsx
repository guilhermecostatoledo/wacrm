"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { BarChart3, Megaphone, Plus, Search } from "lucide-react";
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
import { formatCurrency } from "@/lib/currency";

interface CampaignRow {
  id: string;
  account_id: string;
  name: string;
  objective: string | null;
  channel: string;
  status: "draft" | "active" | "paused" | "completed" | "archived";
  budget: number;
  currency: string;
  starts_at: string | null;
  ends_at: string | null;
  utm_source: string | null;
  utm_medium: string | null;
  utm_campaign: string | null;
  created_at: string;
}

interface CampaignMetrics {
  touchpoints: number;
  replies: number;
  conversions: number;
  attributedRevenue: number;
}

function formatDate(value: string | null): string {
  if (!value) return "—";
  return new Intl.DateTimeFormat("pt-BR", { dateStyle: "short" }).format(new Date(value));
}

export default function CampaignsPage() {
  const { accountId, profile, defaultCurrency } = useAuth();
  const [campaigns, setCampaigns] = useState<CampaignRow[]>([]);
  const [metrics, setMetrics] = useState<Record<string, CampaignMetrics>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [createOpen, setCreateOpen] = useState(false);
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [objective, setObjective] = useState("");
  const [budget, setBudget] = useState("0");
  const [utmSource, setUtmSource] = useState("");
  const [utmMedium, setUtmMedium] = useState("");
  const [utmCampaign, setUtmCampaign] = useState("");

  const loadCampaigns = useCallback(async () => {
    if (!accountId) return;
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const [campaignResult, touchpointResult, attributionResult] = await Promise.all([
      supabase
        .from("marketing_campaigns")
        .select("*")
        .eq("account_id", accountId)
        .is("archived_at", null)
        .order("created_at", { ascending: false }),
      supabase
        .from("marketing_touchpoints")
        .select("campaign_id,event_type")
        .eq("account_id", accountId),
      supabase
        .from("opportunity_attributions")
        .select("campaign_id,attributed_revenue,model")
        .eq("account_id", accountId)
        .eq("model", "last_touch"),
    ]);

    if (campaignResult.error) {
      setError(campaignResult.error.message);
      setCampaigns([]);
      setLoading(false);
      return;
    }

    const aggregate: Record<string, CampaignMetrics> = {};
    for (const campaign of campaignResult.data ?? []) {
      aggregate[campaign.id] = {
        touchpoints: 0,
        replies: 0,
        conversions: 0,
        attributedRevenue: 0,
      };
    }
    for (const touchpoint of touchpointResult.data ?? []) {
      const row = aggregate[touchpoint.campaign_id];
      if (!row) continue;
      row.touchpoints += 1;
      if (touchpoint.event_type === "reply") row.replies += 1;
      if (touchpoint.event_type === "conversion") row.conversions += 1;
    }
    for (const attribution of attributionResult.data ?? []) {
      const row = aggregate[attribution.campaign_id];
      if (row) row.attributedRevenue += Number(attribution.attributed_revenue || 0);
    }

    setCampaigns((campaignResult.data ?? []) as CampaignRow[]);
    setMetrics(aggregate);
    setLoading(false);
  }, [accountId]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void loadCampaigns();
  }, [loadCampaigns]);

  const filtered = useMemo(() => {
    const term = search.trim().toLowerCase();
    if (!term) return campaigns;
    return campaigns.filter((campaign) =>
      [campaign.name, campaign.objective, campaign.utm_source, campaign.utm_campaign]
        .filter(Boolean)
        .some((value) => String(value).toLowerCase().includes(term)),
    );
  }, [campaigns, search]);

  const totals = useMemo(() => {
    const active = campaigns.filter((campaign) => campaign.status === "active").length;
    const investment = campaigns.reduce((sum, campaign) => sum + Number(campaign.budget || 0), 0);
    const attributedRevenue = Object.values(metrics).reduce(
      (sum, campaign) => sum + campaign.attributedRevenue,
      0,
    );
    const conversions = Object.values(metrics).reduce(
      (sum, campaign) => sum + campaign.conversions,
      0,
    );
    return { active, investment, attributedRevenue, conversions };
  }, [campaigns, metrics]);

  async function createCampaign() {
    if (!accountId || !profile?.user_id || !name.trim()) return;
    const numericBudget = Number(budget || 0);
    if (!Number.isFinite(numericBudget) || numericBudget < 0) {
      toast.error("O orçamento precisa ser um valor válido");
      return;
    }

    setCreating(true);
    const supabase = createClient();
    const { error: insertError } = await supabase.from("marketing_campaigns").insert({
      account_id: accountId,
      name: name.trim(),
      objective: objective.trim() || null,
      channel: "whatsapp",
      status: "draft",
      budget: numericBudget,
      currency: defaultCurrency || "BRL",
      utm_source: utmSource.trim() || null,
      utm_medium: utmMedium.trim() || null,
      utm_campaign: utmCampaign.trim() || null,
      created_by: profile.user_id,
    });

    if (insertError) {
      toast.error(insertError.message || "Não foi possível criar a campanha");
    } else {
      toast.success("Campanha criada em rascunho");
      setCreateOpen(false);
      setName("");
      setObjective("");
      setBudget("0");
      setUtmSource("");
      setUtmMedium("");
      setUtmCampaign("");
      await loadCampaigns();
    }
    setCreating(false);
  }

  return (
    <div className="space-y-5">
      <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.16em] text-primary">Aquisição e receita</p>
          <h1 className="mt-1 text-2xl font-bold tracking-tight text-foreground">Campanhas</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Origem, consentimento, respostas, conversões e receita atribuída no mesmo fluxo.
          </p>
        </div>
        <Button onClick={() => setCreateOpen(true)}>
          <Plus className="h-4 w-4" />
          Nova campanha
        </Button>
      </div>

      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        {[
          ["Campanhas ativas", totals.active.toLocaleString("pt-BR")],
          ["Investimento", formatCurrency(totals.investment, defaultCurrency)],
          ["Conversões", totals.conversions.toLocaleString("pt-BR")],
          ["Receita atribuída", formatCurrency(totals.attributedRevenue, defaultCurrency)],
        ].map(([label, value]) => (
          <div key={label} className="rounded-xl border border-border bg-card px-4 py-3">
            <p className="text-xs text-muted-foreground">{label}</p>
            <p className="mt-1 truncate text-xl font-semibold tabular-nums text-foreground">{value}</p>
          </div>
        ))}
      </div>

      <div className="relative max-w-xl">
        <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
        <Input
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder="Buscar campanha, objetivo ou UTM"
          className="pl-9"
        />
      </div>

      {loading ? (
        <LoadingState label="Carregando campanhas..." />
      ) : error ? (
        <ErrorState message={error} onRetry={loadCampaigns} />
      ) : filtered.length === 0 ? (
        <EmptyState
          icon={Megaphone}
          title={campaigns.length === 0 ? "Nenhuma campanha criada" : "Nenhuma campanha encontrada"}
          description={
            campaigns.length === 0
              ? "Crie uma campanha para conectar aquisição, leads e receita."
              : "Ajuste o termo de busca."
          }
          actionLabel={campaigns.length === 0 ? "Criar primeira campanha" : undefined}
          onAction={campaigns.length === 0 ? () => setCreateOpen(true) : undefined}
        />
      ) : (
        <div className="overflow-hidden rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow className="hover:bg-transparent">
                <TableHead>Campanha</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="hidden md:table-cell">UTM</TableHead>
                <TableHead>Interações</TableHead>
                <TableHead className="hidden lg:table-cell">Conversões</TableHead>
                <TableHead>Receita atribuída</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {filtered.map((campaign) => {
                const row = metrics[campaign.id] ?? {
                  touchpoints: 0,
                  replies: 0,
                  conversions: 0,
                  attributedRevenue: 0,
                };
                return (
                  <TableRow key={campaign.id} className="h-14">
                    <TableCell>
                      <div className="min-w-0">
                        <p className="truncate text-sm font-medium text-foreground">{campaign.name}</p>
                        <p className="truncate text-xs text-muted-foreground">
                          {campaign.objective || campaign.channel} · {formatDate(campaign.starts_at || campaign.created_at)}
                        </p>
                      </div>
                    </TableCell>
                    <TableCell><StatusPill status={campaign.status} /></TableCell>
                    <TableCell className="hidden text-xs text-muted-foreground md:table-cell">
                      {[campaign.utm_source, campaign.utm_medium, campaign.utm_campaign]
                        .filter(Boolean)
                        .join(" / ") || "—"}
                    </TableCell>
                    <TableCell className="text-sm tabular-nums text-muted-foreground">
                      {row.touchpoints} · {row.replies} resp.
                    </TableCell>
                    <TableCell className="hidden text-sm tabular-nums text-muted-foreground lg:table-cell">
                      {row.conversions}
                    </TableCell>
                    <TableCell className="text-sm font-medium tabular-nums text-foreground">
                      {formatCurrency(row.attributedRevenue, campaign.currency || defaultCurrency)}
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      )}

      <div className="rounded-xl border border-border bg-card px-4 py-3">
        <div className="flex items-start gap-3">
          <BarChart3 className="mt-0.5 h-4 w-4 text-primary" />
          <div>
            <p className="text-sm font-medium text-foreground">Atribuição controlada</p>
            <p className="mt-0.5 text-xs leading-5 text-muted-foreground">
              A receita mostrada usa last touch. O banco preserva também first touch para comparação gerencial.
            </p>
          </div>
        </div>
      </div>

      <Dialog open={createOpen} onOpenChange={setCreateOpen}>
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>Nova campanha</DialogTitle>
            <DialogDescription>
              Cadastre o planejamento antes de vincular disparos e touchpoints.
            </DialogDescription>
          </DialogHeader>
          <div className="grid gap-4 py-2 sm:grid-cols-2">
            <div className="space-y-1.5 sm:col-span-2">
              <Label htmlFor="campaign-name">Nome *</Label>
              <Input id="campaign-name" value={name} onChange={(event) => setName(event.target.value)} />
            </div>
            <div className="space-y-1.5 sm:col-span-2">
              <Label htmlFor="campaign-objective">Objetivo</Label>
              <Input
                id="campaign-objective"
                value={objective}
                onChange={(event) => setObjective(event.target.value)}
                placeholder="Ex.: gerar reuniões para o produto X"
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="campaign-budget">Orçamento</Label>
              <Input
                id="campaign-budget"
                type="number"
                min="0"
                step="0.01"
                value={budget}
                onChange={(event) => setBudget(event.target.value)}
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="campaign-utm-source">UTM source</Label>
              <Input id="campaign-utm-source" value={utmSource} onChange={(event) => setUtmSource(event.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="campaign-utm-medium">UTM medium</Label>
              <Input id="campaign-utm-medium" value={utmMedium} onChange={(event) => setUtmMedium(event.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="campaign-utm-campaign">UTM campaign</Label>
              <Input id="campaign-utm-campaign" value={utmCampaign} onChange={(event) => setUtmCampaign(event.target.value)} />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setCreateOpen(false)}>Cancelar</Button>
            <Button disabled={creating || !name.trim()} onClick={createCampaign}>
              {creating ? "Criando..." : "Criar campanha"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
