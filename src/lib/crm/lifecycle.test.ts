import { describe, expect, it } from "vitest";
import {
  canTransitionLead,
  getAvailableLeadStatuses,
  isClosedLeadStatus,
  isTaskDueToday,
  isTaskOverdue,
} from "./lifecycle";

describe("lead lifecycle", () => {
  it("allows the normal qualification path", () => {
    expect(canTransitionLead("new", "attempting_contact")).toBe(true);
    expect(canTransitionLead("attempting_contact", "contacted")).toBe(true);
    expect(canTransitionLead("contacted", "qualified")).toBe(true);
    expect(canTransitionLead("qualified", "converted")).toBe(true);
  });

  it("blocks invalid jumps that skip the commercial process", () => {
    expect(canTransitionLead("new", "converted")).toBe(false);
    expect(canTransitionLead("attempting_contact", "qualified")).toBe(false);
  });

  it("keeps the current status available for idempotent updates", () => {
    expect(getAvailableLeadStatuses("contacted")).toContain("contacted");
  });

  it("identifies terminal statuses", () => {
    expect(isClosedLeadStatus("disqualified")).toBe(true);
    expect(isClosedLeadStatus("converted")).toBe(true);
    expect(isClosedLeadStatus("archived")).toBe(true);
    expect(isClosedLeadStatus("qualified")).toBe(false);
  });
});

describe("task timing", () => {
  const now = new Date("2026-07-22T12:00:00.000Z");

  it("marks only open tasks in the past as overdue", () => {
    expect(isTaskOverdue("2026-07-22T11:00:00.000Z", "open", now)).toBe(true);
    expect(isTaskOverdue("2026-07-22T11:00:00.000Z", "completed", now)).toBe(false);
    expect(isTaskOverdue("2026-07-22T13:00:00.000Z", "open", now)).toBe(false);
  });

  it("detects tasks due on the same calendar date", () => {
    expect(isTaskDueToday("2026-07-22T23:00:00.000Z", now)).toBe(true);
    expect(isTaskDueToday("2026-07-23T00:00:00.000Z", now)).toBe(false);
  });
});
