export type WhatsAppProvider = "meta_cloud" | "evolution";
export type NormalizedDirection = "inbound" | "outbound";
export type NormalizedMessageType =
  | "text"
  | "image"
  | "audio"
  | "video"
  | "document"
  | "location"
  | "interactive"
  | "template"
  | "unknown";
export type DeliveryState = "sending" | "sent" | "delivered" | "read" | "failed";

export interface ProviderHealth {
  ok: boolean;
  provider: WhatsAppProvider;
  checkedAt: string;
  accountReference?: string;
  phoneReference?: string;
  details?: Record<string, unknown>;
}

export interface NormalizedInboundEvent {
  provider: WhatsAppProvider;
  eventId: string;
  eventType: "message" | "status" | "connection" | "unknown";
  occurredAt: string;
  phoneNumber: string;
  providerMessageId?: string;
  direction?: NormalizedDirection;
  messageType?: NormalizedMessageType;
  text?: string;
  mediaId?: string;
  mediaUrl?: string;
  status?: DeliveryState;
  raw: Record<string, unknown>;
}

export interface ProviderSendInput {
  phoneNumber: string;
  messageType: NormalizedMessageType;
  text?: string;
  mediaUrl?: string;
  templateName?: string;
  templateLanguage?: string;
  replyToProviderMessageId?: string;
  idempotencyKey: string;
}

export interface ProviderSendResult {
  providerMessageId: string;
  acceptedAt: string;
  raw?: Record<string, unknown>;
}

export interface WhatsAppProviderAdapter {
  readonly provider: WhatsAppProvider;
  health(): Promise<ProviderHealth>;
  normalizeWebhook(payload: unknown, headers?: Headers): NormalizedInboundEvent[];
  send(input: ProviderSendInput): Promise<ProviderSendResult>;
}

const DELIVERY_RANK: Readonly<Record<DeliveryState, number>> = {
  sending: 0,
  sent: 1,
  delivered: 2,
  read: 3,
  failed: -1,
};

/**
 * Delivery receipts may arrive out of order. A later retry must not move a
 * message from read back to delivered/sent. Failure is accepted only before
 * the provider has confirmed a successful send.
 */
export function shouldApplyDeliveryState(
  current: DeliveryState,
  incoming: DeliveryState,
): boolean {
  if (incoming === current) return false;
  if (incoming === "failed") return current === "sending";
  if (current === "failed") return true;
  return DELIVERY_RANK[incoming] > DELIVERY_RANK[current];
}

export function normalizeProviderPhone(value: string): string {
  return value.replace(/\D/g, "");
}

export function webhookIdempotencyKey(
  provider: WhatsAppProvider,
  eventId: string,
): string {
  const normalized = eventId.trim();
  if (!normalized) throw new Error("Provider event id is required");
  return `${provider}:${normalized}`;
}

export function assertAdapterEvent(event: NormalizedInboundEvent): void {
  if (!event.eventId.trim()) throw new Error("Normalized event requires eventId");
  if (!Number.isFinite(new Date(event.occurredAt).getTime())) {
    throw new Error("Normalized event requires a valid occurredAt");
  }
  const phone = normalizeProviderPhone(event.phoneNumber);
  if (phone.length < 8 || phone.length > 15) {
    throw new Error("Normalized event requires a valid phone number");
  }
  if (event.eventType === "message" && !event.providerMessageId) {
    throw new Error("Message events require providerMessageId");
  }
}
