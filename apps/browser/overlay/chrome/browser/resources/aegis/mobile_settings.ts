// Copyright 2026 GCSA
// 移动端复用现有控件与配置，只调整入口和分组。
export function initializeMobileSettings(
    openAgent: (section: string) => Promise<unknown>) {
  const main = document.querySelector<HTMLElement>('main');
  if (!main) throw Error('缺少移动设置主区域');
  if (main.classList.contains('mobile-settings')) return;
  const language = document.documentElement.lang;
  const text = (zh: string, en: string, tw: string) =>
      !language.startsWith('zh') ? en : /^zh-(?:TW|HK|Hant)/i.test(language) ? tw : zh;
  const title = text('Aegis 设置', 'Aegis settings', 'Aegis 設定');
  const groups = [
    {id: 'privacy', title: text('隐私与防护', 'Privacy and protection', '隱私與防護'),
      hint: text('跟踪拦截、广告过滤与网站防护', 'Trackers, filters and website protection', '追蹤攔截、廣告過濾與網站防護'),
      selectors: '.overview, .activity, .modules, .diagnostics, .filters'},
    {id: 'enhancements', title: text('网站增强与脚本', 'Website enhancements and scripts', '網站增強與腳本'),
      hint: text('Android 版暂未提供', 'Not yet available on Android', 'Android 版暫未提供'), selectors: ''},
    {id: 'reading', title: text('阅读与 Markdown', 'Reading and Markdown', '閱讀與 Markdown'),
      hint: text('阅读资料库、工作区与本机翻译', 'Reading library, workspaces and local translation', '閱讀資料庫、工作區與本機翻譯'), selectors: ''},
    {id: 'gestures', title: text('鼠标手势', 'Mouse gestures', '滑鼠手勢'),
      hint: text('此功能适用于桌面版', 'Available on desktop', '此功能適用於桌面版'), selectors: ''},
    {id: 'ai', title: text('AI 与模型', 'AI and models', 'AI 與模型'),
      hint: text('模型服务、网页摘要与助手', 'Model services, page summaries and assistant', '模型服務、網頁摘要與助手'),
      selectors: '.privacy, #browser-agent-section'},
    {id: 'downloads', title: text('下载增强', 'Download enhancements', '下載增強'),
      hint: text('Metalink 下载任务与下载记录', 'Metalink tasks and download history', 'Metalink 下載工作與下載記錄'), selectors: '.downloads'},
    {id: 'tools', title: text('本机工具连接', 'Local tool connections', '本機工具連線'),
      hint: text('此功能适用于桌面版', 'Available on desktop', '此功能適用於桌面版'), selectors: ''},
    {id: 'experiments', title: text('实验功能', 'Experiments', '實驗功能'),
      hint: text('本机实验模型与使用说明', 'Local experimental models and usage notes', '本機實驗模型與使用說明'), selectors: ''},
  ];
  const heading = main.querySelector<HTMLElement>('.page-header h1');
  const subtitle = main.querySelector<HTMLElement>('.subtitle');
  const header = main.querySelector('.page-header');
  if (!heading || !subtitle || !header) throw Error('缺少移动设置标题区域');
  heading.setAttribute('tabindex', '-1');
  main.querySelector<HTMLElement>('.ai-control')?.setAttribute('hidden', '');
  const downloadDescription = main.querySelector('.downloads > .meta');
  if (downloadDescription) downloadDescription.textContent = text(
      '管理普通下载、Metalink 镜像下载与下载记录。Android 版暂不支持种子或磁力链接。',
      'Manage downloads, Metalink mirrors and download history. Torrents and magnet links are not supported on Android.',
      '管理一般下載、Metalink 鏡像下載與下載記錄。Android 版暫不支援種子或磁力連結。');
  const back = document.createElement('a');
  back.className = 'mobile-settings-back';
  back.href = '#home';
  back.textContent = '← ' + title;
  header.before(back);
  const nav = document.createElement('nav');
  nav.className = 'mobile-settings-nav';
  nav.setAttribute('aria-label', title);
  header.after(nav);
  const pages = new Map<string, HTMLElement>();
  for (const group of groups) {
    const link = document.createElement('a');
    link.href = '#' + group.id;
    const label = document.createElement('strong');
    label.textContent = group.title;
    const hint = document.createElement('small');
    hint.textContent = group.hint;
    link.append(label, hint);
    nav.append(link);
    const page = document.createElement('article');
    page.className = 'mobile-settings-content';
    page.id = 'mobile-' + group.id;
    page.setAttribute('aria-label', group.title);
    if (group.selectors) {
      for (const node of main.querySelectorAll(group.selectors)) page.append(node);
    } else {
      const card = document.createElement('section');
      card.className = 'mobile-settings-card';
      const description = document.createElement('p');
      description.textContent = group.id === 'reading' ? text(
          '整理已打开网页、保存阅读资料和批注，或管理本机翻译语言包。Android 版暂未提供 Markdown 阅读器。',
          'Organize open pages, save reading material and notes, or manage local translation packs. The Markdown reader is not yet available on Android.',
          '整理已開啟網頁、儲存閱讀資料和批註，或管理本機翻譯語言包。Android 版暫未提供 Markdown 閱讀器。') : group.hint;
      card.append(description);
      const actions: Array<[string, string]> = group.id === 'reading' ? [
        ['reading', text('本机翻译设置', 'Local translation settings', '本機翻譯設定')],
        ['workspace', text('打开阅读工作区', 'Open reading workspace', '開啟閱讀工作區')],
      ] : group.id === 'experiments' ? [
        ['experiments', text('管理实验模型', 'Manage experimental models', '管理實驗模型')],
      ] : [];
      for (const [section, caption] of actions) {
        const button = document.createElement('button');
        button.type = 'button';
        button.textContent = caption;
        button.addEventListener('click', () => {
          void openAgent(section).catch(() => {
            description.textContent = text('暂时无法打开，请稍后重试。', 'Unable to open. Please retry.', '暫時無法開啟，請稍後重試。');
          });
        });
        card.append(button);
      }
      page.append(card);
    }
    pages.set(group.id, page);
    main.append(page);
  }
  main.classList.add('mobile-settings');
  document.body.classList.add('mobile-settings-shell');
  main.querySelector<HTMLElement>(':scope > .note')?.setAttribute('hidden', '');
  const render = (focus: boolean) => {
    const fragment = location.hash.slice(1);
    const legacy: Record<string, string> = {'overview-title': 'privacy', 'activity-log': 'privacy', 'fp-probe': 'privacy', 'privacy-result': 'ai'};
    const id = legacy[fragment] || fragment;
    const group = groups.find(candidate => candidate.id === id);
    back.hidden = !group;
    nav.hidden = !!group;
    heading.textContent = group?.title || title;
    subtitle.textContent = group?.hint || text(
        '按功能分类管理浏览器设置。', 'Manage browser settings by category.', '依功能分類管理瀏覽器設定。');
    document.title = heading.textContent;
    for (const [key, page] of pages) page.hidden = key !== group?.id;
    if (focus) {
      window.scrollTo(0, 0);
      heading.focus({preventScroll: true});
    }
  };
  window.addEventListener('hashchange', () => { render(true); });
  render(false);
}
