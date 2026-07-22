"use client"

import Link from 'next/link'
import { Briefcase, ListTodo, Radio, UserPlus, UserRound, Zap } from 'lucide-react'
import type { ComponentType } from 'react'

// Quick-action shortcuts. Each navigates to the page that owns the
// relevant create/work flow. Operational actions come first so the
// dashboard helps the user decide what to do, not only what to inspect.
interface Action {
  label: string
  href: string
  icon: ComponentType<{ className?: string }>
  tint: string
}

const ACTIONS: Action[] = [
  { label: 'Meu dia', href: '/tasks', icon: ListTodo, tint: 'text-red-300' },
  { label: 'Leads', href: '/leads', icon: UserRound, tint: 'text-primary' },
  { label: 'Novo contato', href: '/contacts', icon: UserPlus, tint: 'text-primary' },
  { label: 'Novo negócio', href: '/pipelines', icon: Briefcase, tint: 'text-blue-400' },
  { label: 'Novo disparo', href: '/broadcasts/new', icon: Radio, tint: 'text-amber-400' },
  { label: 'Nova automação', href: '/automations/new', icon: Zap, tint: 'text-primary' },
]

export function QuickActions() {
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-6">
      {ACTIONS.map((a) => {
        const Icon = a.icon
        return (
          <Link
            key={a.href}
            href={a.href}
            className="group flex items-center gap-3 rounded-xl border border-border bg-card px-4 py-3 transition-colors hover:border-border hover:bg-muted/60"
          >
            <div className={`flex h-9 w-9 items-center justify-center rounded-lg bg-muted ${a.tint}`}>
              <Icon className="h-4 w-4" />
            </div>
            <span className="text-sm font-medium text-foreground">{a.label}</span>
          </Link>
        )
      })}
    </div>
  )
}
