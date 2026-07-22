'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { ListTodo, UserRound } from 'lucide-react';

import { cn } from '@/lib/utils';

const shortcuts = [
  { href: '/tasks', label: 'Meu dia', icon: ListTodo },
  { href: '/leads', label: 'Leads', icon: UserRound },
];

export function CrmShortcuts() {
  const pathname = usePathname();

  return (
    <nav
      aria-label="Operação comercial"
      className="mb-4 flex flex-wrap items-center gap-2 rounded-xl border border-border bg-card/70 p-2 shadow-sm"
    >
      <span className="px-2 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
        Operação
      </span>
      {shortcuts.map((item) => {
        const active = pathname === item.href || pathname.startsWith(`${item.href}/`);
        const Icon = item.icon;

        return (
          <Link
            key={item.href}
            href={item.href}
            className={cn(
              'inline-flex h-9 items-center gap-2 rounded-lg px-3 text-sm font-medium transition-colors',
              active
                ? 'bg-primary text-primary-foreground'
                : 'text-muted-foreground hover:bg-muted hover:text-foreground',
            )}
          >
            <Icon className="size-4" />
            {item.label}
          </Link>
        );
      })}
    </nav>
  );
}
