import { cn } from "@/lib/utils";

const TONES: Record<string, string> = {
  new: "border-blue-500/25 bg-blue-500/10 text-blue-700 dark:text-blue-300",
  assigned: "border-cyan-500/25 bg-cyan-500/10 text-cyan-700 dark:text-cyan-300",
  attempting_contact: "border-amber-500/25 bg-amber-500/10 text-amber-700 dark:text-amber-300",
  connected: "border-indigo-500/25 bg-indigo-500/10 text-indigo-700 dark:text-indigo-300",
  qualifying: "border-violet-500/25 bg-violet-500/10 text-violet-700 dark:text-violet-300",
  qualified: "border-emerald-500/25 bg-emerald-500/10 text-emerald-700 dark:text-emerald-300",
  nurturing: "border-orange-500/25 bg-orange-500/10 text-orange-700 dark:text-orange-300",
  converted: "border-green-500/25 bg-green-500/10 text-green-700 dark:text-green-300",
  disqualified: "border-slate-500/25 bg-slate-500/10 text-slate-700 dark:text-slate-300",
  reopened: "border-fuchsia-500/25 bg-fuchsia-500/10 text-fuchsia-700 dark:text-fuchsia-300",
  open: "border-blue-500/25 bg-blue-500/10 text-blue-700 dark:text-blue-300",
  in_progress: "border-amber-500/25 bg-amber-500/10 text-amber-700 dark:text-amber-300",
  completed: "border-emerald-500/25 bg-emerald-500/10 text-emerald-700 dark:text-emerald-300",
  cancelled: "border-slate-500/25 bg-slate-500/10 text-slate-700 dark:text-slate-300",
  won: "border-green-500/25 bg-green-500/10 text-green-700 dark:text-green-300",
  lost: "border-rose-500/25 bg-rose-500/10 text-rose-700 dark:text-rose-300",
};

const LABELS: Record<string, string> = {
  new: "Novo",
  assigned: "Atribuído",
  attempting_contact: "Tentando contato",
  connected: "Conectado",
  qualifying: "Qualificando",
  qualified: "Qualificado",
  nurturing: "Nutrição",
  converted: "Convertido",
  disqualified: "Desqualificado",
  reopened: "Reaberto",
  open: "Aberto",
  in_progress: "Em andamento",
  completed: "Concluído",
  cancelled: "Cancelado",
  won: "Ganho",
  lost: "Perdido",
};

interface StatusPillProps {
  status: string;
  label?: string;
  className?: string;
}

export function StatusPill({ status, label, className }: StatusPillProps) {
  return (
    <span
      className={cn(
        "inline-flex max-w-full items-center rounded-full border px-2 py-0.5 text-[11px] font-medium leading-4",
        TONES[status] ?? "border-border bg-muted text-muted-foreground",
        className,
      )}
    >
      <span className="truncate">{label ?? LABELS[status] ?? status}</span>
    </span>
  );
}
