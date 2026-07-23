"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { AlertTriangle, ArrowUpRight, CheckCircle2, Clock3, RefreshCw, TrendingUp } from "lucide-react";
import { Button } from "@/components/ui/button";
import { EmptyState, ErrorState, LoadingState } from "@/components/crm/page-state";
import { createClient } from "@/lib/supabase/client";
import { useAuth } from "@/hooks/use-auth";
import { formatCurrency } from "@/lib/currency";

interface ReportData {
  period: { from: string; to: string };
  generated_at: string;
  leads: {
    captured: number;
    contacted: number;
    qualified: number;
    converted: number;
    disqualified: number;
    sla_breaches: number;
    avg_first_response_minutes: number;
    qualification_rate: number;
    conversion_rate: number;
  };
  tasks: {
    active: number;
    overdue: number;
    completed: number;
    cancelled: number;
    avg_completion_hours: number;
  };
  opportunities: {
    open_count: number;
    open_value: number;
    weighted_value: number;
    won_count: number;
    won_value: number;
    lost_count: number;
    lost_value: number;
    win_rate: number;
  };
  marketing: {
    investment: number;
    attributed_revenue: number;
    roi_percent: number;
    touchpoints: number;
    replies: number;
  };
  whatsapp: {
    processed: number;
    failed: number;
    dead_letter_receipts: number;
    open_dead_letters: number;
  };
  daily: Array<{ day: string; leads: number; qualified: number; won_revenue: number }>;
  pipeline: Array<{
    stage_id: string;
    stage_name: string;
    stage_kind: string;
    opportunities: number;
    value: number;
    weighted_value: number;
  }>;
  owners: Array<{
    user_id: string;
    name: string;
    leads_created: number;
    qualified: number;
    tasks_completed: number;
    won_count: number;
    won_revenue: number;
  }>;
}

const RANGE_OPTIONS = [7, 30, 90] as const;

function number(value: number): string {
  return Number(value || 0).toLocaleString("pt-BR");
}

function percent(value: number): string {
  return `${Number(value || 0).toLocaleString("pt-BR", {
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  })}%`;
}

function ProgressBar({ value, max }: { value: number; max: number }) {
  const width = max <= 0 ? 0 : Math.max(2, Math.min(100, (value / max) * 100));
  return (
    <div className="h-1.5 overflow-hidden rounded-full bg-muted">
      <div className="h-full rounded-full bg-primary" style={{ width: `${width}%` }} />
    </div>
  );
}

export default function ReportsPage() {
  const { accountId, defaultCurrency } = useAuth();
  const [rangeDays, setRangeDays] = useState<(typeof RANGE_OPTIONS)[number]>(30);
  const [report, setReport] = useState<ReportData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const loadReport = useCallback(async () => {
    if (!accountId) return;
    setLoading(true);
    setError(null);
    const to = new Date();
    const from = new Date(to);
    from.setDate(from.getDate() - rangeDays);

    const supabase = createClient();
    const { data, error: rpcError } = await supabase.rpc("crm_management_report", {
      p_account_id: accountId,
      p_from: from.toISOString(),
      p_to: to.toISOString(),
    });

    if (rpcError) {
      setError(rpcError.message);
      setReport(null);
    } else {
      setReport(data as ReportData);
    }
    setLoading(false);
  }, [accountId, rangeDays]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void loadReport();
  }, [loadReport]);

  const dailyMax = useMemo(
    () => Math.max(1, ...(report?.daily ?? []).map((day) => Number(day.leads || 0))),
    [report?.daily],
  );
  const pipelineMax = useMemo(
    () => Math.max(1, ...(report?.pipeline ?? []).map((stage) => Number(stage.value || 0))),
    [report?.pipeline],
  );

  return (
    <div className="space-y-5">
      <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.16em] text-primary">Gestão e previsão</p>
          <h1 className="mt-1 text-2xl font-bold tracking-tight text-foreground">Relatórios</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Funil, produtividade, previsão, marketing e saúde operacional calculados no servidor.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <div className="flex rounded-lg border border-border bg-card p-1">
            {RANGE_OPTIONS.map((days) => (
              <button
                key={days}
                type="button"
                onClick={() => setRangeDays(days)}
                className={
                  rangeDays === days
                    ? "rounded-md bg-primary px-3 py-1.5 text-xs font-medium text-primary-foreground"
                    : "rounded-md px-3 py-1.5 text-xs font-medium text-muted-foreground hover:text-foreground"
                }
              >
                {days} dias
              </button>
            ))}
          </div>
          <Button variant="outline" size="icon" onClick={loadReport} aria-label="Atualizar relatório">
            <RefreshCw className="h-4 w-4" />
          </Button>
        </div>
      </div>

      {loading ? (
        <LoadingState label="Calculando indicadores..." />
      ) : error ? (
        <ErrorState message={error} onRetry={loadReport} />
      ) : !report ? (
        <EmptyState
          icon={TrendingUp}
          title="Relatório indisponível"
          description="O período não retornou dados gerenciais."
        />
      ) : (
        <>
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            {[
              {
                label: "Leads capturados",
                value: number(report.leads.captured),
                detail: `${percent(report.leads.qualification_rate)} qualificados`,
                icon: ArrowUpRight,
              },
              {
                label: "Receita ganha",
                value: formatCurrency(report.opportunities.won_value, defaultCurrency),
                detail: `${percent(report.opportunities.win_rate)} win rate`,
                icon: CheckCircle2,
              },
              {
                label: "Forecast ponderado",
                value: formatCurrency(report.opportunities.weighted_value, defaultCurrency),
                detail: `${number(report.opportunities.open_count)} oportunidades`,
                icon: TrendingUp,
              },
              {
                label: "Tarefas atrasadas",
                value: number(report.tasks.overdue),
                detail: `${number(report.tasks.active)} em aberto`,
                icon: Clock3,
              },
            ].map((metric) => {
              const Icon = metric.icon;
              return (
                <div key={metric.label} className="rounded-xl border border-border bg-card px-4 py-3">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p className="text-xs text-muted-foreground">{metric.label}</p>
                      <p className="mt-1 truncate text-xl font-semibold tabular-nums text-foreground">
                        {metric.value}
                      </p>
                      <p className="mt-1 text-xs text-muted-foreground">{metric.detail}</p>
                    </div>
                    <Icon className="h-4 w-4 shrink-0 text-primary" />
                  </div>
                </div>
              );
            })}
          </div>

          <div className="grid gap-4 xl:grid-cols-[1.1fr_0.9fr]">
            <section className="rounded-xl border border-border bg-card p-4">
              <div className="flex items-center justify-between gap-3">
                <div>
                  <h2 className="text-sm font-semibold text-foreground">Entrada diária de leads</h2>
                  <p className="mt-0.5 text-xs text-muted-foreground">Captura e qualificação no período</p>
                </div>
                <span className="text-xs text-muted-foreground">
                  Resp. média: {number(report.leads.avg_first_response_minutes)} min
                </span>
              </div>
              <div className="mt-4 flex h-44 items-end gap-1 overflow-hidden">
                {report.daily.map((day) => {
                  const height = Math.max(4, (Number(day.leads || 0) / dailyMax) * 100);
                  return (
                    <div key={day.day} className="group flex min-w-0 flex-1 flex-col items-center justify-end gap-1">
                      <div
                        className="w-full rounded-t bg-primary/70 transition-colors group-hover:bg-primary"
                        style={{ height: `${height}%` }}
                        title={`${day.day}: ${day.leads} leads, ${day.qualified} qualificados`}
                      />
                    </div>
                  );
                })}
              </div>
              <div className="mt-3 grid grid-cols-3 gap-3 border-t border-border pt-3 text-xs">
                <div>
                  <p className="text-muted-foreground">Contatados</p>
                  <p className="mt-0.5 font-semibold text-foreground">{number(report.leads.contacted)}</p>
                </div>
                <div>
                  <p className="text-muted-foreground">Convertidos</p>
                  <p className="mt-0.5 font-semibold text-foreground">{number(report.leads.converted)}</p>
                </div>
                <div>
                  <p className="text-muted-foreground">SLA violado</p>
                  <p className="mt-0.5 font-semibold text-destructive">{number(report.leads.sla_breaches)}</p>
                </div>
              </div>
            </section>

            <section className="rounded-xl border border-border bg-card p-4">
              <div>
                <h2 className="text-sm font-semibold text-foreground">Pipeline aberto</h2>
                <p className="mt-0.5 text-xs text-muted-foreground">
                  {formatCurrency(report.opportunities.open_value, defaultCurrency)} em valor nominal
                </p>
              </div>
              <div className="mt-4 space-y-3">
                {report.pipeline.length === 0 ? (
                  <p className="py-8 text-center text-sm text-muted-foreground">Sem oportunidades abertas.</p>
                ) : (
                  report.pipeline.map((stage) => (
                    <div key={stage.stage_id} className="space-y-1.5">
                      <div className="flex items-center justify-between gap-3 text-xs">
                        <span className="truncate font-medium text-foreground">{stage.stage_name}</span>
                        <span className="shrink-0 tabular-nums text-muted-foreground">
                          {stage.opportunities} · {formatCurrency(stage.value, defaultCurrency)}
                        </span>
                      </div>
                      <ProgressBar value={Number(stage.value || 0)} max={pipelineMax} />
                    </div>
                  ))
                )}
              </div>
            </section>
          </div>

          <div className="grid gap-4 xl:grid-cols-3">
            <section className="rounded-xl border border-border bg-card p-4">
              <h2 className="text-sm font-semibold text-foreground">Marketing</h2>
              <dl className="mt-3 space-y-2 text-sm">
                <div className="flex justify-between gap-3"><dt className="text-muted-foreground">Investimento</dt><dd className="font-medium text-foreground">{formatCurrency(report.marketing.investment, defaultCurrency)}</dd></div>
                <div className="flex justify-between gap-3"><dt className="text-muted-foreground">Receita atribuída</dt><dd className="font-medium text-foreground">{formatCurrency(report.marketing.attributed_revenue, defaultCurrency)}</dd></div>
                <div className="flex justify-between gap-3"><dt className="text-muted-foreground">ROI</dt><dd className="font-medium text-foreground">{percent(report.marketing.roi_percent)}</dd></div>
                <div className="flex justify-between gap-3"><dt className="text-muted-foreground">Interações / respostas</dt><dd className="font-medium text-foreground">{number(report.marketing.touchpoints)} / {number(report.marketing.replies)}</dd></div>
              </dl>
            </section>

            <section className="rounded-xl border border-border bg-card p-4">
              <h2 className="text-sm font-semibold text-foreground">Execução de tarefas</h2>
              <dl className="mt-3 space-y-2 text-sm">
                <div className="flex justify-between gap-3"><dt className="text-muted-foreground">Concluídas</dt><dd className="font-medium text-foreground">{number(report.tasks.completed)}</dd></div>
                <div className="flex justify-between gap-3"><dt className="text-muted-foreground">Canceladas</dt><dd className="font-medium text-foreground">{number(report.tasks.cancelled)}</dd></div>
                <div className="flex justify-between gap-3"><dt className="text-muted-foreground">Tempo médio</dt><dd className="font-medium text-foreground">{number(report.tasks.avg_completion_hours)} h</dd></div>
              </dl>
            </section>

            <section className="rounded-xl border border-border bg-card p-4">
              <div className="flex items-center gap-2">
                <h2 className="text-sm font-semibold text-foreground">WhatsApp</h2>
                {report.whatsapp.open_dead_letters > 0 ? (
                  <AlertTriangle className="h-4 w-4 text-destructive" />
                ) : (
                  <CheckCircle2 className="h-4 w-4 text-emerald-500" />
                )}
              </div>
              <dl className="mt-3 space-y-2 text-sm">
                <div className="flex justify-between gap-3"><dt className="text-muted-foreground">Eventos processados</dt><dd className="font-medium text-foreground">{number(report.whatsapp.processed)}</dd></div>
                <div className="flex justify-between gap-3"><dt className="text-muted-foreground">Falhas no período</dt><dd className="font-medium text-foreground">{number(report.whatsapp.failed)}</dd></div>
                <div className="flex justify-between gap-3"><dt className="text-muted-foreground">Dead letters abertas</dt><dd className={report.whatsapp.open_dead_letters > 0 ? "font-medium text-destructive" : "font-medium text-foreground"}>{number(report.whatsapp.open_dead_letters)}</dd></div>
              </dl>
            </section>
          </div>

          <section className="overflow-hidden rounded-xl border border-border bg-card">
            <div className="border-b border-border px-4 py-3">
              <h2 className="text-sm font-semibold text-foreground">Desempenho por responsável</h2>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full min-w-[720px] text-sm">
                <thead className="bg-muted/40 text-left text-xs text-muted-foreground">
                  <tr>
                    <th className="px-4 py-2 font-medium">Responsável</th>
                    <th className="px-4 py-2 text-right font-medium">Leads</th>
                    <th className="px-4 py-2 text-right font-medium">Qualificados</th>
                    <th className="px-4 py-2 text-right font-medium">Tarefas</th>
                    <th className="px-4 py-2 text-right font-medium">Ganhos</th>
                    <th className="px-4 py-2 text-right font-medium">Receita</th>
                  </tr>
                </thead>
                <tbody>
                  {report.owners.map((owner) => (
                    <tr key={owner.user_id} className="border-t border-border first:border-t-0">
                      <td className="px-4 py-2.5 font-medium text-foreground">{owner.name || owner.user_id.slice(0, 8)}</td>
                      <td className="px-4 py-2.5 text-right tabular-nums text-muted-foreground">{number(owner.leads_created)}</td>
                      <td className="px-4 py-2.5 text-right tabular-nums text-muted-foreground">{number(owner.qualified)}</td>
                      <td className="px-4 py-2.5 text-right tabular-nums text-muted-foreground">{number(owner.tasks_completed)}</td>
                      <td className="px-4 py-2.5 text-right tabular-nums text-muted-foreground">{number(owner.won_count)}</td>
                      <td className="px-4 py-2.5 text-right font-medium tabular-nums text-foreground">{formatCurrency(owner.won_revenue, defaultCurrency)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>
        </>
      )}
    </div>
  );
}
