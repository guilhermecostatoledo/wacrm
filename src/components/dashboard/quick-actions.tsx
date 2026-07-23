"use client";

import Link from "next/link";
import type { ComponentType } from "react";
import { CalendarCheck2, GitBranch, MessageSquare, UserRoundPlus } from "lucide-react";

interface Action {
  label: string;
  description: string;
  href: string;
  icon: ComponentType<{ className?: string }>;
}

const ACTIONS: Action[] = [
  {
    label: "Novo lead",
    description: "Capturar, distribuir e criar o primeiro contato",
    href: "/leads",
    icon: UserRoundPlus,
  },
  {
    label: "Minha agenda",
    description: "Executar tarefas vencidas e previstas para hoje",
    href: "/tasks",
    icon: CalendarCheck2,
  },
  {
    label: "Pipeline",
    description: "Avançar oportunidades e registrar a próxima ação",
    href: "/pipelines",
    icon: GitBranch,
  },
  {
    label: "Conversas",
    description: "Responder atendimentos e acompanhar pendências",
    href: "/inbox",
    icon: MessageSquare,
  },
];

export function QuickActions() {
  return (
    <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
      {ACTIONS.map((action) => {
        const Icon = action.icon;
        return (
          <Link
            key={action.href}
            href={action.href}
            className="group rounded-xl border border-border bg-card px-4 py-3 transition-colors hover:border-primary/30 hover:bg-muted/50"
          >
            <div className="flex items-start gap-3">
              <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary">
                <Icon className="h-4 w-4" />
              </div>
              <div className="min-w-0">
                <p className="text-sm font-semibold text-foreground">{action.label}</p>
                <p className="mt-0.5 line-clamp-2 text-xs leading-4 text-muted-foreground">
                  {action.description}
                </p>
              </div>
            </div>
          </Link>
        );
      })}
    </div>
  );
}
