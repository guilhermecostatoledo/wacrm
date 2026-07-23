import { describe, expect, it } from "vitest";
import {
  CAPABILITIES,
  hasCapability,
  isCapability,
  roleHasCapability,
} from "./capabilities";

describe("capability registry", () => {
  it("contains unique capability keys", () => {
    expect(new Set(CAPABILITIES).size).toBe(CAPABILITIES.length);
  });

  it("narrows only registered keys", () => {
    expect(isCapability("lead.assign")).toBe(true);
    expect(isCapability("send-messages")).toBe(false);
    expect(isCapability(null)).toBe(false);
  });
});

describe("role presets", () => {
  it("keeps viewers read-only", () => {
    expect(roleHasCapability("viewer", "contact.read")).toBe(true);
    expect(roleHasCapability("viewer", "contact.write")).toBe(false);
    expect(roleHasCapability("viewer", "message.send")).toBe(false);
  });

  it("does not let agents send campaigns or manage automations", () => {
    expect(roleHasCapability("agent", "message.send")).toBe(true);
    expect(roleHasCapability("agent", "broadcast.send")).toBe(false);
    expect(roleHasCapability("agent", "automation.manage")).toBe(false);
  });

  it("reserves account transfer and deletion for owners", () => {
    expect(roleHasCapability("admin", "account.transfer")).toBe(false);
    expect(roleHasCapability("admin", "account.delete")).toBe(false);
    expect(roleHasCapability("owner", "account.transfer")).toBe(true);
    expect(roleHasCapability("owner", "account.delete")).toBe(true);
  });
});

describe("member overrides", () => {
  const now = new Date("2026-07-22T12:00:00Z");

  it("allows a temporary grant beyond the role preset", () => {
    expect(
      hasCapability(
        "agent",
        "broadcast.create",
        [{ capability: "broadcast.create", effect: "allow", expiresAt: "2026-07-23T12:00:00Z" }],
        now,
      ),
    ).toBe(true);
  });

  it("ignores expired grants", () => {
    expect(
      hasCapability(
        "agent",
        "broadcast.create",
        [{ capability: "broadcast.create", effect: "allow", expiresAt: "2026-07-21T12:00:00Z" }],
        now,
      ),
    ).toBe(false);
  });

  it("gives an active deny precedence over allow", () => {
    expect(
      hasCapability(
        "admin",
        "broadcast.send",
        [
          { capability: "broadcast.send", effect: "allow" },
          { capability: "broadcast.send", effect: "deny" },
        ],
        now,
      ),
    ).toBe(false);
  });
});
