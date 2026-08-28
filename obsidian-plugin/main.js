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
  tablePath: 'Projects/Language Learning/English Vocabulary Learning.md',
  notesFolder: 'Projects/Language Learning/Vocabulary',
};

/* ---------- 工具 ---------- */

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
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
    this.review = { queue: [], index: 0, revealed: false };
  }

  getViewType() { return VIEW_TYPE; }
  getDisplayText() { return 'WordSnap 词库'; }
  getIcon() { return 'graduation-cap'; }

  async onOpen() {
    // 表格或词笔记变动时自动刷新（300ms 防抖）
    this._debounce = null;
    this.registerEvent(this.app.vault.on('modify', (file) => {
      const s = this.plugin.settings;
      if (file.path === s.tablePath || file.path.startsWith(s.notesFolder + '/')) {
        clearTimeout(this._debounce);
        this._debounce = setTimeout(() => this.refresh(), 300);
      }
    }));
    await this.refresh();
  }

  async onClose() {
    clearTimeout(this._debounce);
  }

  async refresh() {
    this.words = await this.loadWords();
    this.render();
  }

  async loadWords() {
    const s = this.plugin.settings;
    const words = [];
    const file = this.app.vault.getAbstractFileByPath(s.tablePath);
    if (file) {
      words.push(...parseTable(await this.app.vault.read(file)));
    }
    const noteMeta = {};
    const prefix = s.notesFolder + '/';
    for (const f of this.app.vault.getMarkdownFiles()) {
      if (!f.path.startsWith(prefix)) continue;
      const fm = (this.app.metadataCache.getFileCache(f) || {}).frontmatter || {};
      noteMeta[fm.word || f.basename] = {
        status: fm.status || 'new',
        star: fm.star || '',
      };
    }
    for (const row of words) {
      const meta = noteMeta[row.word];
      row.status = meta ? meta.status : 'new';
      row.star = meta ? meta.star : '';
      row.hasNote = !!meta;
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
    header.createEl('h2', { text: '📚 WordSnap 词库' });
    header.createSpan({ cls: 'ws-count', text: total ? `${total} 个词` : '' });
    const refreshBtn = header.createEl('button', { cls: 'ws-refresh ws-chip', text: '⟳ 刷新' });
    refreshBtn.onclick = () => this.refresh();

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
      const wordEl = top.createSpan({ cls: 'ws-word', text: w.word });
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
      pill.onclick = async () => {
        const next = STATUS_ORDER[(STATUS_ORDER.indexOf(w.status) + 1) % STATUS_ORDER.length];
        await this.setStatus(w.word, next);
        w.status = next;
        this.renderCardGrid();
      };
      foot.createSpan({ cls: 'ws-date', text: w.date || '' });
      if (w.hasNote) {
        const link = foot.createSpan({ cls: 'ws-note-link', text: '笔记 →' });
        link.onclick = () => this.openNote(w.word);
      }
    }
  }

  /* ---------- 复习页 ---------- */

  startReview() {
    const queue = this.words
      .filter((w) => w.status !== 'mastered')
      .sort((a, b) => (a.date || '').localeCompare(b.date || '')); // 最旧的先复习
    this.review = { queue, index: 0, revealed: false };
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
      for (const [label, status] of gradeDefs) {
        const btn = grades.createEl('button', { cls: 'ws-grade', text: label });
        btn.onclick = async () => {
          await this.setStatus(w.word, status);
          r.index += 1;
          r.revealed = false;
          this.render();
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
    await this.app.workspace.openLinkText(word, '', false);
  }

  /** 评分回写：只改词笔记 frontmatter 里的 status 行 */
  async setStatus(word, status) {
    const path = `${this.plugin.settings.notesFolder}/${word}.md`;
    const file = this.app.vault.getAbstractFileByPath(path);
    if (!file) {
      new obsidian.Notice(`词笔记不存在：${path}（保存时未生成）`);
      return;
    }
    const text = await this.app.vault.read(file);
    const lines = text.split('\n');
    let inFm = false, fences = 0, done = false;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].trim() === '---') {
        fences++;
        if (fences === 1) { inFm = true; continue; }
        break; // 第二个 --- 即 frontmatter 结束
      }
      if (inFm && /^status:/.test(lines[i])) {
        lines[i] = `status: ${status}`;
        done = true;
        break;
      }
    }
    if (done) {
      await this.app.vault.modify(file, lines.join('\n'));
      const row = this.words.find((x) => x.word === word);
      if (row) row.status = status;
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
      leaf = workspace.getRightLeaf(false);
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
      text: '路径相对于当前 vault。默认值对应 WordSnap 的 ~/.wordsnap.json 配置。',
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
