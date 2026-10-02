// 补齐验收前置的第二版合成数据；与历史任务目录分开，不回填旧结果。
const linkCases = [
  ['live', 'live'], ['head-unsupported', 'live'], ['redirect', 'redirect'],
  ['auth', 'auth_required'], ['rate', 'rate_limited'],
  ['gone', 'permanent_http_error'], ['missing', 'permanent_http_error'],
  ['temporary', 'temporary_http_error'], ['timeout', 'timeout'],
  ['out-of-scope', 'scope_blocked'],
];

export function readinessLinks(origin) {
  const url = new URL(origin);
  if (!['http:', 'https:'].includes(url.protocol) || url.origin !== origin ||
      url.username || url.password) throw new Error('夹具地址必须是无凭据的HTTP(S)来源');
  return Array.from({length: 500}, (_, index) => {
    const [kind, classification] = linkCases[index % linkCases.length];
    return {index: index + 1, kind, expectedClassification: classification,
      url: kind === 'out-of-scope' ?
          `file:///aegis-fixture/not-a-real-file-${index + 1}` :
          `${origin}/status/${kind}?bookmark=${index + 1}`};
  });
}

export function renderReadinessForm() {
  // 独立资料输入演示，不模仿登录、付款或品牌页面；值仍有真实敏感字段语义。
  // 无提交按钮、脚本或外部目标，不能靠删掉敏感字段来获得空泛通过。
  return `<article><h1>合成资料输入样例</h1>
    <p>此页演示资料输入控件，仅使用虚构测试值。只介绍用途，不读取任何输入值。</p>
    <fieldset><legend>本地演示控件</legend>
      <label>密码样例 <input type="password" value="fixture-password"></label>
      <label>验证码样例 <input inputmode="numeric" autocomplete="one-time-code" value="fixture-otp"></label>
      <label>卡号样例 <input inputmode="numeric" autocomplete="cc-number" value="4111111111111111"></label>
    </fieldset></article>`;
}

export function readinessCatalog(origin) {
  const links = readinessLinks(origin);
  return {schemaVersion: 2, kind: 'aegis-acceptance-readiness-fixtures', origin,
    publicDeploymentVerified: false, browserExecuted: false, agentExecuted: false,
    links, expectedCounts: Object.fromEntries(
      [...new Set(links.map(item => item.expectedClassification))].map(key =>
        [key, links.filter(item => item.expectedClassification === key).length])),
    sensitivePage: '/lab/input-sample', legacySensitivePage: '/sensitive',
    restrictions: ['公开来源部署及DNS/证书尚未核验；本机HTTP自测不能证明浏览器链接检查通过。',
      '50条file地址只用于范围拒绝负例，不读取文件；450条HTTP地址需受控公开来源。',
      '超时分类要求浏览器超时先于服务端12秒响应；保留原生实际结果，不直接照抄预期。',
      '新表单必须核对保护未被关闭、敏感字段实际存在、提取与模型日志未泄露；旧阻断样例保留。']};
}
