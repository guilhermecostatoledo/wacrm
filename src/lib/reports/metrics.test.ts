import { describe, expect, it } from "vitest";
import {
  average,
  funnelConversionRates,
  safeRate,
  weightedPipelineValue,
} from "./metrics";

describe("report metric helpers", () => {
  it("calculates safe percentages", () => {
    expect(safeRate(25, 100)).toBe(25);
    expect(safeRate(1, 3)).toBe(33.33);
    expect(safeRate(1, 0)).toBe(0);
  });

  it("weights pipeline value by probability", () => {
    expect(
      weightedPipelineValue([
        { value: 10_000, probability: 50 },
        { value: 5_000, probability: 20 },
        { value: null, probability: 80 },
      ]),
    ).toBe(6_000);
  });

  it("builds previous and overall funnel rates", () => {
    expect(
      funnelConversionRates([
        { key: "captured", count: 100 },
        { key: "qualified", count: 40 },
        { key: "converted", count: 10 },
      ]),
    ).toEqual([
      { key: "captured", count: 100, previousRate: 100, overallRate: 100 },
      { key: "qualified", count: 40, previousRate: 40, overallRate: 40 },
      { key: "converted", count: 10, previousRate: 25, overallRate: 10 },
    ]);
  });

  it("averages only finite values", () => {
    expect(average([10, 20, Number.NaN])).toBe(15);
    expect(average([])).toBe(0);
  });
});
