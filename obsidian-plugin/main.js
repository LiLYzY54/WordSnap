'use strict';

/*
 * WordSnap 词库 —— Obsidian 端的单词管理界面。
 * 读取 WordSnap（macOS App）保存的词汇表格与 Vocabulary/ 词笔记：
 *   - 词库页：搜索 / 状态筛选 / 卡片网格 / 发音 / 点词开笔记 / 状态徽章轮换
 *   - 复习页：翻卡 + 四档评分（回写词笔记 frontmatter status）
 *   - 统计页：总量 / 月度柱状 / 16 周热力图
 * 无构建步骤，直接以 CommonJS 加载。
 */

const obsidian = require('obsidian');

const VIEW_TYPE = 'wordsnap-vocab';

const STATUS_ORDER = ['new', 'learning', 'familiar', 'mastered'];
const STATUS_LABEL = { new: '新词', learning: '学习中', familiar: '熟悉', mastered: '已掌握' };

const DEFAULT_SETTINGS = {
  tablePath: 'English Vocabulary Learning.md',
  notesFolder: 'Vocabulary',
};

/* ---------- 工具 ---------- */

/** 与 App 的 NoteWriter.notePath 使用相同的文件名规则。 */
function notePath(settings, word) {
  return `${settings.notesFolder.replace(/\/+$/, '')}/${word.replace(/[/:]/g, '-')}.md`;
}

/** 仅修改文件开头的 frontmatter；正文（包括分隔线）保持原样。 */
function withStatus(text, status) {
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const bom = text.startsWith('\uFEFF') ? '\uFEFF' : '';
  const content = text.slice(bom.length);
  const opening = /^---[ \t]*\r?\n/.exec(content);
  if (!opening) return `${bom}---${eol}status: ${status}${eol}---${eol}${content}`;

  const rest = content.slice(opening[0].length);
  const closing = /^---[ \t]*(?:\r?\n|$)/m.exec(rest);
  if (!closing) throw new Error('词笔记的属性区缺少结束分隔线，请先修复笔记');

  const frontmatter = rest.slice(0, closing.index);
  const statusLine = /^(?:status|"status"|'status')[ \t]*:[^\r\n]*(?:\r?\n|$)/m;
  const updated = statusLine.test(frontmatter)
    ? frontmatter.replace(statusLine, `status: ${status}${eol}`)
    : `${frontmatter}status: ${status}${eol}`;
  return bom + opening[0] + updated + rest.slice(closing.index);
}

/** 与 App 端 tableRows 相同的解析口径（别名折叠 / 转义竖线保护） */
function parseTable(text) {
  const rows = [];
  for (const raw of text.split('\n')) {
    let t = raw.trim();
    if (!t.startsWith('|')) continue;
    t = t.replace(/\[\[([^\]|]+)\|[^\]]+\]\]/g, '[[$1]]');
    t = t.replace(/\\\|/g, '\u0001');
    let cells = t.split('|').map((c) => c.trim().replace(/\u0001/g, '\\|'));
    if (cells.length && cells[0] === '') cells.shift();
    if (cells.length && cells[cells.length - 1] === '') cells.pop();
    if (cells.length < 7) continue;
    if (cells[0] === '单词' || cells[0].includes('--')) continue;
    const word = cells[0].replace(/^\[\[/, '').replace(/\]\]$/, '').trim();
    if (!word) continue;
    rows.push({
      word,
      phonetic: cells[1],
      pos: cells[2],
      meaning: cells[3],
      example: cells[4],
      source: cells[5],
      date: cells[6],
    });
  }
  return rows;
}

function localDateStr(d) {
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/* ---------- 视图 ---------- */

class WordSnapView extends obsidian.ItemView {
  constructor(leaf, plugin) {
    super(leaf);
    this.plugin = plugin;
    this.tab = 'list';           // list | review | stats
    this.query = '';
    this.statusFilter = 'all';
    this.words = [];
    this.review = { queue: [], index: 0, revealed: false, saving: false };
    this.pendingStatus = new Set();
    this.loadError = '';
    this.pathWarning = '';
  }

  getViewType() { return VIEW_TYPE; }
  getDisplayText() { return 'WordSnap 词库'; }
  getIcon() { return 'graduation-cap'; }

  async onOpen() {
    // 表格或词笔记变动时自动刷新（300ms 防抖）
    this._debounce = null;
    const isRelevantPath = (path) => {
      const s = this.plugin.settings;
      return typeof path === 'string' && (path === s.tablePath
        || path === s.notesFolder || path.startsWith(s.notesFolder + '/'));
    };
    const scheduleRefresh = (file, oldPath) => {
      // 移出已配置位置也需要刷新，所以 rename 同时检查旧路径。
      if (!isRelevantPath(file.path) && !isRelevantPath(oldPath)) return;
      clearTimeout(this._debounce);
      this._debounce = setTimeout(() => this.refresh(), 300);
    };
    for (const event of ['create', 'modify', 'delete', 'rename']) {
      this.registerEvent(this.app.vault.on(event, scheduleRefresh));
    }
    // 文件创建可能先于 frontmatter 解析完成，缓存就绪后再更新评分状态。
    this.registerEvent(this.app.metadataCache.on('changed', (file) => scheduleRefresh(file)));
    await this.refresh();
  }

  async onClose() {
    clearTimeout(this._debounce);
  }

  async refresh() {
    this.loadError = '';
    this.pathWarning = '';
    try {
      this.words = await this.loadWords();
    } catch (error) {
      this.words = [];
      this.loadError = error.message || '词库读取失败，请检查插件设置中的路径及文件访问权限。';
    }
    this.render();
  }

  async loadWords() {
    const s = this.plugin.settings;
    const words = [];
    const file = this.app.vault.getAbstractFileByPath(s.tablePath);
    if (!file) {
      throw new Error(`未找到词汇表：${s.tablePath}。请在 WordSnap 插件设置中填写相对于当前 vault 的表格路径。`);
    }
    words.push(...parseTable(await this.app.vault.read(file)));
    if (!this.app.vault.getAbstractFileByPath(s.notesFolder)) {
      this.pathWarning = `未找到词笔记目录：${s.notesFolder}。请检查插件设置中的词笔记目录，或先在 WordSnap 中保存词笔记。`;
    }
    for (const row of words) {
      const note = this.app.vault.getAbstractFileByPath(notePath(s, row.word));
      const fm = note ? (this.app.metadataCache.getFileCache(note) || {}).frontmatter || {} : {};
      row.status = fm.status || 'new';
      row.star = fm.star || '';
      row.hasNote = !!note;
    }
    // 新的在前
    words.sort((a, b) => (b.date || '').localeCompare(a.date || ''));
    return words;
  }

  /* ---------- 渲染骨架 ---------- */

  render() {
    const root = this.contentEl;
    root.empty();
    root.addClass('ws-root');

    const total = this.words.length;
    const header = root.createDiv({ cls: 'ws-header' });
    header.createEl('h2', { text: 'WordSnap' });
    header.createSpan({ cls: 'ws-count', text: total ? `${total} 个词` : '' });
    const refreshBtn = header.createEl('button', { cls: 'ws-refresh ws-chip', text: '⟳ 刷新' });
    refreshBtn.onclick = () => this.refresh();

    if (this.loadError) {
      root.createDiv({ cls: 'ws-config-warning', text: this.loadError });
      return;
    }
    if (this.pathWarning) root.createDiv({ cls: 'ws-config-warning', text: this.pathWarning });

    if (this.tab === 'list') {
      const hero = root.createDiv({ cls: 'ws-hero' });
      hero.createDiv({ cls: 'ws-eyebrow', text: 'MY WORD COLLECTION' });
      hero.createEl('h1', { text: '让遇见的词，留在记忆里。' });
      hero.createEl('p', { text: '收集阅读中的灵感，用自己的句子记住它。' });
      const remaining = this.words.filter((w) => w.status !== 'mastered').length;
      const start = hero.createEl('button', { cls: 'ws-start', text: remaining ? `开始复习 · ${remaining} 个词 →` : '已全部掌握' });
      start.disabled = !remaining;
      start.onclick = () => { this.startReview(); this.tab = 'review'; this.render(); };
      const metrics = hero.createDiv({ cls: 'ws-overview' });
      for (const [label, count] of [
        ['收藏单词', total],
        ['正在学习', this.words.filter((w) => ['learning', 'familiar'].includes(w.status)).length],
        ['已经掌握', this.words.filter((w) => w.status === 'mastered').length],
      ]) {
        const metric = metrics.createDiv({ cls: 'ws-metric' });
        metric.createEl('strong', { text: String(count) });
        metric.createSpan({ text: label });
      }
    }

    const tabs = root.createDiv({ cls: 'ws-tabs' });
    const tabDefs = [
      ['list', '词库'], ['review', '复习'], ['stats', '统计'],
    ];
    for (const [key, label] of tabDefs) {
      const b = tabs.createEl('button', {
        cls: 'ws-tab' + (this.tab === key ? ' ws-active' : ''),
        text: label,
      });
      b.onclick = () => { this.tab = key; this.render(); };
    }

    const content = root.createDiv();
    if (this.tab === 'list') this.renderList(content);
    else if (this.tab === 'review') this.renderReview(content);
    else this.renderStats(content);
  }

  /* ---------- 词库页 ---------- */

  renderList(container) {
    const toolbar = container.createDiv({ cls: 'ws-toolbar' });
    const search = toolbar.createEl('input', {
      cls: 'ws-search',
      type: 'text',
      placeholder: '搜索单词 / 释义…',
      value: this.query,
    });
    search.oninput = () => { this.query = search.value; this.renderCardGrid(); };

    const chips = toolbar.createDiv({ cls: 'ws-chips' });
    const filters = [['all', '全部'], ...STATUS_ORDER.map((s) => [s, STATUS_LABEL[s]])];
    for (const [key, label] of filters) {
      const chip = chips.createEl('button', {
        cls: 'ws-chip' + (this.statusFilter === key ? ' ws-chip-active' : ''),
        text: label,
      });
      chip.onclick = () => {
        this.statusFilter = key;
        this.render();
      };
    }

    this.gridEl = container.createDiv({ cls: 'ws-grid' });
    this.renderCardGrid();
  }

  renderCardGrid() {
    const grid = this.gridEl;
    if (!grid) return;
    grid.empty();

    const q = this.query.trim().toLowerCase();
    const list = this.words.filter((w) => {
      if (this.statusFilter !== 'all' && w.status !== this.statusFilter) return false;
      if (!q) return true;
      return (w.word + w.meaning + w.example).toLowerCase().includes(q);
    });

    if (!this.words.length) {
      grid.createDiv({
        cls: 'ws-empty',
        text: '词汇表还是空的。在任意应用按 ⌘L 呼出 WordSnap，查一个词，⌘Enter 保存——它就会出现在这里。',
      });
      return;
    }
    if (!list.length) {
      grid.createDiv({ cls: 'ws-empty', text: '没有匹配的词。' });
      return;
    }

    for (const w of list) {
      const card = grid.createDiv({ cls: 'ws-card' });

      const top = card.createDiv({ cls: 'ws-card-top' });
      const wordEl = top.createEl('button', { cls: 'ws-word', text: w.word });
      wordEl.title = '打开词笔记';
      wordEl.onclick = () => this.openNote(w.word);
      top.createEl('button', { cls: 'ws-audio-btn', text: '🔊', title: '朗读' })
        .onclick = () => this.playAudio(w.word);
      if (w.star) top.createSpan({ cls: 'ws-star', text: w.star });

      if (w.phonetic || w.pos) {
        card.createSpan({ cls: 'ws-phonetic', text: [w.phonetic, w.pos].filter(Boolean).join('  ') });
      }
      if (w.meaning) card.createDiv({ cls: 'ws-meaning', text: w.meaning });
      if (w.example) card.createDiv({ cls: 'ws-example', text: w.example });

      const foot = card.createDiv({ cls: 'ws-card-foot' });
      const pill = foot.createEl('button', {
        cls: 'ws-pill ws-pill-' + (STATUS_ORDER.includes(w.status) ? w.status : 'none'),
        text: STATUS_LABEL[w.status] || w.status || '未标注',
        title: '点击切换状态',
      });
      pill.disabled = this.pendingStatus.has(notePath(this.plugin.settings, w.word));
      pill.onclick = async () => {
        if (pill.disabled) return;
        pill.disabled = true;
        const next = STATUS_ORDER[(STATUS_ORDER.indexOf(w.status) + 1) % STATUS_ORDER.length];
        if (await this.setStatus(w.word, next)) w.status = next;
        this.renderCardGrid();
      };
      foot.createSpan({ cls: 'ws-date', text: w.date || '' });
      if (w.hasNote) {
        const link = foot.createEl('button', { cls: 'ws-note-link', text: '笔记 →' });
        link.onclick = () => this.openNote(w.word);
      }
    }
  }

  /* ---------- 复习页 ---------- */

  startReview() {
    const queue = this.words
      .filter((w) => w.status !== 'mastered')
      .sort((a, b) => (a.date || '').localeCompare(b.date || '')); // 最旧的先复习
    this.review = { queue, index: 0, revealed: false, saving: false };
  }

  renderReview(container) {
    const wrap = container.createDiv({ cls: 'ws-review-wrap' });

    if (!this.words.length) {
      wrap.createDiv({
        cls: 'ws-empty',
        text: '词库还是空的。先用 WordSnap 存几个词，再来复习。',
      });
      return;
    }
    if (!this.review.queue.length) this.startReview();
    if (this.review.index >= this.review.queue.length) {
      wrap.createDiv({ cls: 'ws-empty', text: '这一轮复习完了 🎉\n点击下方按钮再来一轮（未掌握的词会重新排队）。' });
      const again = wrap.createEl('button', { cls: 'ws-reveal-btn', text: '再来一轮' });
      again.onclick = () => { this.startReview(); this.render(); };
      return;
    }

    const w = this.review.queue[this.review.index];
    const r = this.review;
    wrap.createDiv({ cls: 'ws-progress', text: `${r.index + 1} / ${r.queue.length} · 最旧的优先` });

    const card = wrap.createDiv({ cls: 'ws-flipcard' });
    card.createDiv({ cls: 'ws-flip-word', text: w.word });
    if (w.phonetic) card.createDiv({ cls: 'ws-flip-phonetic', text: w.phonetic });
    card.createEl('button', { cls: 'ws-audio-btn', text: '🔊 朗读' })
      .onclick = () => this.playAudio(w.word);

    if (!r.revealed) {
      const reveal = card.createEl('button', { cls: 'ws-reveal-btn', text: '显示释义' });
      reveal.onclick = () => { r.revealed = true; this.render(); };
    } else {
      const body = card.createDiv({ cls: 'ws-reveal-body' });
      body.createDiv({ cls: 'ws-r-meaning', text: w.meaning || '（无释义）' });
      if (w.example) body.createDiv({ cls: 'ws-r-example', text: w.example });

      const grades = body.createDiv({ cls: 'ws-grades' });
      const gradeDefs = [
        ['不认识', 'new'], ['模糊', 'learning'], ['认识', 'familiar'], ['已掌握', 'mastered'],
      ];
      const buttons = [];
      for (const [label, status] of gradeDefs) {
        const btn = grades.createEl('button', { cls: 'ws-grade', text: label });
        buttons.push(btn);
        btn.disabled = !!r.saving;
        btn.onclick = async () => {
          if (r.saving || this.review !== r || r.queue[r.index] !== w) return;
          // 在第一个 await 前锁住本张卡，连点不同评分也只提交一次。
          r.saving = true;
          buttons.forEach((button) => { button.disabled = true; });
          try {
            if (await this.setStatus(w.word, status)) {
              r.index += 1;
              r.revealed = false;
            }
          } finally {
            r.saving = false;
            this.render();
          }
        };
      }
    }
  }

  /* ---------- 统计页 ---------- */

  renderStats(container) {
    const words = this.words;
    if (!words.length) {
      container.createDiv({ cls: 'ws-empty', text: '还没有数据。先存几个词吧。' });
      return;
    }
    const today = localDateStr(new Date());
    const monthPrefix = today.slice(0, 7);
    const mastered = words.filter((w) => w.status === 'mastered').length;
    const noted = words.filter((w) => w.hasNote).length;

    const cards = container.createDiv({ cls: 'ws-stat-cards' });
    const statDefs = [
      [String(words.length), '总词数'],
      [String(words.filter((w) => (w.date || '').startsWith(monthPrefix)).length), '本月新增'],
      [String(mastered), '已掌握'],
      [String(noted), '词笔记'],
    ];
    for (const [num, label] of statDefs) {
      const c = cards.createDiv({ cls: 'ws-stat-card' });
      c.createDiv({ cls: 'ws-stat-num', text: num });
      c.createDiv({ cls: 'ws-stat-label', text: label });
    }

    // 月度柱状（近 6 个月）
    container.createDiv({ cls: 'ws-section-title', text: '月度新增' });
    const monthCounts = {};
    for (const w of words) {
      const m = (w.date || '').slice(0, 7);
      if (m) monthCounts[m] = (monthCounts[m] || 0) + 1;
    }
    const months = [];
    const now = new Date();
    for (let i = 5; i >= 0; i--) {
      const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
      months.push(`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`);
    }
    const max = Math.max(1, ...months.map((m) => monthCounts[m] || 0));
    const bars = container.createDiv({ cls: 'ws-bars' });
    for (const m of months) {
      const count = monthCounts[m] || 0;
      const col = bars.createDiv({ cls: 'ws-bar-col' });
      col.createDiv({ cls: 'ws-bar-num', text: count ? String(count) : '' });
      const bar = col.createDiv({ cls: 'ws-bar' });
      bar.style.height = `${Math.round((count / max) * 90) + 3}px`;
      col.createDiv({ cls: 'ws-bar-label', text: m.slice(2) });
    }

    // 16 周热力图
    container.createDiv({ cls: 'ws-section-title', text: '近 16 周' });
    const heat = container.createDiv({ cls: 'ws-heat' });
    const totalDays = 16 * 7;
    for (let col = 0; col < 16; col++) {
      const colEl = heat.createDiv({ cls: 'ws-heat-col' });
      for (let row = 0; row < 7; row++) {
        const daysAgo = totalDays - 1 - (col * 7 + row);
        const d = new Date(Date.now() - daysAgo * 86400000);
        const key = localDateStr(d);
        const n = words.filter((w) => w.date === key).length;
        const cell = colEl.createDiv({ cls: 'ws-heat-cell' });
        cell.title = `${key} · ${n} 词`;
        if (n >= 3) cell.style.background = 'var(--color-green, #28b450)';
        else if (n === 2) cell.style.background = 'rgba(var(--color-green-rgb, 40,180,80), 0.65)';
        else if (n === 1) cell.style.background = 'rgba(var(--color-green-rgb, 40,180,80), 0.4)';
      }
    }
  }

  /* ---------- 动作 ---------- */

  playAudio(word) {
    try {
      if (this._audio) this._audio.pause();
      this._audio = new Audio(
        `https://dict.youdao.com/dictvoice?type=2&audio=${encodeURIComponent(word)}`);
      this._audio.play().catch(() => new obsidian.Notice('发音加载失败，请检查网络'));
    } catch (e) { /* 忽略 */ }
  }

  async openNote(word) {
    const path = notePath(this.plugin.settings, word);
    const file = this.app.vault.getAbstractFileByPath(path);
    if (!file) {
      new obsidian.Notice(`词笔记不存在：${path}。请检查词笔记目录，或在 WordSnap 中再次保存该词。`);
      return false;
    }
    await this.app.workspace.getLeaf(false).openFile(file);
    return true;
  }

  /** 持久化成功才返回 true；失败时保留当前卡片和内存状态，允许重试。 */
  async setStatus(word, status) {
    const path = notePath(this.plugin.settings, word);
    if (this.pendingStatus.has(path)) return false;
    const file = this.app.vault.getAbstractFileByPath(path);
    if (!file) {
      new obsidian.Notice(`词笔记不存在：${path}。请检查词笔记目录，或在 WordSnap 中再次保存该词。`);
      return false;
    }
    this.pendingStatus.add(path);
    try {
      // 在同一次原子操作中读取并更新，避免用旧快照覆盖其他编辑器的新内容。
      await this.app.vault.process(file, (text) => withStatus(text, status));
      const row = this.words.find((x) => x.word === word);
      if (row) row.status = status;
      return true;
    } catch (error) {
      new obsidian.Notice(`状态未保存：${error.message || '写入失败'}。请检查笔记后重试。`);
      return false;
    } finally {
      this.pendingStatus.delete(path);
    }
  }
}

/* ---------- 插件入口 ---------- */

class WordSnapPlugin extends obsidian.Plugin {

  async onload() {
    this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData());

    this.registerView(VIEW_TYPE, (leaf) => new WordSnapView(leaf, this));
    this.addRibbonIcon('graduation-cap', 'WordSnap 词库', () => this.activateView());
    this.addCommand({
      id: 'open-dashboard',
      name: '打开词库仪表盘',
      callback: () => this.activateView(),
    });
    this.addSettingTab(new WordSnapSettingTab(this.app, this));
    this.registerObsidianProtocolHandler('wordsnap', () => this.activateView());

    // 启动即展示词库仪表盘（尚未打开时）：打开 Obsidian 就看见自己的词库
    this.app.workspace.onLayoutReady(() => {
      if (!this.app.workspace.getLeavesOfType(VIEW_TYPE).length) {
        this.activateView();
      }
    });
  }

  onunload() {}

  async activateView() {
    const { workspace } = this.app;
    let leaf = null;
    for (const l of workspace.getLeavesOfType(VIEW_TYPE)) { leaf = l; break; }
    if (!leaf) {
      leaf = workspace.getLeaf('tab');
      await leaf.setViewState({ type: VIEW_TYPE, active: true });
    }
    workspace.revealLeaf(leaf);
  }
}

class WordSnapSettingTab extends obsidian.PluginSettingTab {

  constructor(app, plugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display() {
    const { containerEl } = this;
    containerEl.empty();
    containerEl.createEl('h3', { text: 'WordSnap 词库' });
    containerEl.createEl('p', {
      text: '路径相对于当前 vault。默认表格为根目录的 English Vocabulary Learning.md，词笔记为 Vocabulary。若在 WordSnap App 中选择了其他位置，请在这里填写对应路径。',
      cls: 'setting-item-description',
    });

    new obsidian.Setting(containerEl)
      .setName('词汇表格路径')
      .setDesc('WordSnap 保存的 7 列 Markdown 表格')
      .addText((text) => text
        .setPlaceholder(DEFAULT_SETTINGS.tablePath)
        .setValue(this.plugin.settings.tablePath)
        .onChange(async (v) => {
          this.plugin.settings.tablePath = v || DEFAULT_SETTINGS.tablePath;
          await this.plugin.saveData(this.plugin.settings);
        }));

    new obsidian.Setting(containerEl)
      .setName('词笔记目录')
      .setDesc('WordSnap 生成的词笔记所在目录（含 frontmatter status）')
      .addText((text) => text
        .setPlaceholder(DEFAULT_SETTINGS.notesFolder)
        .setValue(this.plugin.settings.notesFolder)
        .onChange(async (v) => {
          this.plugin.settings.notesFolder = v || DEFAULT_SETTINGS.notesFolder;
          await this.plugin.saveData(this.plugin.settings);
        }));
  }
}

module.exports = WordSnapPlugin;
