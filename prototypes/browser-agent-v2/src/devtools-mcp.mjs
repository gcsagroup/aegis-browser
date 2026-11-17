import { createRequire } from 'node:module';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const require = createRequire(import.meta.url);
const metadata = require.resolve('chrome-devtools-mcp/package.json');
const { bin } = require(metadata);
const entry = path.resolve(path.dirname(metadata), bin['chrome-devtools-mcp']);
const entryUrl = pathToFileURL(entry);
const skipBlankFlag = '--lighthouse-skip-about-blank';
const args = process.argv.slice(2);

if (args.includes(skipBlankFlag)) {
  // MCP 1.13.0 的工具尚未暴露这个 Lighthouse 选项。保留上游审计和报告流程，
  // 只省去准备阶段的 about:blank 导航。
  const { McpPage } = await import(new URL('../McpPage.js', entryUrl));
  const runNavigation = McpPage.prototype.lighthouseNavigation;
  McpPage.prototype.lighthouseNavigation = function (flags) {
    return runNavigation.call(this, { ...flags, skipAboutBlank: true });
  };
}

// 与上游使用同一进程，保持 MCP 标准输入输出和 Chromium 子进程的退出处理。
process.env.CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS = '1';
process.argv.splice(1, process.argv.length - 1, entry, '--isolated', '--no-usage-statistics',
  '--no-performance-crux', '--redact-network-headers', '--memory-debugging',
  ...args.filter(arg => arg !== skipBlankFlag));
await import(entryUrl.href);
