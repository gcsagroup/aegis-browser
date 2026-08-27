import type { AegisPorts, NetRule } from "./ports.js";
import { assessPhishing, applyLocalFeedback } from "./phish/detector.js";
import {
  assessWithModel,
  createLightweightPhishModel,
  type PhishModelPort,
} from "./phish/lightweight-model.js";
import { rulesForSettings, classifyBlockedUrl, isWhitelisted } from "./tracker/classifier.js";
import { sanitizeUrlDecorations } from "./tracker/link-sanitize.js";
import {
  classifyCookie,
  shouldRejectCookie,
} from "./tracker/cookie-classify.js";
import { summarizePage, isSensitiveOrigin } from "./privacy/orchestrator.js";
import { gateOutboundText } from "./privacy/pii.js";
import type {
  AegisSettings,
  BlockEvent,
  LocaleCode,
  PageSnapshot,
  PhishAssessment,
  SummarizeResult,
  TabStats,
} from "./types.js";
import { DEFAULT_SETTINGS } from "./types.js";

export class PolicyEngine {
  private settings: AegisSettings = { ...DEFAULT_SETTINGS };
  private tabStats = new Map<number, TabStats>();
  private phishFeedback: Record<string, "safe" | "phish"> = {};
  private phishModel: PhishModelPort = createLightweightPhishModel();

  constructor(private readonly ports: AegisPorts) {}

  setPhishModel(model: PhishModelPort): void {
    this.phishModel = model;
  }

  async init(): Promise<void> {
    this.settings = await this.ports.settings.get();
    await this.syncTrackerRules();
  }

  getSettings(): AegisSettings {
    return this.settings;
  }

  async updateSettings(patch: Partial<AegisSettings>): Promise<AegisSettings> {
    this.settings = await this.ports.settings.set(patch);
    if (
      patch.modules !== undefined ||
      patch.trackerWhitelist !== undefined ||
      patch.ruleSourceUrl !== undefined
    ) {
      await this.syncTrackerRules();
    }
    return this.settings;
  }

  async syncTrackerRules(extraRules: NetRule[] = []): Promise<NetRule[]> {
    if (!this.settings.modules.tracker) {
      await this.ports.net.clearRules();
      return [];
    }
    const rules = [
      ...rulesForSettings(this.settings.trackerWhitelist),
      ...extraRules,
    ];
    await this.ports.net.applyRules(rules);
    return rules;
  }

  recordBlock(event: Omit<BlockEvent, "type"> & { type?: BlockEvent["type"] }): BlockEvent {
    const type = event.type ?? classifyBlockedUrl(event.url);
    const full: BlockEvent = { ...event, type };
    const prev = this.tabStats.get(event.tabId) ?? {
      tabId: event.tabId,
      blocked: 0,
      ads: 0,
      trackers: 0,
    };
    prev.blocked += 1;
    if (type === "ad") prev.ads += 1;
    if (type === "tracker") prev.trackers += 1;
    prev.lastUrl = event.url;
    this.tabStats.set(event.tabId, prev);
    return full;
  }

  getTabStats(tabId: number): TabStats {
    return (
      this.tabStats.get(tabId) ?? {
        tabId,
        blocked: 0,
        ads: 0,
        trackers: 0,
      }
    );
  }

  resetTabStats(tabId: number): void {
    this.tabStats.delete(tabId);
  }

  assessPage(snapshot: PageSnapshot): PhishAssessment {
    if (!this.settings.modules.phish) {
      return {
        score: 0,
        severity: "low",
        reasons: [],
        shouldBlock: false,
        url: snapshot.url,
      };
    }
    // Synchronous heuristic path for navigation intercept
    const base = assessPhishing(snapshot, this.settings.phishAllowlist);
    return applyLocalFeedback(base, this.phishFeedback);
  }

  async assessPageAsync(snapshot: PageSnapshot): Promise<PhishAssessment> {
    if (!this.settings.modules.phish) {
      return this.assessPage(snapshot);
    }
    const blended = await assessWithModel(
      snapshot,
      this.settings.phishAllowlist,
      this.phishModel,
    );
    return applyLocalFeedback(blended, this.phishFeedback);
  }

  markPhishFeedback(host: string, vote: "safe" | "phish"): void {
    this.phishFeedback[host.toLowerCase()] = vote;
  }

  getPhishFeedback(): Record<string, "safe" | "phish"> {
    return { ...this.phishFeedback };
  }

  loadPhishFeedback(data: Record<string, "safe" | "phish">): void {
    this.phishFeedback = { ...data };
  }

  async summarize(
    snapshot: PageSnapshot,
    locale?: Exclude<LocaleCode, "auto">,
  ): Promise<SummarizeResult> {
    if (!this.settings.modules.privacyAi) {
      return {
        summary: "",
        bullets: [],
        risks: [],
        backend: this.settings.modelBackend,
        modelReady: false,
      };
    }
    const resolved =
      locale ??
      (this.settings.locale === "auto" ? "zh-CN" : this.settings.locale);
    return summarizePage(this.ports.model, this.settings.modelBackend, {
      locale: resolved,
      snapshot,
    });
  }

  gateCloudPrompt(text: string, userApproved: boolean) {
    if (!this.settings.allowCloudModels) {
      return {
        allowed: false as const,
        payload: text,
        scan: gateOutboundText(text, true).scan,
        reason: "cloud_disabled" as const,
      };
    }
    const gated = gateOutboundText(text, userApproved);
    return { ...gated, reason: gated.allowed ? ("ok" as const) : ("pii_blocked" as const) };
  }

  cloudUploadAllowedForUrl(url: string): boolean {
    if (!this.settings.allowCloudModels) return false;
    if (isSensitiveOrigin(url)) return false;
    return true;
  }

  sanitizeUrl(url: string) {
    if (!this.settings.sanitizeLinkDecorations) {
      return {
        original: url,
        cleaned: url,
        removed: [] as string[],
        changed: false,
      };
    }
    return sanitizeUrlDecorations(url);
  }

  async enforceCookiePolicy(pageUrl?: string): Promise<number> {
    const cookies = await this.ports.storage.listCookies(pageUrl);
    let removed = 0;
    for (const cookie of cookies) {
      if (isWhitelisted(`https://${cookie.domain.replace(/^\./, "")}/`, this.settings.trackerWhitelist)) {
        continue;
      }
      const category =
        this.ports.storage.classifyCookie?.(cookie) ?? classifyCookie(cookie);
      if (shouldRejectCookie(category, this.settings.rejectedCookieCategories)) {
        await this.ports.storage.removeCookie(cookie);
        removed += 1;
      }
    }
    return removed;
  }
}
