import { describe, expect, it } from "vitest";
import {
  assertAdapterEvent,
  normalizeProviderPhone,
  shouldApplyDeliveryState,
  webhookIdempotencyKey,
} from "./provider-adapter";

describe("delivery state ordering", () => {
  it("advances monotonically", () => {
    expect(shouldApplyDeliveryState("sending", "sent")).toBe(true);
    expect(shouldApplyDeliveryState("sent", "delivered")).toBe(true);
    expect(shouldApplyDeliveryState("delivered", "read")).toBe(true);
    expect(shouldApplyDeliveryState("read", "delivered")).toBe(false);
    expect(shouldApplyDeliveryState("delivered", "sent")).toBe(false);
  });

  it("accepts failure only before provider acceptance", () => {
    expect(shouldApplyDeliveryState("sending", "failed")).toBe(true);
    expect(shouldApplyDeliveryState("sent", "failed")).toBe(false);
    expect(shouldApplyDeliveryState("failed", "sent")).toBe(true);
  });
});

describe("provider normalization", () => {
  it("normalizes phones and event keys", () => {
    expect(normalizeProviderPhone("+55 (11) 99999-0000")).toBe("5511999990000");
    expect(webhookIdempotencyKey("meta_cloud", " wamid.123 ")).toBe(
      "meta_cloud:wamid.123",
    );
  });

  it("validates normalized message events", () => {
    expect(() =>
      assertAdapterEvent({
        provider: "meta_cloud",
        eventId: "evt-1",
        eventType: "message",
        occurredAt: "2026-07-22T12:00:00Z",
        phoneNumber: "+55 11 99999-0000",
        providerMessageId: "wamid.1",
        direction: "inbound",
        messageType: "text",
        text: "Olá",
        raw: {},
      }),
    ).not.toThrow();
  });

  it("rejects incomplete normalized events", () => {
    expect(() =>
      assertAdapterEvent({
        provider: "evolution",
        eventId: "evt-2",
        eventType: "message",
        occurredAt: "invalid",
        phoneNumber: "123",
        raw: {},
      }),
    ).toThrow();
    expect(() => webhookIdempotencyKey("evolution", " ")).toThrow(
      "Provider event id is required",
    );
  });
});
