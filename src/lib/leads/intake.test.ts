import { describe, expect, it } from "vitest";
import { normalizeLeadPhone, parseLeadIntakeInput } from "./intake";

describe("normalizeLeadPhone", () => {
  it("keeps only digits", () => {
    expect(normalizeLeadPhone("+55 (11) 99999-0000")).toBe("5511999990000");
  });
});

describe("parseLeadIntakeInput", () => {
  it("normalizes a valid API payload", () => {
    const result = parseLeadIntakeInput({
      phone: "+55 (11) 99999-0000",
      name: "  Ana Silva  ",
      email: "ANA@EXAMPLE.COM",
      source_code: "landing_page",
      external_key: "form-123",
      source_detail: { utm_campaign: "july" },
      first_response_minutes: 30,
    });

    expect(result).toEqual({
      ok: true,
      value: {
        phone: "+55 (11) 99999-0000",
        phoneNormalized: "5511999990000",
        name: "Ana Silva",
        email: "ana@example.com",
        company: undefined,
        sourceCode: "landing_page",
        externalKey: "form-123",
        requestedOwnerId: undefined,
        sourceDetail: { utm_campaign: "july" },
        firstResponseMinutes: 30,
        createFirstTask: true,
        reopenDisqualified: false,
      },
    });
  });

  it("defaults source, SLA and first task", () => {
    const result = parseLeadIntakeInput({ phone: "11999990000" });
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.value.sourceCode).toBe("api");
      expect(result.value.firstResponseMinutes).toBe(60);
      expect(result.value.createFirstTask).toBe(true);
    }
  });

  it.each([
    [null, "Request body must be a JSON object"],
    [{}, "'phone' is required"],
    [{ phone: "123" }, "'phone' must contain between 8 and 15 digits"],
    [{ phone: "11999990000", source_code: "Invalid Source" }, "'source_code' has an invalid format"],
    [{ phone: "11999990000", email: "invalid" }, "'email' is invalid"],
    [{ phone: "11999990000", requested_owner_id: "nope" }, "'requested_owner_id' must be a UUID"],
    [{ phone: "11999990000", first_response_minutes: 0 }, "'first_response_minutes' must be between 1 and 10080"],
  ])("rejects invalid payload %#", (payload, error) => {
    expect(parseLeadIntakeInput(payload)).toEqual({ ok: false, error });
  });
});
