import { describe, expect, it } from "vitest";
import {
  agendaBucket,
  nextRecurrenceDueAt,
  parseTaskCreateInput,
} from "./operations";

const CONTACT_ID = "11111111-1111-4111-8111-111111111111";
const USER_ID = "22222222-2222-4222-8222-222222222222";

describe("parseTaskCreateInput", () => {
  it("normalizes a valid task", () => {
    const result = parseTaskCreateInput({
      contact_id: CONTACT_ID,
      assigned_to: USER_ID,
      task_type: "meeting",
      title: "  Discovery meeting  ",
      description: "Understand the customer context",
      priority: "high",
      due_at: "2026-07-23T15:00:00-03:00",
      recurrence_rule: "freq=weekly;interval=2",
    });

    expect(result).toEqual({
      ok: true,
      value: {
        contactId: CONTACT_ID,
        assignedTo: USER_ID,
        taskType: "meeting",
        title: "Discovery meeting",
        description: "Understand the customer context",
        priority: "high",
        dueAt: "2026-07-23T18:00:00.000Z",
        recurrenceRule: "FREQ=WEEKLY;INTERVAL=2",
      },
    });
  });

  it.each([
    [null, "Request body must be a JSON object"],
    [{}, "'contact_id' is required"],
    [{ contact_id: "invalid" }, "'contact_id' must be a UUID"],
    [{ contact_id: CONTACT_ID, title: "X", due_at: "invalid" }, "'due_at' must be a valid ISO date"],
    [{ contact_id: CONTACT_ID, due_at: "2026-07-23", title: "X", task_type: "unknown" }, "'task_type' is invalid"],
    [{ contact_id: CONTACT_ID, due_at: "2026-07-23", title: "X", recurrence_rule: "FREQ=YEARLY" }, "'recurrence_rule' supports FREQ=DAILY|WEEKLY|MONTHLY with optional INTERVAL"],
  ])("rejects invalid payload %#", (payload, error) => {
    expect(parseTaskCreateInput(payload)).toEqual({ ok: false, error });
  });
});

describe("agendaBucket", () => {
  const now = new Date("2026-07-22T12:00:00-03:00");

  it("separates overdue, today and upcoming work", () => {
    expect(agendaBucket("open", "2026-07-21T18:00:00-03:00", now)).toBe("overdue");
    expect(agendaBucket("in_progress", "2026-07-22T18:00:00-03:00", now)).toBe("today");
    expect(agendaBucket("open", "2026-07-23T09:00:00-03:00", now)).toBe("upcoming");
  });

  it("uses terminal status before dates", () => {
    expect(agendaBucket("completed", "2026-07-20T09:00:00Z", now)).toBe("completed");
    expect(agendaBucket("cancelled", "2026-07-20T09:00:00Z", now)).toBe("cancelled");
  });
});

describe("nextRecurrenceDueAt", () => {
  it("advances daily, weekly and monthly rules", () => {
    expect(nextRecurrenceDueAt("2026-07-22T12:00:00Z", "FREQ=DAILY;INTERVAL=2").toISOString()).toBe(
      "2026-07-24T12:00:00.000Z",
    );
    expect(nextRecurrenceDueAt("2026-07-22T12:00:00Z", "FREQ=WEEKLY").toISOString()).toBe(
      "2026-07-29T12:00:00.000Z",
    );
    expect(nextRecurrenceDueAt("2026-07-22T12:00:00Z", "FREQ=MONTHLY").toISOString()).toBe(
      "2026-08-22T12:00:00.000Z",
    );
  });

  it("rejects unsupported rules", () => {
    expect(() => nextRecurrenceDueAt("2026-07-22T12:00:00Z", "FREQ=YEARLY")).toThrow(
      "Unsupported recurrence rule",
    );
  });
});
