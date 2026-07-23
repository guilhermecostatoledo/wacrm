export interface FunnelStage {
  key: string;
  count: number;
}

export function safeRate(numerator: number, denominator: number): number {
  if (!Number.isFinite(numerator) || !Number.isFinite(denominator) || denominator <= 0) {
    return 0;
  }
  return Math.round((numerator / denominator) * 10_000) / 100;
}

export function weightedPipelineValue(
  opportunities: readonly { value: number | null; probability: number | null }[],
): number {
  const total = opportunities.reduce((sum, opportunity) => {
    const value = Number(opportunity.value ?? 0);
    const probability = Math.max(0, Math.min(100, Number(opportunity.probability ?? 0)));
    if (!Number.isFinite(value) || value <= 0) return sum;
    return sum + value * (probability / 100);
  }, 0);
  return Math.round(total * 100) / 100;
}

export function funnelConversionRates(stages: readonly FunnelStage[]): Array<
  FunnelStage & { previousRate: number; overallRate: number }
> {
  const first = stages[0]?.count ?? 0;
  return stages.map((stage, index) => ({
    ...stage,
    previousRate: index === 0 ? 100 : safeRate(stage.count, stages[index - 1]?.count ?? 0),
    overallRate: safeRate(stage.count, first),
  }));
}

export function average(values: readonly number[]): number {
  const valid = values.filter((value) => Number.isFinite(value));
  if (valid.length === 0) return 0;
  return Math.round((valid.reduce((sum, value) => sum + value, 0) / valid.length) * 100) / 100;
}
