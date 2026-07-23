import { describe, expect, it } from "vitest";
import {
  chooseAttributedTouchpoint,
  isContactableConsent,
  parseUtmParameters,
} from "./attribution";

describe("UTM parsing", () => {
  it("extracts normalized campaign fields", () => {
    expect(
      parseUtmParameters(
        "https://example.com/?utm_source=google&utm_medium=cpc&utm_campaign=crm&utm_term=leads&utm_content=hero",
      ),
    ).toEqual({
      source: "google",
      medium: "cpc",
      campaign: "crm",
      term: "leads",
      content: "hero",
    });
  });
});

describe("attribution", () => {
  const touchpoints = [
    { id: "b", campaignId: "campaign-2", occurredAt: "2026-07-20T12:00:00Z", eventType: "click" },
    { id: "a", campaignId: "campaign-1", occurredAt: "2026-07-19T12:00:00Z", eventType: "form_submission" },
    { id: "c", campaignId: "campaign-3", occurredAt: "2026-07-21T12:00:00Z", eventType: "reply" },
  ];

  it("chooses first and last touch deterministically", () => {
    expect(chooseAttributedTouchpoint(touchpoints, "first_touch")?.campaignId).toBe("campaign-1");
    expect(chooseAttributedTouchpoint(touchpoints, "last_touch")?.campaignId).toBe("campaign-3");
  });

  it("returns null without valid timestamps", () => {
    expect(
      chooseAttributedTouchpoint(
        [{ id: "x", campaignId: "c", occurredAt: "invalid", eventType: "click" }],
        "last_touch",
      ),
    ).toBeNull();
  });
});

describe("consent", () => {
  it("allows opted-in and transactional-only contacts", () => {
    expect(isContactableConsent("opted_in")).toBe(true);
    expect(isContactableConsent("transactional_only")).toBe(true);
    expect(isContactableConsent("opted_out")).toBe(false);
    expect(isContactableConsent(undefined)).toBe(false);
  });
});
