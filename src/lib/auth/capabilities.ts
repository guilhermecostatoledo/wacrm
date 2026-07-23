import type { AccountRole } from "./roles";

export const CAPABILITIES = [
  "contact.read",
  "contact.write",
  "contact.archive",
  "contact.import",
  "lead.read",
  "lead.create",
  "lead.update",
  "lead.assign",
  "lead.disqualify",
  "lead.convert",
  "activity.read",
  "activity.create",
  "activity.correct",
  "task.read",
  "task.create",
  "task.update",
  "task.delegate",
  "opportunity.read",
  "opportunity.create",
  "opportunity.update",
  "opportunity.close",
  "conversation.read",
  "conversation.assign",
  "message.send",
  "broadcast.read",
  "broadcast.create",
  "broadcast.approve",
  "broadcast.send",
  "automation.read",
  "automation.manage",
  "pipeline.read",
  "pipeline.manage",
  "report.view",
  "report.export",
  "audit.read",
  "team.manage",
  "member.manage",
  "account.settings",
  "account.manage",
  "account.transfer",
  "account.delete",
] as const;

export type Capability = (typeof CAPABILITIES)[number];
export type CapabilityEffect = "allow" | "deny";

export interface CapabilityOverride {
  capability: Capability;
  effect: CapabilityEffect;
  expiresAt?: Date | string | null;
}

const VIEWER_CAPABILITIES: readonly Capability[] = [
  "contact.read",
  "lead.read",
  "activity.read",
  "task.read",
  "opportunity.read",
  "conversation.read",
  "broadcast.read",
  "automation.read",
  "pipeline.read",
  "report.view",
];

const AGENT_CAPABILITIES: readonly Capability[] = [
  ...VIEWER_CAPABILITIES,
  "contact.write",
  "contact.archive",
  "contact.import",
  "lead.create",
  "lead.update",
  "lead.assign",
  "lead.disqualify",
  "lead.convert",
  "activity.create",
  "activity.correct",
  "task.create",
  "task.update",
  "task.delegate",
  "opportunity.create",
  "opportunity.update",
  "opportunity.close",
  "conversation.assign",
  "message.send",
];

const ADMIN_CAPABILITIES: readonly Capability[] = [
  ...AGENT_CAPABILITIES,
  "broadcast.create",
  "broadcast.approve",
  "broadcast.send",
  "automation.manage",
  "pipeline.manage",
  "report.export",
  "audit.read",
  "team.manage",
  "member.manage",
  "account.settings",
  "account.manage",
];

const OWNER_CAPABILITIES: readonly Capability[] = [
  ...ADMIN_CAPABILITIES,
  "account.transfer",
  "account.delete",
];

export const ROLE_CAPABILITIES: Readonly<Record<AccountRole, readonly Capability[]>> = {
  viewer: VIEWER_CAPABILITIES,
  agent: AGENT_CAPABILITIES,
  admin: ADMIN_CAPABILITIES,
  owner: OWNER_CAPABILITIES,
};

export function isCapability(value: unknown): value is Capability {
  return typeof value === "string" && (CAPABILITIES as readonly string[]).includes(value);
}

export function roleHasCapability(role: AccountRole, capability: Capability): boolean {
  return ROLE_CAPABILITIES[role].includes(capability);
}

function isOverrideActive(override: CapabilityOverride, now: Date): boolean {
  if (!override.expiresAt) return true;
  const expiresAt = override.expiresAt instanceof Date
    ? override.expiresAt
    : new Date(override.expiresAt);
  return Number.isFinite(expiresAt.getTime()) && expiresAt.getTime() > now.getTime();
}

/**
 * Explicit member grants win over role defaults. A deny wins over an allow
 * when duplicate active overrides are supplied, which makes the resolver safe
 * against accidentally merged grant sources.
 */
export function hasCapability(
  role: AccountRole,
  capability: Capability,
  overrides: readonly CapabilityOverride[] = [],
  now = new Date(),
): boolean {
  const active = overrides.filter(
    (override) => override.capability === capability && isOverrideActive(override, now),
  );

  if (active.some((override) => override.effect === "deny")) return false;
  if (active.some((override) => override.effect === "allow")) return true;
  return roleHasCapability(role, capability);
}
