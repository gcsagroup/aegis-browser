import { describe, expect, it } from "vitest";
import {
  clopperPearsonLowerBound,
  clopperPearsonUpperBound,
} from "./confidence-bounds.js";

describe("Clopper-Pearson 单侧置信界", () => {
  it("正确处理零成功和全部成功端点", () => {
    expect(clopperPearsonLowerBound(0, 100)).toBe(0);
    expect(clopperPearsonUpperBound(100, 100)).toBe(1);
    expect(clopperPearsonUpperBound(0, 100)).toBeCloseTo(
      0.02951304960703993,
      14,
    );
    expect(clopperPearsonLowerBound(100, 100)).toBeCloseTo(
      0.9704869503929601,
      14,
    );
  });

  it("按 0.1% FPR 预设门禁区分 10000 个良性样本中的 4 和 5 个误报", () => {
    const maximumFalsePositiveRate = 0.001;
    const fourFalsePositives = clopperPearsonUpperBound(4, 10_000);
    const fiveFalsePositives = clopperPearsonUpperBound(5, 10_000);

    expect(fourFalsePositives).toBeCloseTo(0.0009151160584710778, 14);
    expect(fiveFalsePositives).toBeCloseTo(0.0010510137186384819, 14);
    expect(fourFalsePositives <= maximumFalsePositiveRate).toBe(true);
    expect(fiveFalsePositives <= maximumFalsePositiveRate).toBe(false);
  });

  it("以计算出的下界判断 95% recall 门禁", () => {
    const minimumRecall = 0.95;
    const passing = clopperPearsonLowerBound(1_917, 2_000);
    const failing = clopperPearsonLowerBound(1_916, 2_000);

    expect(passing).toBeCloseTo(0.9503974682915636, 13);
    expect(failing).toBeCloseTo(0.9498561091112261, 13);
    expect(passing >= minimumRecall).toBe(true);
    expect(failing >= minimumRecall).toBe(false);
  });

  it("以计算出的上界判断 0.5% 破站率门禁", () => {
    const maximumBreakageRate = 0.005;
    const passing = clopperPearsonUpperBound(1, 1_000);
    const failing = clopperPearsonUpperBound(2, 1_000);

    expect(passing).toBeCloseTo(0.0047349935754998, 14);
    expect(failing).toBeCloseTo(0.006282284546723427, 14);
    expect(passing <= maximumBreakageRate).toBe(true);
    expect(failing <= maximumBreakageRate).toBe(false);
  });

  it("在大样本下保持有限、单调并满足成功失败对称性", () => {
    const upper = clopperPearsonUpperBound(100, 1_000_000);
    const nextUpper = clopperPearsonUpperBound(101, 1_000_000);
    const symmetricLower = clopperPearsonLowerBound(999_900, 1_000_000);
    const centralLower = clopperPearsonLowerBound(500_000, 1_000_000);
    const centralUpper = clopperPearsonUpperBound(500_000, 1_000_000);

    expect(Number.isFinite(upper)).toBe(true);
    expect(upper).toBeCloseTo(0.0001180782053691365, 13);
    expect(upper).toBeGreaterThan(100 / 1_000_000);
    expect(nextUpper).toBeGreaterThan(upper);
    expect(symmetricLower).toBeCloseTo(1 - upper, 13);
    expect(centralLower).toBeLessThan(0.5);
    expect(centralUpper).toBeGreaterThan(0.5);
    expect(centralLower).toBeCloseTo(1 - centralUpper, 13);
  });

  it.each([
    [-1, 10, 0.95],
    [11, 10, 0.95],
    [1.5, 10, 0.95],
    [1, 0, 0.95],
    [1, 10.5, 0.95],
    [1, Number.MAX_SAFE_INTEGER + 1, 0.95],
    [1, 10, 0],
    [1, 10, 1],
    [1, 10, Number.NaN],
    [1, 10, Number.POSITIVE_INFINITY],
  ])(
    "拒绝无效输入 successes=%s trials=%s confidence=%s",
    (successes, trials, confidence) => {
      expect(() =>
        clopperPearsonLowerBound(successes, trials, confidence),
      ).toThrow(RangeError);
      expect(() =>
        clopperPearsonUpperBound(successes, trials, confidence),
      ).toThrow(RangeError);
    },
  );
});
