import type { LucideIcon } from "lucide-react";
import { AlertTriangle, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";

interface LoadingStateProps {
  label?: string;
}

export function LoadingState({ label = "Carregando dados..." }: LoadingStateProps) {
  return (
    <div className="flex min-h-48 items-center justify-center rounded-xl border border-border bg-card/60">
      <div className="flex items-center gap-2 text-sm text-muted-foreground">
        <Loader2 className="h-4 w-4 animate-spin" />
        {label}
      </div>
    </div>
  );
}

interface EmptyStateProps {
  icon: LucideIcon;
  title: string;
  description: string;
  actionLabel?: string;
  onAction?: () => void;
}

export function EmptyState({
  icon: Icon,
  title,
  description,
  actionLabel,
  onAction,
}: EmptyStateProps) {
  return (
    <div className="flex min-h-56 flex-col items-center justify-center rounded-xl border border-dashed border-border bg-card/40 px-6 text-center">
      <div className="mb-3 flex h-10 w-10 items-center justify-center rounded-xl bg-muted text-muted-foreground">
        <Icon className="h-5 w-5" />
      </div>
      <h2 className="text-sm font-semibold text-foreground">{title}</h2>
      <p className="mt-1 max-w-md text-sm text-muted-foreground">{description}</p>
      {actionLabel && onAction ? (
        <Button className="mt-4" size="sm" onClick={onAction}>
          {actionLabel}
        </Button>
      ) : null}
    </div>
  );
}

interface ErrorStateProps {
  message: string;
  onRetry?: () => void;
}

export function ErrorState({ message, onRetry }: ErrorStateProps) {
  return (
    <div className="flex min-h-48 flex-col items-center justify-center rounded-xl border border-destructive/30 bg-destructive/5 px-6 text-center">
      <AlertTriangle className="mb-3 h-6 w-6 text-destructive" />
      <h2 className="text-sm font-semibold text-foreground">Não foi possível carregar</h2>
      <p className="mt-1 max-w-lg text-sm text-muted-foreground">{message}</p>
      {onRetry ? (
        <Button className="mt-4" variant="outline" size="sm" onClick={onRetry}>
          Tentar novamente
        </Button>
      ) : null}
    </div>
  );
}
