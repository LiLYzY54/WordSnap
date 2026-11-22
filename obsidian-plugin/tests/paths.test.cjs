const assert = require('node:assert/strict');
const test = require('node:test');
const { createView, memoryVault } = require('./helpers.cjs');

const row = (word) => `| [[${word}]] | | | definition | example | Youdao | 2026-11-21 |\n`;

test('new installations use the App default paths relative to the vault root', async () => {
  const vault = memoryVault({
    'English Vocabulary Learning.md': row('apple'),
    'Vocabulary/apple.md': '---\nstatus: new\n---\n',
  });
  const { view, plugin } = await createView(vault);

  await view.refresh();

  assert.equal(plugin.settings.tablePath, 'English Vocabulary Learning.md');
  assert.equal(plugin.settings.notesFolder, 'Vocabulary');
  assert.equal(view.words.length, 1);
  assert.equal(view.words[0].hasNote, true);
  assert.equal(view.loadError, '');
  assert.equal(view.pathWarning, '');
});

test('saved custom paths are preserved', async () => {
  const settings = { tablePath: 'Projects/Words.md', notesFolder: 'Projects/Vocabulary' };
  const { plugin } = await createView(memoryVault({}), settings);
  assert.equal(plugin.settings.tablePath, settings.tablePath);
  assert.equal(plugin.settings.notesFolder, settings.notesFolder);
});

test('a missing table shows a configuration message instead of an empty vocabulary', async () => {
  const { view } = await createView(memoryVault({}));

  await view.refresh();

  const messages = view.contentEl.findAll((element) => element.cls === 'ws-config-warning');
  assert.equal(messages.length, 1);
  assert.match(messages[0].text, /未找到词汇表.*插件设置/);
  assert.equal(view.contentEl.findAll((element) => element.cls === 'ws-empty').length, 0);
});

test('a missing notes folder shows its configured path without hiding the table', async () => {
  const { view } = await createView(memoryVault({ 'English Vocabulary Learning.md': row('apple') }));

  await view.refresh();

  assert.equal(view.words.length, 1);
  assert.match(view.pathWarning, /未找到词笔记目录：Vocabulary/);
  assert.equal(view.words[0].hasNote, false);
});

for (const word of ['and/or', 'ratio:one']) {
  test(`reading, grading and opening ${word} use the App's sanitized note path`, async () => {
    const path = `Vocabulary/${word.replace(/[/:]/g, '-')}.md`;
    const vault = memoryVault({
      'English Vocabulary Learning.md': row(word),
      [path]: '---\nstatus: new\n---\nMy example\n',
      [`Other/${word.replace(/[/:]/g, '-')}.md`]: 'Unrelated note with the same name',
    });
    const { view, opened, app } = await createView(vault);
    app.metadataCache.getFileCache = (file) => file.path === path ? { frontmatter: { status: 'learning' } } : {};

    await view.refresh();
    assert.equal(view.words[0].hasNote, true);
    assert.equal(view.words[0].status, 'learning');
    assert.equal(await view.setStatus(word, 'mastered'), true);
    assert.match(vault.contents.get(path), /status: mastered/);
    assert.equal(await view.openNote(word), true);
    assert.deepEqual(opened, [path]);
  });
}

test('opening a missing note reports its expected location without creating another file', async () => {
  const { view, notices, opened } = await createView(memoryVault({}));
  assert.equal(await view.openNote('and/or'), false);
  assert.deepEqual(opened, []);
  assert.match(notices[0], /Vocabulary\/and-or\.md/);
});
