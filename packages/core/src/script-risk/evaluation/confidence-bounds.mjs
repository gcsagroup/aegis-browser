const DEFAULT_CONFIDENCE_LEVEL = 0.95;
const CONTINUED_FRACTION_EPSILON = 1e-14;
const CONTINUED_FRACTION_FLOOR = 1e-300;
const MAX_CONTINUED_FRACTION_ITERATIONS = 512;
const INVERSE_ITERATIONS = 100;

// Lanczos 近似系数；本模块只会以正整数参数调用 logGamma。
const LANCZOS_G = 7;
const LANCZOS_COEFFICIENTS = [
  0.9999999999998099,
  676.5203681218851,
  -1259.1392167224028,
  771.3234287776531,
  -176.6150291621406,
  12.507343278686905,
  -0.13857109526572012,
  9.984369578019572e-6,
  1.5056327351493116e-7,
];

function validateInputs(successes, trials, confidenceLevel) {
  if (!Number.isSafeInteger(trials) || trials <= 0) {
    throw new RangeError("trials must be a positive safe integer");
  }
  if (
    !Number.isSafeInteger(successes) ||
    successes < 0 ||
    successes > trials
  ) {
    throw new RangeError(
      "successes must be a safe integer between 0 and trials",
    );
  }
  if (
    typeof confidenceLevel !== "number" ||
    !Number.isFinite(confidenceLevel) ||
    confidenceLevel <= 0 ||
    confidenceLevel >= 1
  ) {
    throw new RangeError("confidenceLevel must be finite and between 0 and 1");
  }
}

function logGamma(value) {
  const shifted = value - 1;
  let series = LANCZOS_COEFFICIENTS[0];
  for (let index = 1; index < LANCZOS_COEFFICIENTS.length; index += 1) {
    series += LANCZOS_COEFFICIENTS[index] / (shifted + index);
  }

  const base = shifted + LANCZOS_G + 0.5;
  return (
    0.5 * Math.log(2 * Math.PI) +
    (shifted + 0.5) * Math.log(base) -
    base +
    Math.log(series)
  );
}

/** 计算不完全 Beta 的连分数部分。对称分支保证 x 位于收敛较快的一侧。 */
function betaContinuedFraction(a, b, x) {
  const sum = a + b;
  const aPlusOne = a + 1;
  const aMinusOne = a - 1;
  let c = 1;
  let d = 1 - (sum * x) / aPlusOne;
  if (Math.abs(d) < CONTINUED_FRACTION_FLOOR) {
    d = CONTINUED_FRACTION_FLOOR;
  }
  d = 1 / d;
  let result = d;

  for (
    let iteration = 1;
    iteration <= MAX_CONTINUED_FRACTION_ITERATIONS;
    iteration += 1
  ) {
    const doubled = 2 * iteration;
    let coefficient =
      (iteration * (b - iteration) * x) /
      ((aMinusOne + doubled) * (a + doubled));
    d = 1 + coefficient * d;
    if (Math.abs(d) < CONTINUED_FRACTION_FLOOR) {
      d = CONTINUED_FRACTION_FLOOR;
    }
    c = 1 + coefficient / c;
    if (Math.abs(c) < CONTINUED_FRACTION_FLOOR) {
      c = CONTINUED_FRACTION_FLOOR;
    }
    d = 1 / d;
    result *= d * c;

    coefficient =
      (-(a + iteration) * (sum + iteration) * x) /
      ((a + doubled) * (aPlusOne + doubled));
    d = 1 + coefficient * d;
    if (Math.abs(d) < CONTINUED_FRACTION_FLOOR) {
      d = CONTINUED_FRACTION_FLOOR;
    }
    c = 1 + coefficient / c;
    if (Math.abs(c) < CONTINUED_FRACTION_FLOOR) {
      c = CONTINUED_FRACTION_FLOOR;
    }
    d = 1 / d;
    const delta = d * c;
    result *= delta;

    if (Math.abs(delta - 1) <= CONTINUED_FRACTION_EPSILON) {
      return result;
    }
  }

  throw new Error("incomplete beta continued fraction did not converge");
}

function regularizedIncompleteBeta(x, a, b) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;

  const logScale =
    logGamma(a + b) -
    logGamma(a) -
    logGamma(b) +
    a * Math.log(x) +
    b * Math.log1p(-x);
  const scale = Math.exp(logScale);
  const value =
    x < (a + 1) / (a + b + 2)
      ? (scale * betaContinuedFraction(a, b, x)) / a
      : 1 - (scale * betaContinuedFraction(b, a, 1 - x)) / b;

  // 浮点舍入可能产生极小的越界，概率输出统一收敛到闭区间。
  return Math.min(1, Math.max(0, value));
}

function inverseRegularizedIncompleteBeta(probability, a, b) {
  let lower = 0;
  let upper = 1;

  // 固定次数二分避免依赖导数，在低事件率和大样本下仍保持稳定。
  for (let iteration = 0; iteration < INVERSE_ITERATIONS; iteration += 1) {
    const midpoint = lower + (upper - lower) / 2;
    if (midpoint === lower || midpoint === upper) break;
    if (regularizedIncompleteBeta(midpoint, a, b) < probability) {
      lower = midpoint;
    } else {
      upper = midpoint;
    }
  }

  return lower + (upper - lower) / 2;
}

/**
 * Clopper-Pearson 精确单侧下置信界。
 * “精确”指二项分布覆盖率不低于给定置信水平，结果通常是保守的。
 */
export function clopperPearsonLowerBound(
  successes,
  trials,
  confidenceLevel = DEFAULT_CONFIDENCE_LEVEL,
) {
  validateInputs(successes, trials, confidenceLevel);
  if (successes === 0) return 0;
  if (successes === trials) {
    return Math.exp(Math.log1p(-confidenceLevel) / trials);
  }
  return inverseRegularizedIncompleteBeta(
    1 - confidenceLevel,
    successes,
    trials - successes + 1,
  );
}

/** Clopper-Pearson 精确单侧上置信界。 */
export function clopperPearsonUpperBound(
  successes,
  trials,
  confidenceLevel = DEFAULT_CONFIDENCE_LEVEL,
) {
  validateInputs(successes, trials, confidenceLevel);
  if (successes === trials) return 1;
  if (successes === 0) {
    return -Math.expm1(Math.log1p(-confidenceLevel) / trials);
  }
  return inverseRegularizedIncompleteBeta(
    confidenceLevel,
    successes + 1,
    trials - successes,
  );
}
