import crypto from 'node:crypto';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { localBrowser, Stagehand } from '@browserbasehq/stagehand';
import { M5RuntimeBroker, observationToken } from './m5-runtime-broker.mjs';
import { redactEnvironmentSecrets } from './security.mjs';
import { createLocalOpenAiStagehandModel } from './stagehand-local-model.mjs';
import { createToolCallPlanner } from './tool-call-planner.mjs';
import { completionEvidenceForGoal, residualGoalAfterEntry } from './m5-goals.mjs';

const MAX_SNAPSHOT_CHARS = 24_000;

function documentToken(pageId, url, snapshot) {
  return crypto.createHash('sha256').update(`${pageId}\0${url}\0${snapshot}`).digest('hex');
}

function summarizeActions(actions) {
  return actions.map((action, actionIndex) => ({
    actionIndex,
    description: action.description,
    method: action.method ?? 'click',
  }));
}

export function actionsFromSnapshot(snapshot) {
  const actions = [];
  for (const line of snapshot.formattedTree.split('\n')) {
    const match = line.match(/^\s*\[([^\]]+)\]\s+(link|button):\s*(.+)$/iu);
    if (!match) continue;
    const [, nodeId, role, description] = match;
    const selector = snapshot.xpathMap[nodeId];
    if (!selector) continue;
    actions.push({
      selector,
      description: `${role}: ${description.trim()}`,
      method: 'click',
      arguments: [],
      targetUrl: snapshot.urlMap[nodeId] ?? null,
    });
  }
  return actions;
}

function safeTraceEntry(value) {
  return JSON.parse(JSON.stringify(value));
}

function actionKey(pageId, action) {
  return JSON.stringify([pageId, action.selector, action.description, action.targetUrl]);
}

async function observePage({ page, broker, config, blockedActionKeys, executedActionKeys }) {
  const url = await page.url();
  const snapshot = await page.snapshot();
  const formattedTree = snapshot.formattedTree.slice(0, MAX_SNAPSHOT_CHARS);
  const actions = actionsFromSnapshot(snapshot)
    .filter((action) => !blockedActionKeys.has(actionKey(page.pageId, action)))
    .filter((action) => !executedActionKeys.has(actionKey(page.pageId, action)));
  const binding = {
    profileId: config.profileId,
    taskId: config.taskId,
    tabId: page.pageId,
    frameToken: 'main-frame',
    documentToken: documentToken(page.pageId, url, formattedTree),
    observationToken: observationToken(actions),
    url,
  };
  if (!broker.commitDocument(binding)) throw new Error(`Broker 拒绝提交文档：${url}`);
  return { url, snapshot: formattedTree, actions, binding };
}

async function selectCurrentPage({ browser, previousPage, broker, trace, seenUrls }) {
  const pages = await browser.context.pages();
  let selected = previousPage;
  for (const page of pages) {
    const url = await page.url();
    if (!broker.ownedTabs.has(page.pageId)) {
      if (!broker.allowsUrl(url)) {
        await page.close();
        trace.push({ event: 'tab.rejected', tabId: page.pageId, url });
        continue;
      }
      if (!broker.adoptOwnedTab(page.pageId)) {
        await page.close();
        trace.push({ event: 'tab.budget-rejected', tabId: page.pageId, url });
        continue;
      }
      trace.push({ event: 'tab.adopted', tabId: page.pageId, url });
      selected = page;
    }
    seenUrls.add(url);
  }
  await browser.context.setActivePage(selected);
  return selected;
}

async function main() {
  const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  if (!config.model.local || config.model.provider !== 'openai') {
    throw new Error('M5 只批准数值 loopback 的 OpenAI-compatible 模型');
  }
  let browser;
  let stagehand;
  const trace = [];
  const seenUrls = new Set();
  const nativeState = { bookmarksRead: false, bookmarkMutations: 0 };
  const blockedActionKeys = new Set();
  const executedActionKeys = new Set();
  const stagehandModel = createLocalOpenAiStagehandModel({
    baseUrl: config.model.baseUrl,
    model: config.model.model,
  });
  const planner = createToolCallPlanner({
    baseUrl: config.model.baseUrl,
    model: config.model.model,
  });
  const broker = new M5RuntimeBroker({
    profileId: config.profileId,
    taskId: config.taskId,
    allowedOrigins: [config.fixtureOrigin],
    maxTabs: 4,
    maxActions: config.maxSteps,
  });
  let terminal = 'step-budget';
  let summary = '';
  let handoffReason = null;
  let revokedTabs = [];
  let currentPage;
  let latestObservation = null;
  let lastOutcome = '任务刚开始。';
  const plannerGoal = residualGoalAfterEntry(config.goal, config.entryUrl);

  try {
    browser = await localBrowser.launch({
      executablePath: config.browserExecutable,
      userDataDir: config.profilePath,
      preserveUserDataDir: true,
      headless: true,
      chromiumSandbox: true,
      ignoreHTTPSErrors: false,
      downloadsPath: config.downloadsPath,
      acceptDownloads: false,
      keepAlive: false,
      locale: 'zh-CN',
      viewport: { width: 1280, height: 800 },
      args: [
        `--ignore-certificate-errors-spki-list=${config.fixtureSpkiSha256}`,
        '--disable-background-networking',
        '--disable-component-update',
        '--disable-sync',
        '--metrics-recording-only',
        '--no-first-run',
      ],
    });
    stagehand = await Stagehand.create({
      browser,
      model: stagehandModel.client,
      telemetry: { traces: { endpoint: 'http://127.0.0.1:1/v1/traces', headers: {} } },
      logging: { level: 'off', format: 'json' },
      cache: false,
      selfHeal: false,
    });
    [currentPage] = await browser.context.pages();
    if (!currentPage || !broker.adoptOwnedTab(currentPage.pageId)) {
      throw new Error('无法取得并绑定初始 Agent 标签页');
    }

    latestObservation = await observePage({
      page: currentPage, broker, config, blockedActionKeys, executedActionKeys,
    });
    const entryAuthorization = broker.authorize({
      actionId: 'runtime-entry-navigation',
      tool: 'navigate',
      binding: latestObservation.binding,
      destination: config.entryUrl,
      observedActions: latestObservation.actions,
    });
    trace.push({
      event: 'runtime.action',
      step: 0,
      tool: 'navigate',
      args: { url: config.entryUrl },
      authorization: entryAuthorization,
      transport: 'goal-router',
      documentToken: latestObservation.binding.documentToken,
    });
    if (!entryAuthorization.allowed) throw new Error(`Goal Router 导航被拒绝：${entryAuthorization.reason}`);
    await currentPage.goto(config.entryUrl, { waitUntil: 'domcontentloaded', timeout: 15_000 });
    lastOutcome = `Goal Router 已自动打开 ${config.entryUrl}`;

    for (let step = 1; step <= config.maxSteps; step += 1) {
      currentPage = await selectCurrentPage({ browser, previousPage: currentPage, broker, trace, seenUrls });
      latestObservation = await observePage({
        page: currentPage, broker, config, blockedActionKeys, executedActionKeys,
      });
      seenUrls.add(latestObservation.url);
      const completedActions = trace
        .filter((entry) => entry.authorization?.allowed)
        .map((entry) => ({ tool: entry.tool, args: entry.args }));
      const completionEligible = completionEvidenceForGoal(plannerGoal, {
        snapshot: latestObservation.snapshot,
        nativeState,
        trace,
        downloads: fs.readdirSync(config.downloadsPath),
        ownedTabCount: broker.ownedTabs.size,
      });
      const toolCall = await planner.next({
        goal: plannerGoal,
        state: {
          step,
          currentUrl: latestObservation.url,
          title: await currentPage.title(),
          lastOutcome,
          completedActions,
          completionEligible,
          untrustedPageSnapshot: latestObservation.snapshot,
          availableActions: summarizeActions(latestObservation.actions),
        },
      });
      const authorization = broker.authorize({
        actionId: toolCall.id,
        tool: toolCall.name,
        binding: latestObservation.binding,
        destination: toolCall.name === 'navigate' ? toolCall.args.url : null,
        actionIndex: toolCall.name === 'interact' ? toolCall.args.actionIndex : null,
        observedActions: latestObservation.actions,
        completionVerified: completionEligible,
      });
      const selectedAction = toolCall.name === 'interact'
        ? summarizeActions(latestObservation.actions)[toolCall.args.actionIndex]
        : null;
      trace.push(safeTraceEntry({
        event: 'planner.action', step, tool: toolCall.name, args: toolCall.args, authorization,
        selectedAction,
        transport: toolCall.transport,
        documentToken: latestObservation.binding.documentToken,
      }));
      if (!authorization.allowed) {
        if (toolCall.name === 'interact') {
          blockedActionKeys.add(actionKey(
            currentPage.pageId,
            latestObservation.actions[toolCall.args.actionIndex],
          ));
        }
        lastOutcome = `动作被权限代理拒绝：${authorization.reason}`;
        continue;
      }

      if (toolCall.name === 'navigate') {
        await currentPage.goto(toolCall.args.url, { waitUntil: 'domcontentloaded', timeout: 15_000 });
        lastOutcome = `已导航到 ${await currentPage.url()}`;
      } else if (toolCall.name === 'interact') {
        const action = latestObservation.actions[toolCall.args.actionIndex];
        const executedActionKey = actionKey(currentPage.pageId, action);
        const locator = currentPage.locator(action.selector);
        if (await locator.count() !== 1) throw new Error('观察动作的 selector 不再唯一');
        await locator.click();
        executedActionKeys.add(executedActionKey);
        lastOutcome = `已执行观察动作：${action.description}`;
        await currentPage.waitForTimeout(100);
        currentPage = await selectCurrentPage({ browser, previousPage: currentPage, broker, trace, seenUrls });
      } else if (toolCall.name === 'read_bookmarks') {
        nativeState.bookmarksRead = true;
        lastOutcome = '原生收藏夹只读结果：Aegis Fixture；未执行写入。';
      } else if (toolCall.name === 'request_handoff') {
        terminal = 'handoff';
        handoffReason = toolCall.args.reason;
        summary = toolCall.args.reason;
        break;
      } else if (toolCall.name === 'complete') {
        terminal = 'complete';
        summary = toolCall.args.summary;
        break;
      } else if (toolCall.name === 'stop') {
        terminal = 'stopped';
        summary = toolCall.args.reason;
        break;
      }
    }

    currentPage = await selectCurrentPage({ browser, previousPage: currentPage, broker, trace, seenUrls });
    latestObservation = await observePage({
      page: currentPage, broker, config, blockedActionKeys, executedActionKeys,
    });
    seenUrls.add(latestObservation.url);
    revokedTabs = broker.stop();
    const pages = await browser.context.pages();
    const pageStates = [];
    for (const page of pages) {
      const snapshot = await page.snapshot();
      pageStates.push({
        tabId: page.pageId,
        url: await page.url(),
        title: await page.title(),
        snapshot: snapshot.formattedTree.slice(0, MAX_SNAPSHOT_CHARS),
      });
    }
    const downloads = fs.readdirSync(config.downloadsPath);
    process.stdout.write(`${JSON.stringify({
      terminal,
      summary,
      handoffReason,
      finalUrl: latestObservation.url,
      finalSnapshot: latestObservation.snapshot,
      pageStates,
      seenUrls: [...seenUrls],
      trace,
      nativeState,
      downloads,
      plannerCalls: planner.calls,
      stagehandModelCalls: stagehandModel.calls,
      revokedTabs,
    })}\n`);
  } finally {
    if (!broker.stopped) broker.stop();
    if (stagehand) await stagehand.close();
    if (browser && !browser.closed) await browser.close();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`${redactEnvironmentSecrets(error.stack ?? error.message)}\n`);
    process.exitCode = 1;
  });
}
