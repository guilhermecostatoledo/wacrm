import { describe, expect, it } from "vitest";
import {
  assertLeadTransition,
  assertTaskTransition,
  canTransitionLead,
  canTransitionTask,
  isActionableTaskStatus,
  isTerminalLeadStatus,
} from "./domain";

describe("lead state machine", () => {
  it("allows the normal qualification path", () => {
    expect(canTransitionLead("new", "assigned")).toBe(true);
    expect(canTransitionLead("assigned", "attempting_contact")).toBe(true);
    expect(canTransitionLead("attempting_contact", "connected")).toBe(true);
    expect(canTransitionLead("connected", "qualifying")).toBe(true);
    expect(canTransitionLead("qualifying", "qualified")).toBe(true);
    expect(canTransitionLead("qualified", "converted")).toBe(true);
  });

  it("prevents skipping from new directly to converted", () => {
    expect(canTransitionLead("new", "converted")).toBe(false);
    expect(() => assertLeadTransition("new", "converted")).toThrow(
      "Invalid lead status transition: new -> converted",
    );
  });

  it("only reopens a disqualified lead through reopened", () => {
    expect(canTransitionLead("disqualified", "reopened")).toBe(true);
    expect(canTransitionLead("disqualified", "qualifying")).toBe(false);
  });

  it("treats converted and disqualified as terminal reporting states", () => {
    expect(isTerminalLeadStatus("converted")).toBe(true);
    expect(isTerminalLeadStatus("disqualified")).toBe(true);
    expect(isTerminalLeadStatus("nurturing")).toBe(false);
  });
});

describe("task state machine", () => {
  it("supports execution, completion and cancellation", () => {
    expect(canTransitionTask("open", "in_progress")).toBe(true);
    expect(canTransitionTask("in_progress", "completed")).toBe(true);
    expect(canTransitionTask("open", "cancelled")).toBe(true);
  });

  it("does not silently reopen completed work", () => {
    expect(canTransitionTask("completed", "open")).toBe(false);
    expect(() => assertTaskTransition("completed", "open")).toThrow(
      "Invalid task status transition: completed -> open",
    );
  });

  it("permits an explicitly cancelled task to be reopened", () => {
    expect(canTransitionTask("cancelled", "open")).toBe(true);
  });

  it("identifies actionable statuses", () => {
    expect(isActionableTaskStatus("open")).toBe(true);
    expect(isActionableTaskStatus("in_progress")).toBe(true);
    expect(isActionableTaskStatus("completed")).toBe(false);
    expect(isActionableTaskStatus("cancelled")).toBe(false);
  });
});
