import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

// 从共用规则生成 WebKit 内容规则，避免各平台维护不同的域名清单。
// 独立命令固定到仓库根目录；文件路径不接受命令行或环境变量输入。
process.chdir(fileURLToPath(new URL('../../../', import.meta.url)));
const source = fs.readFileSync('packages/core/src/tracker/builtin-rules.ts', 'utf8');
const block = source.match(/BUILTIN_TRACKER_HOSTS\s*=\s*\[([\s\S]*?)\]\s*as const/);
if (!block) throw new Error('找不到共用跟踪域名清单');
const hosts = [...block[1].matchAll(/"([^"\n]+)"/g)].map(match => match[1]);
if (!hosts.length || hosts.some(host => !/^[a-z0-9./-]+$/.test(host))) throw new Error('跟踪规则格式异常');
const rules = hosts.map(entry => {
  const [host, ...parts] = entry.split('/');
  const escaped = host.replaceAll('.', '\\.');
  // WebKit 使用受限正则语法，不能用 alternation；网络 URL 的 host 后总有斜线或端口。
  const suffix = parts.length ? `/${parts.join('/')}([/?].*)?$` : '[/:]';
  return {
    trigger: {
      'url-filter': `^https?://([^/]+\\.)?${escaped}${suffix}`,
      'resource-type': ['script', 'image', 'raw', 'media', 'font', 'svg-document', 'ping'],
      'load-type': ['third-party'],
    },
    action: { type: 'block' },
  };
});
const text = `${JSON.stringify(rules, null, 2)}\n`;
if (process.argv.includes('--check')) {
  if (fs.readFileSync('apps/ios/BrowserKit/Resources/tracker-rules.json', 'utf8') !== text) throw new Error('iOS 规则未与共用清单同步，请重新生成');
} else {
  fs.mkdirSync('apps/ios/BrowserKit/Resources', { recursive: true });
  fs.writeFileSync('apps/ios/BrowserKit/Resources/tracker-rules.json', text);
}
console.log(`IOS_TRACKER_RULES=PASS count=${rules.length}`);
