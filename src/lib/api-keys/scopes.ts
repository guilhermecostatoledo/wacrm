// ============================================================
// API key scopes — pure, unit-testable, no I/O.
// ============================================================

export const API_SCOPES = [
  'messages:send',
  'messages:read',
  'contacts:read',
  'contacts:write',
  'leads:read',
  'leads:write',
  'tasks:read',
  'tasks:write',
  'opportunities:read',
  'opportunities:write',
  'opportunities:close',
  'campaigns:read',
  'campaigns:write',
  'conversations:read',
  'broadcasts:send',
  'webhooks:manage',
] as const;

export type ApiScope = (typeof API_SCOPES)[number];

export const SCOPE_DESCRIPTIONS: Record<ApiScope, string> = {
  'messages:send': 'Send WhatsApp messages',
  'messages:read': 'Read messages and their delivery status',
  'contacts:read': 'List and read contacts',
  'contacts:write': 'Create and update contacts',
  'leads:read': 'List and read leads',
  'leads:write': 'Capture, assign and update leads',
  'tasks:read': 'List and read CRM tasks',
  'tasks:write': 'Create, assign and complete CRM tasks',
  'opportunities:read': 'List and read opportunities',
  'opportunities:write': 'Create and move opportunities',
  'opportunities:close': 'Mark opportunities won, lost or reopen them',
  'campaigns:read': 'List campaigns and attribution results',
  'campaigns:write': 'Create campaigns and record marketing touchpoints',
  'conversations:read': 'List and read conversations',
  'broadcasts:send': 'Launch broadcast campaigns',
  'webhooks:manage': 'Register and manage outbound event webhooks',
};

export function isApiScope(value: unknown): value is ApiScope {
  return (
    typeof value === 'string' &&
    (API_SCOPES as readonly string[]).includes(value)
  );
}

export function normalizeScopes(input: unknown): ApiScope[] | null {
  if (!Array.isArray(input)) return null;
  const out: ApiScope[] = [];
  for (const entry of input) {
    if (!isApiScope(entry)) return null;
    if (!out.includes(entry)) out.push(entry);
  }
  return out;
}

export function hasScope(
  granted: readonly string[],
  required: ApiScope
): boolean {
  return granted.includes(required);
}
