// Copyright 2026 GCSA

import '/strings.m.js';

import {loadTimeData} from '//resources/js/load_time_data.js';

import type {
  CheckoutSummary,
  MonitorSummary,
  PlanSummary,
  TaskSnapshot,
} from './aegis_agent.mojom-webui.js';
import {AgentMode, Workflow} from './aegis_agent.mojom-webui.js';
import {BrowserProxy} from './browser_proxy.js';

let proxy: BrowserProxy;
let snapshot: TaskSnapshot|null = null;
let selectedWorkflow: Workflow|null = null;
let busy = false;
let modelBusy = false;
let goalUserEdited = false;
let modelFormInitialized = false;
let autoRunTaskId = '';
let autoRunInFlight = false;
let activeView: 'task'|'automation' = 'task';
const launchParameters = new URLSearchParams(window.location.search);
const launchGoal = (launchParameters.get('goal') || '').trim().slice(0, 4096);
const launchAutoStart =
    launchParameters.get('autostart') === '1' && launchGoal.length > 0;

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

function showStartupError() {
  element('status').textContent = loadTimeData.getString('statusFailed');
  element('status').dataset['tone'] = 'danger';
  const error = element('error');
  error.textContent = loadTimeData.getString('startupError');
  error.hidden = false;
  element<HTMLButtonElement>('plan-button').disabled = true;
  element<HTMLButtonElement>('automation-view-button').disabled = true;
}

function option(value: string, label: string): HTMLOptionElement {
  const result = document.createElement('option');
  result.value = value;
  result.textContent = label;
  return result;
}

function inferWorkflow(goal: string): Workflow {
  if (/书签|書籤|收藏夹|收藏|历史记录|歷史記錄|失效链接|失效連結|链接失效|連結失效|bookmark|favorite|history|dead\s*link/iu.test(goal)) {
    return Workflow.kBrowserSteward;
  }
  if (/下载|下載|安装包|安裝包|官方版本|download|installer|release/iu.test(goal)) {
    return Workflow.kSafeDownload;
  }
  if (/购买|購買|帮我买|幫我買|买下|買下|下单|下單|结账|結帳|付款|加入购物车|加入購物車|\bbuy\b|purchase|checkout|add\s+to\s+cart/iu
          .test(goal)) {
    return Workflow.kShopping;
  }
  return Workflow.kResearch;
}

function refersToCurrentPage(goal: string): boolean {
  return /当前页|当前页面|当前网页|目前頁|目前頁面|目前網頁|这个页面|这个网页|這個頁面|這個網頁|本页面|本网页|本頁面|本網頁|页面内容|网页内容|頁面內容|網頁內容|this\s+page|current\s+page|(?:the\s+)?page\s+content/iu
      .test(goal);
}

function scheduledTaskStatus(next: TaskSnapshot): string {
  if (next.mode !== 'automate' ||
      !(next.state === 'completed' ||
        (next.state === 'running' && next.resultSummary))) {
    return '';
  }
  const monitors = next.monitors.filter(item => item.taskId === next.taskId);
  if (monitors.length === 0) {
    return '';
  }
  return monitors.every(item => item.paused) ? 'paused' : 'scheduled';
}

function hasPartialResult(next: TaskSnapshot): boolean {
  return next.resultOutcome === 'partial' || next.unfinishedItems.length > 0;
}

function statusTone(next: TaskSnapshot): string {
  if (next.state === 'failed') {
    return 'danger';
  }
  if (hasPartialResult(next) ||
      ['awaiting_action_approval', 'user_takeover', 'expired'].includes(next.state)) {
    return 'warning';
  }
  return next.state === 'completed' && next.resultOutcome === 'completed' ?
      'success' : 'neutral';
}

function humanStatus(next: TaskSnapshot): string {
  const scheduled = scheduledTaskStatus(next);
  if (scheduled) {
    return loadTimeData.getString(
        scheduled === 'paused' ? 'statusPaused' : 'statusScheduled');
  }
  const state = next.state || 'idle';
  if (state === 'idle' || state === 'draft') {
    return loadTimeData.getString('statusIdle');
  }
  if (state === 'planning' || state === 'awaiting_task_consent') {
    return loadTimeData.getString('statusPlanning');
  }
  if (['running', 'reflecting', 'verifying'].includes(state)) {
    return loadTimeData.getString('statusRunning');
  }
  if (state === 'paused_by_user') {
    return loadTimeData.getString('statusPaused');
  }
  if (state === 'recovering') {
    return loadTimeData.getString('statusRecovering');
  }
  if (state === 'cancelled' || state === 'expired') {
    return loadTimeData.getString(
        state === 'cancelled' ? 'statusCancelled' : 'statusExpired');
  }
  if (state === 'awaiting_action_approval') {
    return loadTimeData.getString('statusApproval');
  }
  if (state === 'user_takeover') {
    return loadTimeData.getString('statusTakeover');
  }
  if (state === 'completed') {
    return loadTimeData.getString(hasPartialResult(next) ? 'statusPartial' :
        next.resultOutcome === 'completed' ? 'statusCompleted' : 'statusEnded');
  }
  return loadTimeData.getString('statusFailed');
}

function renderView() {
  const taskView = element('task-view');
  const automationView = element('automation-view');
  const taskButton = element<HTMLButtonElement>('task-view-button');
  const automationButton =
      element<HTMLButtonElement>('automation-view-button');
  const taskSelected = activeView === 'task';
  taskView.hidden = !taskSelected;
  automationView.hidden = taskSelected;
  taskButton.setAttribute('aria-selected', String(taskSelected));
  automationButton.setAttribute('aria-selected', String(!taskSelected));
  taskButton.disabled = busy;
  automationButton.disabled = busy;
  element('target-card').hidden = !taskSelected;
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

function renderPlan(plan: PlanSummary|null, hasTask: boolean, state: string) {
  const card = element('plan-card');
  card.hidden = !hasTask;
  const risk = element('risk-badge');
  const details = element<HTMLDetailsElement>('plan-card')
      .querySelector<HTMLDetailsElement>('.task-details');
  if (!plan) {
    const planning = hasTask && state === 'planning';
    const failed = hasTask && state === 'failed';
    card.hidden = !planning && !failed;
    element('plan-summary').textContent =
        failed ? loadTimeData.getString('planFailed') :
        planning ? loadTimeData.getString('statusPlanning') : '';
    risk.hidden = true;
    element('scope-grid').replaceChildren();
    element('plan-steps').replaceChildren();
    if (details) {
      details.hidden = true;
    }
    return;
  }
  risk.hidden = false;
  risk.textContent = plan.maxRisk;
  element('plan-summary').textContent = plan.summary;
  if (details) {
    details.hidden = false;
  }
  const scope = element('scope-grid');
  scope.replaceChildren();
  addDefinition(
      scope, loadTimeData.getString('provider'),
      `${plan.provider} · ${plan.model} · ${plan.destination}`);
  addDefinition(scope, loadTimeData.getString('risk'), plan.maxRisk);
  addDefinition(
      scope, loadTimeData.getString('origins'), plan.origins.join(', '));
  addDefinition(
      scope, loadTimeData.getString('data'), plan.dataClasses.join(', '));
  addDefinition(
      scope, loadTimeData.getString('tools'), plan.tools.join(', '));
  addDefinition(
      scope, loadTimeData.getString('budget'),
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

function renderResult(next: TaskSnapshot) {
  const partial = hasPartialResult(next);
  const scheduled = scheduledTaskStatus(next);
  const summary = scheduled && !partial ?
      loadTimeData.getString(
          scheduled === 'paused' ? 'automationPausedHelp' :
                                   'automationScheduledHelp') :
      next.resultSummary;
  const card = element('result-card');
  card.hidden = !summary && !partial;
  card.dataset['outcome'] = partial ? 'partial' : next.resultOutcome;
  element('result-title').textContent = loadTimeData.getString(
      partial ? 'resultPartialTitle' : 'resultTitle');
  const note = element('result-partial-note');
  note.hidden = !partial;
  note.textContent = partial ? loadTimeData.getString('resultPartialHelp') : '';
  element('result-summary').textContent = summary;
  const renderItems = (groupId: string, listId: string, items: string[]) => {
    const group = element(groupId);
    const list = element(listId);
    group.hidden = items.length === 0;
    list.replaceChildren();
    for (const item of items) {
      const li = document.createElement('li');
      li.textContent = item;
      list.append(li);
    }
  };
  renderItems(
      'result-sources-group', 'result-sources', next.resultSources);
  renderItems('unfinished-group', 'unfinished-items', next.unfinishedItems);
}

function renderTimeline(next: TaskSnapshot) {
  const partial = hasPartialResult(next);
  const finished = next.resultOutcome === 'completed';
  const scheduled = scheduledTaskStatus(next);
  const monitoring = Boolean(scheduled);
  const events = next.timeline;
  element('empty-task').hidden = Boolean(events.length);
  element('empty-task').textContent = loadTimeData.getString(
      scheduled === 'paused' ? 'automationPausedHelp' :
      scheduled ? 'automationScheduledHelp' : 'noTask');
  const list = element('timeline');
  list.replaceChildren();
  const friendlyTimelineText = (value: string): string => {
    if (value.startsWith(
            'execution model did not produce required tool ')) {
      const match = value.match(/required tool ([a-z0-9._-]+)/i);
      return loadTimeData.getString('timelineRequiredToolFailed')
          .replace('$1', match?.[1] || 'browser action');
    }
    const keyByValue: {[key: string]: string} = {
      'planning': 'timelinePlanning',
      'planning started': 'timelinePlanningDetail',
      'planning repair': 'timelinePlanningRepair',
      'browser requested one bounded plan format repair':
          'timelinePlanningRepairDetail',
      'planning recovery': 'timelinePlanningRecovery',
      ['model plan format failed twice; browser kept only approved ' +
       'read-only steps']:
          'timelinePlanningRecoveryDetail',
      'awaiting_task_consent': 'timelineReady',
      'plan validated': 'timelineReadyDetail',
      'running': 'timelineRunning',
      'task consent granted': 'timelineRunningDetail',
      'verifying': 'timelineVerifying',
      'all planned actions have browser results': 'timelineVerifyingDetail',
      'completed': partial ? 'statusPartial' :
          monitoring ? 'timelineMonitorReady' :
                       finished ? 'timelineCompleted' : 'statusEnded',
      'browser verification passed': partial ? 'timelinePartialDetail' :
          monitoring ? 'timelineMonitorReadyDetail' :
                       finished ? 'timelineCompletedDetail' : 'timelineEndedDetail',
      'failed': 'timelineFailed',
      'recovering': 'statusRecovering',
      'browser restarted; external actions were not replayed':
          'timelineRestartedDetail',
      'paused_by_user': 'statusPaused',
      'cancelled': 'statusCancelled',
      'expired': 'statusExpired',
      'execution schema failed twice': 'timelineExecutionFormatFailed',
      'browser action failed after bounded retries':
          'timelineBrowserActionFailed',
      'browser rejected the action; bounded retry requested':
          'timelineBrowserActionRetry',
      'browser verified the retried action':
          'timelineBrowserActionRetrySucceeded',
      'completion evidence was rejected':
          'timelineCompletionEvidenceRejected',
      'planning stopped safely; edit the goal and retry':
          'timelineFailedDetail',
    };
    const key = keyByValue[value];
    return key ? loadTimeData.getString(key) : value;
  };
  for (const event of events) {
    const li = document.createElement('li');
    li.textContent = friendlyTimelineText(event.title);
    const detail = document.createElement('small');
    const timestamp = Number(event.timestamp);
    const when = Number.isFinite(timestamp) ?
        new Date(timestamp).toLocaleTimeString() :
        '';
    detail.textContent =
        `${friendlyTimelineText(event.detail)}${when ? ` · ${when}` : ''}`;
    li.append(detail);
    list.append(li);
  }
}

function renderMonitors(monitors: MonitorSummary[]) {
  const list = element('monitors');
  list.replaceChildren();
  element('empty-automations').hidden = monitors.length !== 0;
  element('automation-count').textContent = String(monitors.length);
  const kindLabels: {[key: string]: string} = {
    'price': loadTimeData.getString('automationPrice'),
    'inventory': loadTimeData.getString('automationInventory'),
    'page_change': loadTimeData.getString('automationPageChange'),
    'url_status': loadTimeData.getString('automationUrlStatus'),
  };
  for (const monitor of monitors) {
    const li = document.createElement('li');
    const title = document.createElement('strong');
    title.textContent = `${kindLabels[monitor.kind] || monitor.kind} · ${
        monitor.paused ? loadTimeData.getString('automationPaused') :
                         monitor.interval}`;
    const origin = document.createElement('small');
    origin.textContent = monitor.origin;
    const retention = document.createElement('small');
    retention.hidden = !monitor.sessionOnly;
    retention.textContent = `${
        loadTimeData.getString('automationSessionOnly')} · ${
        loadTimeData.getString('automationSessionOnlyHelp')}`;
    const nextRun = document.createElement('small');
    const timestamp = Number(monitor.nextRun);
    const when = Number.isFinite(timestamp) ?
        new Date(timestamp).toLocaleString() :
        '';
    nextRun.textContent = monitor.paused ?
        loadTimeData.getString('automationPausedHelp') :
        loadTimeData.getString('automationNextRun').replace('$1', when);
    const failures = document.createElement('small');
    failures.hidden = monitor.failures === 0;
    failures.textContent = loadTimeData.getString('automationFailures')
        .replace('$1', String(monitor.failures));
    const outcome = document.createElement('small');
    outcome.className = 'monitor-outcome';
    outcome.hidden = monitor.lastCheckStatus === 0;
    const status = monitor.lastCheckStatus >= 1 && monitor.lastCheckStatus <= 14 ?
        monitor.lastCheckStatus : 11;
    outcome.textContent = loadTimeData.getString(`automationCheckStatus${status}`);
    if (monitor.lastHttpStatus >= 100 && monitor.lastHttpStatus <= 599) {
      outcome.textContent += ` · HTTP ${monitor.lastHttpStatus}`;
    }
    const summary = document.createElement('p');
    summary.className = 'monitor-change-summary';
    summary.hidden = !monitor.changeSummary;
    summary.textContent = monitor.changeSummary ?
        `${loadTimeData.getString('automationChangeSummary')}：${monitor.changeSummary}` : '';
    if (monitor.changeSummary && monitor.changeSummaryPartial) {
      summary.textContent += `\n${loadTimeData.getString('automationChangeSummaryPartial')}`;
    }
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
    li.append(title, origin, retention, nextRun, outcome, summary, failures, actions);
    list.append(li);
  }
}

function renderModel(next: TaskSnapshot) {
  const details = element<HTMLDetailsElement>('model-details');
  const provider = element<HTMLSelectElement>('model-provider');
  const baseUrl = element<HTMLInputElement>('model-base-url');
  const model = element<HTMLInputElement>('model-name');
  if (!modelFormInitialized) {
    provider.value = next.modelConfigured ? next.modelProvider : 'openai';
    baseUrl.value = next.modelConfigured ?
        next.modelBaseUrl :
        'http://127.0.0.1:8000/v1';
    model.value = next.modelConfigured ? next.modelName : '';
    modelFormInitialized = true;
  }
  if (!next.modelConfigured) {
    details.open = true;
  }
  element('model-state').textContent = next.modelConfigured ?
      `${loadTimeData.getString('modelReady')} · ${next.modelName}` :
      loadTimeData.getString('modelMissing');
  provider.disabled = modelBusy;
  baseUrl.disabled = modelBusy;
  model.disabled = modelBusy;
  element<HTMLSelectElement>('model-options').disabled = modelBusy;
  element<HTMLInputElement>('model-api-key').disabled = modelBusy;
  element<HTMLButtonElement>('detect-models-button').disabled = modelBusy;
  element<HTMLButtonElement>('save-model-button').disabled = modelBusy;
}

function friendlyError(error: string, hasPlan: boolean): string {
  if (!error) {
    return '';
  }
  if (error.includes('Configure a valid Agent model')) {
    return loadTimeData.getString('modelMissing');
  }
  if (error.includes('invalid agent model configuration') ||
      error.includes('model configuration is invalid')) {
    return loadTimeData.getString('modelConfigurationError');
  }
  if (error.includes('related page could not be opened')) {
    return loadTimeData.getString('relatedPageOpenError');
  }
  if (error.includes('execution stopped because browser context changed')) {
    return loadTimeData.getString('pageContextUnavailableError');
  }
  if (error.includes('current public page is unavailable')) {
    return loadTimeData.getString('currentPageUnavailableError');
  }
  if (error.includes('Task input is invalid')) {
    return loadTimeData.getString('taskInputError');
  }
  if (error.includes('URL check requires 1 to 100 bookmark node ids') ||
      error.includes('network budget exhausted during URL check')) {
    return loadTimeData.getString('bookmarkUrlLimitError');
  }
  if (error.includes(
          'bookmark node is invalid, duplicated, or not HTTP')) {
    return loadTimeData.getString('bookmarkUrlSafetyError');
  }
  if (error.includes('scheduled automation plan') ||
      error.includes('monitor.create requires a scheduled automation')) {
    return loadTimeData.getString('automationPlanError');
  }
  if (error.includes('monitor schedule is invalid')) {
    return loadTimeData.getString('taskInputError');
  }
  if (error.includes('monitor target is unavailable') ||
      error.includes('monitor creation requires Automate mode')) {
    return loadTimeData.getString('automationTargetError');
  }
  if (error.includes('monitor could not be scheduled') ||
      error.includes('secure monitor target storage is unavailable')) {
    return loadTimeData.getString('automationRuntimeError');
  }
  if (error.includes('goal route') ||
      error.includes('browser goal') ||
      error.includes('goal is being understood') ||
      error.includes('selected a browser target')) {
    return loadTimeData.getString('goalRoutingError');
  }
  if (error.includes('browser-approved scope') ||
      error.includes('bind the plan to its approved scope')) {
    return loadTimeData.getString('planningScopeError');
  }
  if (error.includes('execution model did not produce required tool ')) {
    const match = error.match(/required tool ([a-z0-9._-]+)/i);
    if (match?.[1] === 'agent.complete') {
      return loadTimeData.getString('executionCompletionError');
    }
    return loadTimeData.getString('executionRequiredToolError')
        .replace('$1', match?.[1] || 'browser action');
  }
  if (hasPlan &&
      (error.includes('structured-tool contract') ||
       error.includes('tool argument') ||
       error.includes('execution schema') ||
       error.includes('model execution response') ||
       error.includes('browser-selected tool') ||
       error.includes('more than one tool call'))) {
    return loadTimeData.getString('executionFormatError');
  }
  if (error.includes('structured-tool contract') ||
      error.includes('native task plan') ||
      error.includes('tool argument') ||
      error.includes('task plan')) {
    return loadTimeData.getString('planningFormatError');
  }
  if (error.includes('execution schema') ||
      error.includes('model execution response') ||
      error.includes('browser-selected tool') ||
      error.includes('more than one tool call')) {
    return loadTimeData.getString('executionFormatError');
  }
  return loadTimeData.getString(
      hasPlan ? 'executionGenericError' : 'planningGenericError');
}

function friendlyModelError(error: string): string {
  if (error.includes('invalid') || error.includes('unsupported')) {
    return loadTimeData.getString('modelConfigurationError');
  }
  return loadTimeData.getString('modelConnectionError');
}

function maybeAutoRun(next: TaskSnapshot) {
  if (autoRunTaskId && next.taskId === autoRunTaskId &&
      next.state === 'awaiting_task_consent' && !autoRunInFlight) {
    autoRunInFlight = true;
    proxy.handler.consentAndRun(next.taskId)
        .then(({snapshot: updated}) => render(updated))
        .finally(() => {
          autoRunInFlight = false;
        });
  }
  if (next.taskId === autoRunTaskId &&
      ['completed', 'failed', 'cancelled', 'expired'].includes(next.state)) {
    autoRunTaskId = '';
  }
}

function render(next: TaskSnapshot) {
  snapshot = next;
  element('status').dataset['tone'] = statusTone(next);
  element('status').textContent = busy && !next.taskId ?
      loadTimeData.getString('statusUnderstanding') :
      humanStatus(next);
  const goal = element<HTMLTextAreaElement>('goal');
  element('target-value').textContent =
      refersToCurrentPage(goal.value) && next.activeOrigin ?
      next.activeOrigin :
      loadTimeData.getString('noTarget');
  const invocation = element('invocation-context');
  invocation.hidden = !next.invocationContext;
  invocation.textContent = next.invocationContext;
  if (!next.taskId && next.suggestedGoal && !goalUserEdited) {
    goal.value = next.suggestedGoal;
  }

  const banner = element('disabled-banner');
  banner.hidden = next.agentEnabled;
  banner.textContent = loadTimeData.getString('disabled');

  goal.disabled = busy;
  const automationGoal = element<HTMLTextAreaElement>('automation-goal');
  automationGoal.disabled = busy;
  element<HTMLSelectElement>('automation-schedule').disabled = busy;
  element<HTMLButtonElement>('plan-button').disabled =
      busy || !next.modelConfigured || !goal.value.trim();
  element<HTMLButtonElement>('create-automation-button').disabled =
      busy || !next.modelConfigured || !automationGoal.value.trim();
  renderView();
  renderModel(next);
  renderPlan(next.plan || null, Boolean(next.taskId), next.state);
  renderResult(next);
  renderTimeline(next);
  renderMonitors(next.monitors);
  const error = element('error');
  error.textContent = friendlyError(next.lastError, Boolean(next.plan));
  error.hidden = !error.textContent;
  const technicalErrorGroup = element('technical-error-group');
  element('technical-error-label').textContent =
      loadTimeData.getString('technicalErrorLabel');
  element('technical-error').textContent = next.lastError;
  technicalErrorGroup.hidden = !next.lastError || !next.plan;

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
        loadTimeData.getString('takeoverNotice') :
        '';
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
  element<HTMLButtonElement>('start-button').disabled = true;
  element<HTMLButtonElement>('pause-button').disabled =
      busy || state !== 'running';
  element<HTMLButtonElement>('resume-button').disabled =
      busy || state !== 'paused_by_user';
  element<HTMLButtonElement>('takeover-button').disabled =
      busy || (state !== 'running' &&
               state !== 'awaiting_action_approval');
  element<HTMLButtonElement>('finish-takeover-button').disabled =
      busy || state !== 'user_takeover';
  approveButton.disabled =
      busy || !next.pendingApproval ||
      next.pendingApproval.requiresUserTakeover;
  element<HTMLButtonElement>('undo-button').disabled =
      busy || !next.undoAvailable;
  element<HTMLButtonElement>('stop-button').disabled =
      busy || !next.taskId ||
      ['completed', 'failed', 'cancelled', 'expired'].includes(state);
  document.querySelector<HTMLElement>('.controls')!.hidden =
      !next.taskId || Boolean(scheduledTaskStatus(next));
  document.querySelector<HTMLElement>('.activity-card')!.hidden = !next.taskId;
  maybeAutoRun(next);
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
  text('task-view-button', 'taskWorkspace');
  text('automation-view-button', 'automationWorkspace');
  text('target-label', 'target');
  text('goal-label', 'goal');
  text('simple-help', 'simpleHelp');
  text('plan-button', 'plan');
  text('automation-title', 'automationTitle');
  text('automation-help', 'automationHelp');
  text('automation-goal-label', 'automationGoal');
  text('schedule-label', 'scheduleLabel');
  text('schedule-help', 'scheduleHelp');
  text('create-automation-button', 'createAutomation');
  text('automations-title', 'automationsTitle');
  text('empty-automations', 'emptyAutomations');
  text('scope-title', 'scope');
  text('details-label', 'details');
  text('result-title', 'resultTitle');
  text('result-sources-label', 'resultSources');
  text('unfinished-label', 'unfinishedItems');
  text('start-button', 'start');
  text('model-settings-label', 'modelSettings');
  text('model-hint', 'modelHint');
  text('provider-label', 'providerLabel');
  text('base-url-label', 'baseUrlLabel');
  text('model-name-label', 'modelNameLabel');
  text('api-key-label', 'apiKeyLabel');
  text('detect-models-button', 'detectModels');
  text('save-model-button', 'saveModel');
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
  element<HTMLTextAreaElement>('goal').placeholder =
      loadTimeData.getString('goalPlaceholder');
  element<HTMLTextAreaElement>('automation-goal').placeholder =
      loadTimeData.getString('automationGoalPlaceholder');

  const goal = element<HTMLTextAreaElement>('goal');
  if (launchGoal) {
    goal.value = launchGoal;
    goalUserEdited = true;
  }
  if (launchParameters.get('view') === 'automation') {
    activeView = 'automation';
  }
  goal.addEventListener('input', () => {
    selectedWorkflow = null;
    goalUserEdited = true;
    if (snapshot) {
      render(snapshot);
    }
  });

  const quick = element('quick-actions');
  const presets: Array<[Workflow, string, string]> = [
    [Workflow.kResearch, 'quickSummary', 'quickSummaryGoal'],
    [Workflow.kResearch, 'quickResearch', 'quickResearchGoal'],
    [Workflow.kBrowserSteward, 'quickSteward', 'quickStewardGoal'],
    [Workflow.kBrowserSteward, 'quickUrlCheck', 'quickUrlCheckGoal'],
    [Workflow.kSafeDownload, 'quickDownload', 'quickDownloadGoal'],
    [Workflow.kResearch, 'quickGather', 'quickGatherGoal'],
  ];
  for (const [workflow, labelKey, goalKey] of presets) {
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = loadTimeData.getString(labelKey);
    button.addEventListener('click', () => {
      selectedWorkflow = workflow;
      goal.value = loadTimeData.getString(goalKey);
      goalUserEdited = true;
      if (snapshot) {
        render(snapshot);
      }
    });
    quick.append(button);
  }

  const automationGoal = element<HTMLTextAreaElement>('automation-goal');
  const automationPresets: Array<[string, string]> = [
    ['automationPrice', 'automationPriceGoal'],
    ['automationInventory', 'automationInventoryGoal'],
    ['automationPageChange', 'automationPageChangeGoal'],
    ['automationUrlStatus', 'automationUrlStatusGoal'],
  ];
  for (const [labelKey, goalKey] of automationPresets) {
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = loadTimeData.getString(labelKey);
    button.addEventListener('click', () => {
      automationGoal.value = loadTimeData.getString(goalKey);
      if (snapshot) {
        render(snapshot);
      }
    });
    element('automation-presets').append(button);
  }
  automationGoal.addEventListener('input', () => {
    if (snapshot) {
      render(snapshot);
    }
  });

  const schedule = element<HTMLSelectElement>('automation-schedule');
  schedule.append(
      option('15', loadTimeData.getString('schedule15Minutes')),
      option('60', loadTimeData.getString('scheduleHourly')),
      option('360', loadTimeData.getString('schedule6Hours')),
      option('1440', loadTimeData.getString('scheduleDaily')),
      option('10080', loadTimeData.getString('scheduleWeekly')));
  schedule.value = '60';

  element('task-view-button').addEventListener('click', () => {
    activeView = 'task';
    renderView();
  });
  element('automation-view-button').addEventListener('click', () => {
    activeView = 'automation';
    renderView();
  });
  renderView();
}

function resetDetectedModels() {
  element<HTMLSelectElement>('model-options').replaceChildren();
  element('model-options').hidden = true;
  element('model-options-label').hidden = true;
  element('model-feedback').textContent = '';
}

function selectDetectedModel() {
  const selected = element<HTMLSelectElement>('model-options').value;
  if (selected) {
    element<HTMLInputElement>('model-name').value = selected;
  }
}

function syncDetectedModel() {
  element<HTMLSelectElement>('model-options').value =
      element<HTMLInputElement>('model-name').value;
}

async function detectModels() {
  if (modelBusy) {
    return;
  }
  modelBusy = true;
  resetDetectedModels();
  if (snapshot) {
    render(snapshot);
  }
  try {
    const response = await proxy.handler.listModels(
        element<HTMLSelectElement>('model-provider').value,
        element<HTMLInputElement>('model-base-url').value.trim(),
        element<HTMLInputElement>('model-api-key').value.trim());
    if (!response.ok) {
      element('model-feedback').textContent =
          friendlyModelError(response.error);
      return;
    }
    // 侧栏中的 datalist 弹窗未能展开；独立选择框也不会按旧模型名过滤候选。
    const options = element<HTMLSelectElement>('model-options');
    for (const name of response.models) {
      options.append(option(name, name));
    }
    const model = element<HTMLInputElement>('model-name');
    if (response.models.length && !model.value) {
      model.value = response.models[0]!;
    }
    syncDetectedModel();
    options.hidden = !response.models.length;
    const label = element('model-options-label');
    label.hidden = options.hidden;
    label.textContent = loadTimeData.getString('modelDetected');
    element('model-feedback').textContent =
        response.models.length ?
        `${loadTimeData.getString('modelDetected')} (${response.models.length}) · ${new Date().toLocaleTimeString()}` :
        `${loadTimeData.getString('detectModels')}: 0`;
  } catch {
    element('model-feedback').textContent =
        loadTimeData.getString('modelConnectionError');
  } finally {
    modelBusy = false;
    if (snapshot) {
      render(snapshot);
    }
  }
}

function showModelSaveError(error: string) {
  const key = error.includes('invalid') || error.includes('unsupported') ?
      'modelConfigurationError' :
      error.includes('credential') || error.includes('encrypt') ?
      'modelStorageError' : 'modelSaveError';
  element('model-feedback').textContent = loadTimeData.getString(key);
  element<HTMLDetailsElement>('model-details').open = true;
}

async function saveModel() {
  if (modelBusy) {
    return;
  }
  modelBusy = true;
  element('model-feedback').textContent = '';
  if (snapshot) {
    render(snapshot);
  }
  try {
    const response = await proxy.handler.configureModel(
        element<HTMLSelectElement>('model-provider').value,
        element<HTMLInputElement>('model-base-url').value.trim(),
        element<HTMLInputElement>('model-name').value.trim(),
        element<HTMLInputElement>('model-api-key').value.trim(), false);
    // 旧连接仍有效不代表这次保存成功；失败时保留非敏感草稿供用户修正。
    const saved = response.snapshot.modelConfigured &&
        !response.snapshot.lastError;
    if (saved) {
      modelFormInitialized = false;
    }
    render(response.snapshot);
    if (saved) {
      element('model-feedback').textContent =
          loadTimeData.getString('modelSaved');
      element<HTMLDetailsElement>('model-details').open = false;
    } else {
      showModelSaveError(response.snapshot.lastError);
    }
  } catch {
    // 响应中断时不能确认保存结果，也不向页面输出原始错误或密钥。
    showModelSaveError('');
  } finally {
    element<HTMLInputElement>('model-api-key').value = '';
    modelBusy = false;
    if (snapshot) {
      render(snapshot);
    }
  }
}

function bindActions() {
  element('plan-button').addEventListener('click', () => withBusy(async () => {
    const goal = element<HTMLTextAreaElement>('goal').value.trim();
    const workflow = selectedWorkflow ?? inferWorkflow(goal);
    const created = await proxy.handler.createTask(
        goal, AgentMode.kAct, workflow, [], 0);
    if (!created.snapshot.taskId) {
      return created;
    }
    autoRunTaskId = created.snapshot.taskId;
    return proxy.handler.requestPlan(created.snapshot.taskId);
  }));
  element('create-automation-button').addEventListener(
      'click', () => withBusy(async () => {
        const goal =
            element<HTMLTextAreaElement>('automation-goal').value.trim();
        const interval =
            Number(element<HTMLSelectElement>('automation-schedule').value);
        // 自动化从读取目标开始；禁止下载、购物等语句不能选择一次性操作模板。
        // 缺少明确来源时仍由模型理解目标，最终权限由原生自动化范围约束。
        const created = await proxy.handler.createTask(
            goal, AgentMode.kAutomate, Workflow.kResearch, [], interval);
        if (!created.snapshot.taskId) {
          return created;
        }
        autoRunTaskId = created.snapshot.taskId;
        return proxy.handler.requestPlan(created.snapshot.taskId);
      }));
  element('detect-models-button').addEventListener('click', detectModels);
  element('model-options').addEventListener('change', selectDetectedModel);
  element('model-name').addEventListener('input', syncDetectedModel);
  element('model-base-url').addEventListener('input', resetDetectedModels);
  element('model-api-key').addEventListener('input', resetDetectedModels);
  element('save-model-button').addEventListener('click', saveModel);
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
  element('model-provider').addEventListener('change', () => {
    const provider = element<HTMLSelectElement>('model-provider').value;
    const baseUrl = element<HTMLInputElement>('model-base-url');
    baseUrl.value = provider === 'openai' ?
        'http://127.0.0.1:8000/v1' :
        provider === 'anthropic' ?
        'https://api.anthropic.com/v1' :
        'https://generativelanguage.googleapis.com/v1beta';
    element<HTMLInputElement>('model-name').value = '';
    resetDetectedModels();
  });
}

initializeLabels();
try {
  proxy = BrowserProxy.getInstance();
  bindActions();
  proxy.callbackRouter.onSnapshotChanged.addListener(render);
  proxy.handler.getSnapshot().then(({snapshot: initial}) => {
    render(initial);
    proxy.handler.showUI();
    // A launcher invocation always represents a new user request. Do not let a
    // completed (or otherwise retained) previous task silently suppress it.
    if (launchAutoStart && initial.modelConfigured) {
      element<HTMLButtonElement>('plan-button').click();
    }
  }).catch(showStartupError);
} catch {
  showStartupError();
}
