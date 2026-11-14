// Copyright 2026 GCSA
// Read-only account observations. Traffic admission and metering belong to the service.
export interface AccessUsageReply {
  state: 'available'|'loading'|'signed_out'|'superseded'|'unavailable';
  stale?: boolean;
  // Authoritative service decision time aged through native delivery.
  evaluatedAt?: number;
  entitlement?: {
    entitlementAccountId: string;
    status: 'active'|'exhausted'|'expired'|'not_subscribed';
    quotaBytes: string|null;
    usedBytes: string|null;
    remainingBytes: string|null;
    uploadedBytes: string|null;
    downloadedBytes: string|null;
    measuredAt: number|null;
    receivedAt: number|null;
    snapshotAgeMs: number|null;
    freshness: 'current'|'delayed'|'unavailable'|null;
    expiresAt: number|null;
    periodEnd: number|null;
    quotaSource?: '3xui_alpha';
    panelExpiryMode?: 'none'|'absolute';
    panelExpiresAt?: number|null;
  };
}

export function formatUsageBytes(raw: string|null): string {
  if (raw === null || !/^(0|[1-9]\d*)$/.test(raw)) return '—';
  const bytes = BigInt(raw);
  if (bytes > 18446744073709551615n) return '—';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB', 'EiB'];
  let divisor = 1n;
  let unit = 0;
  while (unit < units.length - 1 && bytes / divisor >= 1024n) {
    divisor *= 1024n;
    ++unit;
  }
  if (!unit) return `${raw} B`;
  const fraction = ((bytes % divisor) * 100n / divisor).toString().padStart(2, '0');
  return `${bytes / divisor}.${fraction} ${units[unit]} (${raw} B)`;
}

export function usageFreshness(
    reply: AccessUsageReply, elapsedMs: number): 'current'|'delayed'|'unavailable' {
  const data = reply.entitlement;
  if (!data || data.measuredAt === null || data.receivedAt === null ||
      data.snapshotAgeMs === null || !Number.isSafeInteger(data.measuredAt) ||
      !Number.isSafeInteger(data.receivedAt) || !Number.isSafeInteger(data.snapshotAgeMs) ||
      data.measuredAt < 0 || data.receivedAt < data.measuredAt ||
      data.snapshotAgeMs < data.receivedAt - data.measuredAt ||
      !Number.isFinite(elapsedMs) || elapsedMs < 0) return 'unavailable';
  const classify = (age: number) => age > 15000 ? 'unavailable' :
      age > 5000 ? 'delayed' : 'current';
  if (data.freshness !== classify(data.snapshotAgeMs)) return 'unavailable';
  return classify(data.snapshotAgeMs + Math.ceil(elapsedMs));
}

export function usageStatus(reply: AccessUsageReply, elapsedMs: number):
    'active'|'exhausted'|'expired'|'not_subscribed'|'unavailable' {
  const data = reply.entitlement;
  if (!data) return 'unavailable';
  if (data.status === 'not_subscribed' || data.status === 'expired') return data.status;
  const evaluated = reply.evaluatedAt;
  const end = data.periodEnd;
  const expiry = data.expiresAt;
  if (evaluated == null || end === null || expiry === null ||
      !Number.isSafeInteger(evaluated) || evaluated < 0 ||
      !Number.isSafeInteger(end) || end <= 0 ||
      !Number.isSafeInteger(expiry) || expiry <= 0 ||
      !Number.isFinite(elapsedMs) || elapsedMs < 0) return 'unavailable';
  return evaluated + Math.ceil(elapsedMs) >= Math.min(end, expiry) ?
      'expired' : data.status;
}

// One in-flight snapshot read per visible settings view. Replies from a hidden
// or detached view cannot replace its next observation.
export class AccessUsageRefresh {
  private static pendingRead_: Promise<AccessUsageReply>|null = null;
  private inFlight_ = false;
  private visible_ = false;
  private generation_ = 0;
  constructor(
      private snapshot_: () => Promise<AccessUsageReply>,
      private render_: (reply: AccessUsageReply|null, deliveryAgeMs?: number) => void,
      private isVisible_: () => boolean = () => true,
      private now_: () => number = () => performance.now(),
      private clearWhileReading_ = true) {}
  private current_(generation: number): boolean {
    if (this.visible_ && !this.isVisible_()) this.setVisible(false);
    return this.visible_ && generation === this.generation_;
  }
  setVisible(visible: boolean) {
    if (visible === this.visible_) return;
    this.visible_ = visible;
    ++this.generation_;
    this.render_(null);
    if (visible) void this.refresh();
  }
  async refresh() {
    if (!this.visible_ || this.inFlight_) return;
    this.inFlight_ = true;
    const generation = this.generation_;
    if (this.clearWhileReading_) this.render_(null);
    try {
      // Keep the native request fence across Polymer restamping. A hidden
      // waiter is discarded before it can start its own request.
      while (AccessUsageRefresh.pendingRead_) {
        try { await AccessUsageRefresh.pendingRead_; } catch {}
      }
      if (!this.current_(generation)) return;
      const started = this.now_();
      const pending = this.snapshot_();
      AccessUsageRefresh.pendingRead_ = pending;
      try {
        const reply = await pending;
        // The native snapshot is already aged through sampling. Charge the
        // full round trip of this cached read as a conservative delivery bound.
        if (this.current_(generation)) this.render_(reply, this.now_() - started);
      } finally {
        if (AccessUsageRefresh.pendingRead_ === pending) AccessUsageRefresh.pendingRead_ = null;
      }
    } catch {
      if (this.current_(generation)) {
        this.render_({state: 'unavailable'});
      }
    } finally {
      this.inFlight_ = false;
      if (this.visible_ && generation !== this.generation_) void this.refresh();
    }
  }
}

export function startAccessUsage(
    root: HTMLElement, snapshot: () => Promise<AccessUsageReply>,
    query: () => Promise<AccessUsageReply>, setVisible: (visible: boolean) => void,
    isVisible: () => boolean): () => void {
  const lang = document.documentElement.lang.toLowerCase();
  const text = (cn: string, en: string, tw = cn) =>
      lang.startsWith('zh') ? (/tw|hk|hant/.test(lang) ? tw : cn) : en;
  const put = (id: string, value: string) => {
    const element = root.querySelector<HTMLElement>(`[data-usage="${id}"]`);
    if (element && element.textContent !== value) element.textContent = value;
  };
  let last: AccessUsageReply|null = null;
  let received = 0;
  let deliveryAge = 0;
  let displayedValues = '';
  const paintObservation = (reply: AccessUsageReply, elapsed: number) => {
    if (reply.stale) {
      put('status', text('这是上次查询结果，当前额度尚未确认',
          'Last result; current balance is unconfirmed',
          '這是上次查詢結果，目前額度尚未確認'));
      put('freshness', '');
      return;
    }
    const states = {
      active: text('服务端报告：额度有效', 'Service reports available quota', '伺服器回報：額度有效'),
      exhausted: text('服务端报告：额度已耗尽', 'Service reports quota exhausted', '伺服器回報：額度已耗盡'),
      expired: text('授权已到期', 'Authorization expired', '授權已到期'),
      not_subscribed: text('尚无有效套餐', 'No active plan', '尚無有效方案'),
      unavailable: text('授权状态未确认，请刷新', 'Authorization unconfirmed; refresh usage', '授權狀態未確認，請重新整理'),
    };
    put('status', states[usageStatus(reply, elapsed)]);
    if (reply.entitlement?.status === 'not_subscribed') {
      put('freshness', '');
      return;
    }
    const freshness = usageFreshness(reply, elapsed);
    put('freshness', freshness === 'current' ? text('用量测量较新', 'Recent usage measurement', '用量測量較新') :
        freshness === 'delayed' ? text('用量同步有延迟', 'Usage synchronization delayed', '用量同步有延遲') :
        text('用量测量时间未知或数据已陈旧', 'Measurement time unknown or usage stale', '用量測量時間未知或資料已陳舊'));
  };
  const render = (reply: AccessUsageReply|null, elapsed = 0) => {
    last = reply;
    received = performance.now();
    deliveryAge = elapsed;
    put('heading', text('Access 账户额度', 'Access account usage', 'Access 帳戶額度'));
    put('refresh', text('刷新额度', 'Refresh usage', '重新整理額度'));
    put('note', text('此处只展示服务端额度快照。',
        'This view shows a read-only service quota snapshot.', '此處僅顯示伺服器額度快照。'));
    const values = root.querySelector<HTMLElement>('[data-usage="values"]');
    if (!values) return;

    if (!reply?.entitlement || (reply.state !== 'available' && !reply.stale)) {
      values.replaceChildren();
      displayedValues = '';
      put('freshness', '');
      put('status', !reply || reply.state === 'loading' ? text('正在查询额度…', 'Loading usage…', '正在查詢額度…') :
          reply.state === 'signed_out' ? text('尚未绑定额度查询账户', 'No usage account is bound', '尚未綁定額度查詢帳戶') :
          text('额度查询失败，当前余额未确认', 'Usage unavailable; current balance is unconfirmed', '額度查詢失敗，目前餘額未確認'));
      return;
    }
    const data = reply.entitlement;
    paintObservation(reply, deliveryAge);
    const key = JSON.stringify([
      data.entitlementAccountId, data.status === 'not_subscribed', data.quotaBytes,
      data.usedBytes, data.remainingBytes, data.uploadedBytes, data.downloadedBytes,
      data.measuredAt, data.receivedAt, data.expiresAt, data.quotaSource,
      data.panelExpiryMode, data.panelExpiresAt,
    ]);
    if (key === displayedValues) return;
    displayedValues = key;
    values.replaceChildren();
    const row = (label: string, value: string) => {
      const item = document.createElement('p');
      item.textContent = `${label} · ${value}`;
      values.append(item);
    };
    if (data.status === 'not_subscribed') return;
    row(text('总额度', 'Total quota', '總額度'), formatUsageBytes(data.quotaBytes));
    row(text('已用', 'Used'), formatUsageBytes(data.usedBytes));
    row(text('剩余', 'Remaining', '剩餘'), formatUsageBytes(data.remainingBytes));
    row(text('上传', 'Uploaded', '上傳'), formatUsageBytes(data.uploadedBytes));
    row(text('下载', 'Downloaded', '下載'), formatUsageBytes(data.downloadedBytes));
    const stamp = (raw: number|null|undefined) => raw == null ? '—' : new Date(raw).toLocaleString();
    row(text('服务端测量时间', 'Source measurement time', '伺服器測量時間'), stamp(data.measuredAt));
    row(text('数据接收时间', 'Source receipt time', '資料接收時間'), stamp(data.receivedAt));
    row(data.quotaSource === '3xui_alpha' ?
        text('查询授权截止', 'Query authorization expiry', '查詢授權截止') :
        text('到期时间', 'Expiry', '到期時間'), stamp(data.expiresAt));
    if (data.quotaSource === '3xui_alpha') {
      row(text('来源', 'Source', '來源'), '3X-UI Alpha');
      row(text('节点到期', 'Node expiry', '節點到期'), data.panelExpiryMode === 'none' ?
          text('未设到期', 'No expiry configured', '未設到期') : stamp(data.panelExpiresAt));
    }
  };
  const visibleNow = () => !document.hidden && isVisible();
  const refresh = new AccessUsageRefresh(
      snapshot, render, visibleNow, () => performance.now(), false);
  let visible = false;
  let manual = false;
  const button = root.querySelector<HTMLButtonElement>('[data-usage="refresh"]');
  const onRefresh = async () => {
    if (!visibleNow() || manual) return;
    manual = true;
    if (button) button.disabled = true;
    try {
      await query();
    } catch {
      // A torn-down WebUI cannot receive the reply.
    } finally {
      manual = false;
      if (button) button.disabled = false;
      if (visibleNow()) void refresh.refresh();
    }
  };
  button?.addEventListener('click', onRefresh);
  const tick = () => {
    const next = visibleNow();
    if (next !== visible) {
      visible = next;
      setVisible(visible);
      refresh.setVisible(visible);
    } else if (visible) {
      void refresh.refresh();
    }
    if (visible && last?.state === 'available' && !last.stale) {
      paintObservation(last, deliveryAge + performance.now() - received);
    }
  };
  tick();
  // Reads an already validated in-process snapshot. Network cadence is owned
  // by the Profile, including while this settings tab is closed.
  const timer = window.setInterval(tick, 1000);
  document.addEventListener('visibilitychange', tick);
  const observer = new MutationObserver(tick);
  for (let element: HTMLElement|null = root; element;) {
    observer.observe(element, {attributes: true,
      attributeFilter: ['hidden', 'hidden-by-search', 'class', 'style']});
    const tree = element.getRootNode();
    const host: Element|null = tree instanceof ShadowRoot ? tree.host : null;
    element = element.parentElement ?? (host instanceof HTMLElement ? host : null);
  }
  return () => {
    if (visible) setVisible(false);
    refresh.setVisible(false);
    window.clearInterval(timer);
    document.removeEventListener('visibilitychange', tick);
    observer.disconnect();
    button?.removeEventListener('click', onRefresh);
  };
}
