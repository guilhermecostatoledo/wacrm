export interface LeadIntakeInput {
  phone: string;
  phoneNormalized: string;
  name?: string;
  email?: string;
  company?: string;
  sourceCode: string;
  externalKey?: string;
  requestedOwnerId?: string;
  sourceDetail: Record<string, unknown>;
  firstResponseMinutes: number;
  createFirstTask: boolean;
  reopenDisqualified: boolean;
}

export type LeadIntakeParseResult =
  | { ok: true; value: LeadIntakeInput }
  | { ok: false; error: string };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SOURCE_CODE_RE = /^[a-z0-9][a-z0-9_-]{0,63}$/;

function optionalText(value: unknown, maxLength: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const normalized = value.trim();
  if (!normalized) return undefined;
  return normalized.slice(0, maxLength);
}

export function normalizeLeadPhone(phone: string): string {
  return phone.replace(/\D/g, "");
}

export function parseLeadIntakeInput(raw: unknown): LeadIntakeParseResult {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return { ok: false, error: "Request body must be a JSON object" };
  }

  const input = raw as Record<string, unknown>;
  const phone = optionalText(input.phone, 64);
  if (!phone) return { ok: false, error: "'phone' is required" };

  const phoneNormalized = normalizeLeadPhone(phone);
  if (phoneNormalized.length < 8 || phoneNormalized.length > 15) {
    return { ok: false, error: "'phone' must contain between 8 and 15 digits" };
  }

  const sourceCode = optionalText(input.source_code, 64) ?? "api";
  if (!SOURCE_CODE_RE.test(sourceCode)) {
    return { ok: false, error: "'source_code' has an invalid format" };
  }

  const externalKey = optionalText(input.external_key, 200);
  const requestedOwnerId = optionalText(input.requested_owner_id, 36);
  if (requestedOwnerId && !UUID_RE.test(requestedOwnerId)) {
    return { ok: false, error: "'requested_owner_id' must be a UUID" };
  }

  const email = optionalText(input.email, 320)?.toLowerCase();
  if (email && (!email.includes("@") || email.startsWith("@") || email.endsWith("@"))) {
    return { ok: false, error: "'email' is invalid" };
  }

  const sourceDetail =
    input.source_detail && typeof input.source_detail === "object" && !Array.isArray(input.source_detail)
      ? (input.source_detail as Record<string, unknown>)
      : {};

  const firstResponseMinutes =
    typeof input.first_response_minutes === "number"
      ? Math.trunc(input.first_response_minutes)
      : 60;
  if (firstResponseMinutes < 1 || firstResponseMinutes > 10_080) {
    return { ok: false, error: "'first_response_minutes' must be between 1 and 10080" };
  }

  return {
    ok: true,
    value: {
      phone,
      phoneNormalized,
      name: optionalText(input.name, 200),
      email,
      company: optionalText(input.company, 200),
      sourceCode,
      externalKey,
      requestedOwnerId,
      sourceDetail,
      firstResponseMinutes,
      createFirstTask: input.create_first_task !== false,
      reopenDisqualified: input.reopen_disqualified === true,
    },
  };
}
