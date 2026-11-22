const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

/** Load the real plugin with a small, isolated Obsidian API substitute. */
async function createView(vault, settings = {}, timers = { setTimeout, clearTimeout }) {
  const notices = [];
  const opened = [];
  const app = {
    vault,
    workspace: {
      onLayoutReady() {},
      getLeaf() { return { async openFile(file) { opened.push(file.path); } }; },
    },
    metadataCache: { ...events(), getFileCache() { return {}; } },
  };
  const obsidian = {
    ItemView: class {
      constructor(leaf) { this.app = leaf.app; this.contentEl = new Element(); }
      registerEvent() {}
    },
    Plugin: class {
      constructor() { this.app = app; }
      async loadData() { return settings; }
      registerView(type, factory) { this.viewFactory = factory; }
      addRibbonIcon() {}
      addCommand() {}
      addSettingTab() {}
      registerObsidianProtocolHandler() {}
    },
    PluginSettingTab: class {},
    Notice: class {
      constructor(message) { notices.push(message); }
    },
  };
  const sandbox = {
    module: { exports: {} },
    require(name) {
      if (name !== 'obsidian') throw new Error(`Unexpected dependency: ${name}`);
      return obsidian;
    },
    setTimeout: timers.setTimeout,
    clearTimeout: timers.clearTimeout,
  };
  vm.createContext(sandbox);
  const filename = path.join(__dirname, '..', 'main.js');
  vm.runInContext(fs.readFileSync(filename, 'utf8'), sandbox, { filename });
  const plugin = new sandbox.module.exports();
  await plugin.onload();
  return { view: plugin.viewFactory({ app }), plugin, notices, opened, app };
}

class Element {
  constructor(options = {}) {
    Object.assign(this, options);
    this.children = [];
    this.style = {};
    this.disabled = false;
  }
  createEl(tag, options = {}) {
    const element = new Element({ tag, ...options });
    this.children.push(element);
    return element;
  }
  createDiv(options) { return this.createEl('div', options); }
  createSpan(options) { return this.createEl('span', options); }
  empty() { this.children = []; }
  addClass() {}
  findAll(predicate) {
    return [this, ...this.children.flatMap((child) => child.findAll(() => true))].filter(predicate);
  }
}

/** Each process callback sees and updates the latest content synchronously. */
function memoryVault(initialFiles) {
  const contents = new Map(Object.entries(initialFiles));
  return {
    ...events(),
    contents,
    getAbstractFileByPath(path) {
      if (contents.has(path)) return { path };
      return [...contents.keys()].some((key) => key.startsWith(path + '/')) ? { path, children: [] } : null;
    },
    async read(file) { return contents.get(file.path); },
    async modify(file, text) { contents.set(file.path, text); },
    async process(file, transform) {
      const text = transform(contents.get(file.path));
      contents.set(file.path, text);
      return text;
    },
  };
}

function events() {
  const handlers = new Map();
  return {
    on(name, callback) {
      if (!handlers.has(name)) handlers.set(name, []);
      handlers.get(name).push(callback);
      return { name, callback };
    },
    trigger(name, ...args) {
      for (const callback of handlers.get(name) || []) callback(...args);
    },
  };
}

function fakeTimers() {
  const pending = new Map();
  return {
    setTimeout(callback) {
      const id = Symbol('timeout');
      pending.set(id, callback);
      return id;
    },
    clearTimeout(id) { pending.delete(id); },
    get pendingCount() { return pending.size; },
    async flush() {
      const callbacks = [...pending.values()];
      pending.clear();
      for (const callback of callbacks) await callback();
    },
  };
}

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

module.exports = { createView, memoryVault, deferred, fakeTimers };
