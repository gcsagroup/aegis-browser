// Copyright 2026 GCSA
// Android 独立设置子页复用助手现有控件；不自动启用助手或执行模型。
export function initializeMobileAgentSettings(
    refresh: () => Promise<void>, showReading: () => void,
    openSettings: () => void) {
  const params = new URLSearchParams(location.search);
  const section = params.get('mobileSettings');
  const language = document.documentElement.lang;
  const text = (zh: string, en: string, tw: string) =>
      !language.startsWith('zh') ? en : /^zh-(?:TW|HK|Hant)/i.test(language) ? tw : zh;
  const main = document.querySelector('main')!;
  document.body.classList.add('mobile-agent-shell');
  const back = document.createElement('a');
  back.className = 'mobile-settings-back';
  back.href = 'chrome://aegis/';
  back.textContent = '← ' + text('Aegis 设置', 'Aegis settings', 'Aegis 設定');
  // 不受信任页面不能直接跳转 chrome://，沿用仅打开固定设置页的原生入口。
  back.addEventListener('click', event => {
    event.preventDefault();
    openSettings();
  });
  main.prepend(back);
  if (params.get('view') === 'reading') {
    document.getElementById('goal')?.removeAttribute('autofocus');
    showReading();
    void refresh();
  }
  if (section !== 'reading' && section !== 'experiments') return;
  document.getElementById('goal')?.removeAttribute('autofocus');
  let research = document.getElementById('reading-research-settings');
  const local = document.getElementById('reading-ai-settings') as HTMLDetailsElement;
  local.querySelector('summary')!.textContent = text(
      '本机翻译设置', 'Local translation settings', '本機翻譯設定');
  if (!research) {
    research = document.createElement('details');
    research.id = 'reading-research-settings';
    research.className = 'card';
    const summary = document.createElement('summary');
    const heading = local.querySelector('h3')!;
    summary.textContent = heading.textContent;
    research.append(summary);
    while (heading.nextElementSibling) research.append(heading.nextElementSibling);
    heading.remove();
    local.after(research);
    research.addEventListener('toggle', () => {
      if ((research as HTMLDetailsElement).open) void refresh();
    });
  }
  document.body.dataset['mobileSettings'] = section;
  document.getElementById('title')!.textContent = section === 'reading' ?
      text('本机翻译设置', 'Local translation settings', '本機翻譯設定') :
      text('实验功能', 'Experiments', '實驗功能');
  document.title = document.getElementById('title')!.textContent!;
  document.getElementById('subtitle')!.textContent = section === 'reading' ?
      text('先下载语言包，再按所选方向离线翻译。', 'Download a language pack to translate offline in the selected direction.', '先下載語言包，再依所選方向離線翻譯。') :
      text('实验评分不会自动拦截网页或修改正文。', 'Experimental scores do not automatically block pages or change their content.', '實驗評分不會自動攔截網頁或修改正文。');
  (section === 'reading' ? local : research as HTMLDetailsElement).open = true;
  // 沿用展开事件回读配置，避免同时发起两次刷新；推理仍需用户主动发起。
}
