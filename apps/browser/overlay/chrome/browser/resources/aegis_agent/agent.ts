// Copyright 2026 GCSA

import '/strings.m.js';

import {loadTimeData} from '//resources/js/load_time_data.js';

import type {
  CheckoutSummary,
  MonitorSummary,
  PlanSummary,
  TaskSnapshot,
  TimelineEvent,
} from './aegis_agent.mojom-webui.js';
import {AgentMode, Workflow} from './aegis_agent.mojom-webui.js';
import {BrowserProxy} from './browser_proxy.js';

const proxy = BrowserProxy.getInstance();
let snapshot: TaskSnapshot|null = null;
let selectedMode = AgentMode.kAsk;
let selectedWorkflow = Workflow.kResearch;
let busy = false;
let goalUserEdited = false;
let originsUserEdited = false;

function element<T extends HTMLElement>(id: string): T {
  const value = document.getElementById(id);
  if (!value) {
    throw new Error(`Missing element: ${id}`);
  }
  return value as T;
}

function text(id: string, key: string) {
  element(id).textContent = loadTimeData.getString(key);
}

function option(value: Workflow, label: string): HTMLOptionElement {
  const result = document.createElement('option');
  result.value = String(value);
  result.textContent = label;
  return result;
}

function renderModes() {
  const group = element('mode-group');
  group.replaceChildren();
  const modes: Array<[AgentMode, string]> = [
    [AgentMode.kAsk, 'ask'],
    [AgentMode.kAct, 'act'],
    [AgentMode.kAutomate, 'automate'],
  ];
  for (const [mode, key] of modes) {
    const button = document.createElement('button');
    button.type = 'button';
    button.role = 'radio';
    button.textContent = loadTimeData.getString(key);
    button.setAttribute('aria-checked', String(selectedMode === mode));
    button.addEventListener('click', () => {
      selectedMode = mode;
      renderModes();
    });
    group.append(button);
  }
}

function addDefinition(
    list: HTMLElement, term: string, value: string, total = false) {
  const dt = document.createElement('dt');
  dt.textContent = term;
  const dd = document.createElement('dd');
  dd.textContent = value;
  if (total) {
    dd.dataset['total'] = 'true';
  }
  list.append(dt, dd);
}

function formatMinorUnits(value: string, currency: string): string {
  const parsed = Number.parseInt(value, 10);
  return Number.isSafeInteger(parsed) && parsed >= 0 ?
      `${currency} ${(parsed / 100).toFixed(2)}` :
      `${currency} ${value}`;
}

function renderCheckoutSummary(checkout: CheckoutSummary|null) {
  const list = element('checkout-summary');
  list.hidden = !checkout;
  list.replaceChildren();
  if (!checkout) {
    return;
  }
  const amount = (value: string) =>
      formatMinorUnits(value, checkout.currency);
  addDefinition(list, loadTimeData.getString('merchant'), checkout.merchant);
  addDefinition(list, loadTimeData.getString('product'), checkout.product);
  addDefinition(
      list, loadTimeData.getString('quantity'), String(checkout.quantity));
  addDefinition(
      list, loadTimeData.getString('unitPrice'),
      amount(checkout.unitPriceMinorUnits));
  addDefinition(
      list, loadTimeData.getString('shipping'),
      amount(checkout.shippingMinorUnits));
  addDefinition(
      list, loadTimeData.getString('tax'), amount(checkout.taxMinorUnits));
  addDefinition(
      list, loadTimeData.getString('discount'),
      amount(checkout.discountMinorUnits));
  addDefinition(
      list, loadTimeData.getString('total'),
      amount(checkout.totalMinorUnits), true);
  addDefinition(
      list, loadTimeData.getString('delivery'), checkout.deliverySummary);
  addDefinition(
      list, loadTimeData.getString('returns'), checkout.returnSummary);
  addDefinition(
      list, loadTimeData.getString('sources'),
      `${checkout.sourceNodeCount} nodes · ` +
          `${checkout.observationFingerprint.slice(0, 16)}…`);
}

function renderPlan(plan: PlanSummary|null) {
  const card = element('plan-card');
  card.hidden = !plan;
  if (!plan) {
    return;
  }
  element('plan-summary').textContent = plan.summary;
  element('risk-badge').textContent = plan.maxRisk;
  const scope = element('scope-grid');
  scope.replaceChildren();
  addDefinition(scope, loadTimeData.getString('provider'),
      `${plan.provider} · ${plan.model} · ${plan.destination}`);
  addDefinition(scope, loadTimeData.getString('risk'), plan.maxRisk);
  addDefinition(scope, loadTimeData.getString('origins'), plan.origins.join(', '));
  addDefinition(scope, loadTimeData.getString('data'), plan.dataClasses.join(', '));
  addDefinition(scope, loadTimeData.getString('tools'), plan.tools.join(', '));
  addDefinition(scope, loadTimeData.getString('budget'),
      `${plan.maxToolCalls} tools · ${plan.maxModelCalls} model · ` +
      `${plan.maxNetworkRequests} network · ${plan.maxDuration}`);
  const steps = element('plan-steps');
  steps.replaceChildren();
  for (const step of plan.steps) {
    const li = document.createElement('li');
    li.textContent = step.title;
    const detail = document.createElement('small');
    detail.textContent = `${step.toolName} · ${step.risk}`;
    li.append(detail);
    steps.append(li);
  }
}

function renderTimeline(events: TimelineEvent[]) {
  const list = element('timeline');
  list.replaceChildren();
  for (const event of events) {
    const li = document.createElement('li');
    li.textContent = event.title;
    const detail = document.createElement('small');
    const timestamp = Number(event.timestamp);
    const when = Number.isFinite(timestamp) ? new Date(timestamp).toLocaleTimeString() : '';
    detail.textContent = `${event.detail}${when ? ` · ${when}` : ''}`;
    li.append(detail);
    list.append(li);
  }
}

function renderMonitors(monitors: MonitorSummary[]) {
  const list = element('monitors');
  list.replaceChildren();
  for (const monitor of monitors) {
    const li = document.createElement('li');
    const title = document.createElement('strong');
    title.textContent = `${monitor.kind} · ${monitor.paused ? 'paused' : monitor.interval}`;
    const origin = document.createElement('small');
    origin.textContent = monitor.origin;
    const hash = document.createElement('small');
    hash.textContent = `${monitor.targetHash.slice(0, 24)}… · failures ${monitor.failures}`;
    const actions = document.createElement('div');
    actions.className = 'monitor-actions';
    const toggle = document.createElement('button');
    toggle.type = 'button';
    toggle.dataset['monitorAction'] = 'toggle';
    toggle.textContent = loadTimeData.getString(
        monitor.paused ? 'resumeMonitor' : 'pauseMonitor');
    toggle.disabled = busy;
    toggle.addEventListener('click', () => withBusy(() =>
      proxy.handler.setMonitorPaused(
          monitor.taskId, monitor.monitorId, !monitor.paused)));
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.dataset['monitorAction'] = 'delete';
    remove.textContent = loadTimeData.getString('deleteMonitor');
    remove.disabled = busy;
    remove.addEventListener('click', () => withBusy(() =>
      proxy.handler.deleteMonitor(monitor.taskId, monitor.monitorId)));
    actions.append(toggle, remove);
    li.append(title, origin, hash, actions);
    list.append(li);
  }
}

function render(next: TaskSnapshot) {
  snapshot = next;
  element('status').textContent = next.state || 'idle';
  element('target-value').textContent = next.activeOrigin || loadTimeData.getString('noTarget');
  const invocation = element('invocation-context');
  invocation.hidden = !next.invocationContext;
  invocation.textContent = next.invocationContext;
  if (!next.taskId && next.suggestedGoal && !goalUserEdited) {
    element<HTMLTextAreaElement>('goal').value = next.suggestedGoal;
  }
  if (!next.taskId && next.activeOrigin && !originsUserEdited) {
    element<HTMLTextAreaElement>('origins').value = next.activeOrigin;
  }
  const banner = element('disabled-banner');
  banner.hidden = next.agentEnabled;
  banner.textContent = loadTimeData.getString('disabled');
  element<HTMLTextAreaElement>('goal').disabled = !next.agentEnabled || busy;
  element<HTMLTextAreaElement>('origins').disabled = !next.agentEnabled || busy;
  element<HTMLSelectElement>('workflow').disabled = !next.agentEnabled || busy;
  element<HTMLButtonElement>('plan-button').disabled =
      !next.agentEnabled || !next.activeTabId || busy;
  renderPlan(next.plan || null);
  renderTimeline(next.timeline);
  renderMonitors(next.monitors);
  element('empty-task').hidden = Boolean(next.timeline.length);
  element('empty-task').textContent = loadTimeData.getString('noTask');
  element('error').textContent = next.lastError;

  const approval = element('approval-card');
  approval.hidden = !next.pendingApproval;
  const approveButton = element<HTMLButtonElement>('approve-button');
  const takeoverNotice = element('takeover-notice');
  if (next.pendingApproval) {
    const takeover = next.pendingApproval.requiresUserTakeover;
    element('approval-title').textContent = loadTimeData.getString(
        takeover ? 'takeoverReady' : 'waitingApproval');
    element('approval-detail').textContent =
        `${next.pendingApproval.toolName} · ${next.pendingApproval.origin} · ` +
        next.pendingApproval.risk;
    element('approval-id').textContent = next.pendingApproval.actionId;
    element('approval-arguments').textContent =
        next.pendingApproval.argumentSummary;
    element('approval-fingerprint').textContent =
        next.pendingApproval.actionFingerprint;
    renderCheckoutSummary(next.pendingApproval.checkout || null);
    takeoverNotice.hidden = !takeover;
    takeoverNotice.textContent = takeover ?
        loadTimeData.getString('takeoverNotice') : '';
    approveButton.hidden = takeover;
  } else {
    renderCheckoutSummary(null);
    takeoverNotice.hidden = true;
    takeoverNotice.textContent = '';
    element('approval-id').textContent = '';
    element('approval-arguments').textContent = '';
    element('approval-fingerprint').textContent = '';
    approveButton.hidden = false;
  }

  const state = next.state;
  element<HTMLButtonElement>('start-button').disabled =
      busy || state !== 'awaiting_task_consent';
  element<HTMLButtonElement>('pause-button').disabled = busy || state !== 'running';
  element<HTMLButtonElement>('resume-button').disabled =
      busy || state !== 'paused_by_user';
  element<HTMLButtonElement>('takeover-button').disabled =
      busy || (state !== 'running' && state !== 'awaiting_action_approval');
  element<HTMLButtonElement>('finish-takeover-button').disabled =
      busy || state !== 'user_takeover';
  approveButton.disabled =
      busy || !next.pendingApproval ||
      next.pendingApproval.requiresUserTakeover;
  element<HTMLButtonElement>('undo-button').disabled =
      busy || !next.undoAvailable;
  element<HTMLButtonElement>('stop-button').disabled =
      busy || !next.taskId || ['completed', 'failed', 'cancelled', 'expired'].includes(state);
}

async function withBusy(action: () => Promise<{snapshot: TaskSnapshot}>) {
  if (busy) {
    return;
  }
  busy = true;
  if (snapshot) {
    render(snapshot);
  }
  try {
    const response = await action();
    render(response.snapshot);
  } finally {
    busy = false;
    if (snapshot) {
      render(snapshot);
    }
  }
}

function initializeLabels() {
  text('title', 'title');
  text('subtitle', 'subtitle');
  text('target-label', 'target');
  text('goal-label', 'goal');
  text('origins-label', 'origins');
  text('workflow-label', 'workflow');
  text('plan-button', 'plan');
  text('scope-title', 'scope');
  text('start-button', 'start');
  text('approval-title', 'waitingApproval');
  text('approval-arguments-label', 'exactArguments');
  text('approval-fingerprint-label', 'actionFingerprint');
  text('approve-button', 'approve');
  text('pause-button', 'pause');
  text('resume-button', 'resume');
  text('takeover-button', 'takeover');
  text('finish-takeover-button', 'finishTakeover');
  text('undo-button', 'undo');
  text('stop-button', 'stop');
  text('timeline-title', 'timeline');
  text('monitors-title', 'monitors');
  element<HTMLTextAreaElement>('goal').placeholder =
      loadTimeData.getString('goalPlaceholder');
  element<HTMLTextAreaElement>('origins').placeholder =
      loadTimeData.getString('originsPlaceholder');
  element<HTMLTextAreaElement>('goal').addEventListener('input', () => {
    goalUserEdited = true;
  });
  element<HTMLTextAreaElement>('origins').addEventListener('input', () => {
    originsUserEdited = true;
  });

  const select = element<HTMLSelectElement>('workflow');
  select.append(
      option(Workflow.kResearch, loadTimeData.getString('research')),
      option(Workflow.kBrowserSteward, loadTimeData.getString('steward')),
      option(Workflow.kSafeDownload, loadTimeData.getString('download')),
      option(Workflow.kShopping, loadTimeData.getString('shopping')));
  select.addEventListener('change', () => {
    selectedWorkflow = Number(select.value) as Workflow;
  });

  const quick = element('quick-actions');
  const presets: Array<[Workflow, string, string]> = [
    [Workflow.kResearch, 'research', 'Compare sources and cite conflicts'],
    [Workflow.kBrowserSteward, 'steward', 'Organize my bookmarks with a preview'],
    [Workflow.kSafeDownload, 'download', 'Find the official safe download'],
    [Workflow.kShopping, 'shopping', 'Compare total prices and prepare checkout'],
  ];
  for (const [workflow, key, prompt] of presets) {
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = loadTimeData.getString(key);
    button.addEventListener('click', () => {
      selectedWorkflow = workflow;
      select.value = String(workflow);
      element<HTMLTextAreaElement>('goal').value = prompt;
      goalUserEdited = true;
    });
    quick.append(button);
  }
  renderModes();
}

function bindActions() {
  element('plan-button').addEventListener('click', () => withBusy(async () => {
    const goal = element<HTMLTextAreaElement>('goal').value.trim();
    const origins = element<HTMLTextAreaElement>('origins').value.split('\n')
                        .map(value => value.trim())
                        .filter(value => value.length > 0);
    const created = await proxy.handler.createTask(
        goal, selectedMode, selectedWorkflow, origins);
    if (!created.snapshot.taskId) {
      return created;
    }
    return proxy.handler.requestPlan(created.snapshot.taskId);
  }));
  element('start-button').addEventListener('click', () => withBusy(() =>
    proxy.handler.consentAndRun(snapshot?.taskId || '')));
  element('pause-button').addEventListener('click', () => withBusy(() =>
    proxy.handler.pause(snapshot?.taskId || '')));
  element('resume-button').addEventListener('click', () => withBusy(() =>
    proxy.handler.resume(snapshot?.taskId || '')));
  element('takeover-button').addEventListener('click', () => withBusy(() =>
    proxy.handler.takeOver(snapshot?.taskId || '')));
  element('finish-takeover-button').addEventListener('click', () => withBusy(() =>
    proxy.handler.finishTakeOver(snapshot?.taskId || '', true)));
  element('stop-button').addEventListener('click', () => withBusy(() =>
    proxy.handler.stop(snapshot?.taskId || '')));
  element('approve-button').addEventListener('click', () => withBusy(() =>
    proxy.handler.approve(
        snapshot?.taskId || '', snapshot?.pendingApproval?.actionId || '')));
  element('undo-button').addEventListener('click', () => withBusy(() =>
    proxy.handler.undo(snapshot?.taskId || '')));
}

initializeLabels();
bindActions();
proxy.callbackRouter.onSnapshotChanged.addListener(render);
proxy.handler.getSnapshot().then(({snapshot: initial}) => {
  render(initial);
  proxy.handler.showUI();
});
