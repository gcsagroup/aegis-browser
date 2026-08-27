import type { PageSnapshot, PhishAssessment } from "../types.js";
import { assessPhishing } from "./detector.js";

export interface PhishModelPort {
  /** Optional learned/scored head; returns null to fall back to heuristics. */
  score(snapshot: PageSnapshot): Promise<number | null>;
}

/**
 * Tiny bag-of-features logistic-ish scorer (no external weights file yet).
 * Acts as a hot-swappable slot for MobileBERT/PhishLang-class models.
 */
export function createLightweightPhishModel(): PhishModelPort {
  return {
    async score(snapshot) {
      const heuristic = assessPhishing(snapshot);
      // Blend: keep explainable heuristic as primary; model head nudges score.
      const text = `${snapshot.title} ${snapshot.textSample}`.toLowerCase();
      let nudge = 0;
      if (/(password|passwd|验证码|驗證|otp|wallet|seed phrase)/.test(text)) {
        nudge += 8;
      }
      if (/(urgent|immediately|suspend|立即|異常|异常)/.test(text)) {
        nudge += 6;
      }
      return Math.min(100, heuristic.score + nudge);
    },
  };
}

export async function assessWithModel(
  snapshot: PageSnapshot,
  allowlist: string[],
  model: PhishModelPort,
): Promise<PhishAssessment> {
  const base = assessPhishing(snapshot, allowlist);
  const modelScore = await model.score(snapshot);
  if (modelScore == null) return base;
  const score = Math.round(base.score * 0.7 + modelScore * 0.3);
  return {
    ...base,
    score,
    shouldBlock: score >= 55,
    severity:
      score >= 80 ? "critical" : score >= 55 ? "high" : score >= 30 ? "medium" : "low",
    reasons: [
      ...base.reasons,
      { code: "lightweight_model_blend", weight: modelScore - base.score },
    ],
  };
}
