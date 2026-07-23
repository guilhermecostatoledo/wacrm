import { describe, expect, it } from "vitest";
import {
  canMoveOpportunity,
  parseOpportunityCloseInput,
  probabilityForStage,
} from "./process";

const REASON_ID = "11111111-1111-4111-8111-111111111111";

describe("opportunity process", () => {
  it("moves only open opportunities", () => {
    expect(canMoveOpportunity("open", "open")).toBe(true);
    expect(canMoveOpportunity("open", "won")).toBe(true);
    expect(canMoveOpportunity("open", "lost")).toBe(false);
    expect(canMoveOpportunity("won", "open")).toBe(false);
  });

  it("normalizes probabilities by terminal stage", () => {
    expect(probabilityForStage("won", 20)).toBe(100);
    expect(probabilityForStage("lost", 80)).toBe(0);
    expect(probabilityForStage("open", 150)).toBe(99);
    expect(probabilityForStage("open", -2)).toBe(0);
  });
});

describe("parseOpportunityCloseInput", () => {
  it("requires a structured loss reason", () => {
    expect(parseOpportunityCloseInput({ action: "lose" })).toEqual({
      ok: false,
      error: "'loss_reason_id' is required and must be a UUID",
    });
    expect(parseOpportunityCloseInput({ action: "lose", loss_reason_id: REASON_ID })).toEqual({
      ok: true,
      value: {
        action: "lose",
        lossReasonId: REASON_ID,
        reopenStageId: undefined,
        nextTaskTitle: undefined,
        nextTaskDueAt: undefined,
      },
    });
  });

  it("requires a next action when reopening", () => {
    expect(parseOpportunityCloseInput({ action: "reopen" })).toEqual({
      ok: false,
      error: "'next_task_due_at' is required and must be a valid ISO date",
    });

    const parsed = parseOpportunityCloseInput({
      action: "reopen",
      next_task_title: "Follow up",
      next_task_due_at: "2026-07-25T10:00:00-03:00",
    });
    expect(parsed).toEqual({
      ok: true,
      value: {
        action: "reopen",
        lossReasonId: undefined,
        reopenStageId: undefined,
        nextTaskTitle: "Follow up",
        nextTaskDueAt: "2026-07-25T13:00:00.000Z",
      },
    });
  });

  it("rejects unknown actions", () => {
    expect(parseOpportunityCloseInput({ action: "invalid" })).toEqual({
      ok: false,
      error: "'action' must be win, lose or reopen",
    });
  });
});
