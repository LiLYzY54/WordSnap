const assert = require('node:assert/strict');
const test = require('node:test');
const { createView, memoryVault, fakeTimers } = require('./helpers.cjs');

const tablePath = 'English Vocabulary Learning.md';
const notePath = 'Vocabulary/apple.md';
const row = '| [[apple]] | | | fruit | example | Youdao | 2026-11-21 |\n';
const note = '---\nword: apple\nstatus: mastered\n---\nMy example\n';

test('first table creation, later note creation and delayed metadata all refresh automatically', async () => {
  const vault = memoryVault({});
  const timers = fakeTimers();
  const { view, app } = await createView(vault, {}, timers);
  let cache = null;
  app.metadataCache.getFileCache = () => cache;
  await view.onOpen();
  assert.match(view.loadError, /未找到词汇表/);

  vault.contents.set(tablePath, row);
  vault.trigger('create', { path: tablePath });
  await timers.flush();
  assert.equal(view.loadError, '');
  assert.equal(view.words.length, 1);
  assert.equal(view.words[0].hasNote, false);

  vault.contents.set(notePath, note);
  vault.trigger('create', { path: notePath });
  await timers.flush();
  assert.equal(view.words[0].hasNote, true);
  assert.equal(view.words[0].status, 'new');
  assert.equal(view.pathWarning, '');

  // Obsidian may finish parsing frontmatter after the file event debounce.
  cache = { frontmatter: { status: 'mastered' } };
  app.metadataCache.trigger('changed', { path: notePath }, note, cache);
  await timers.flush();
  assert.equal(view.words[0].status, 'mastered');
});

test('deleting notes and the table removes stale cards and file metadata', async () => {
  const vault = memoryVault({ [tablePath]: row, [notePath]: note });
  const timers = fakeTimers();
  const { view, app } = await createView(vault, {}, timers);
  app.metadataCache.getFileCache = () => ({ frontmatter: { status: 'mastered' } });
  await view.onOpen();

  vault.contents.delete(notePath);
  vault.trigger('delete', { path: notePath });
  await timers.flush();
  assert.equal(view.words[0].hasNote, false);
  assert.equal(view.words[0].status, 'new');

  vault.contents.delete(tablePath);
  vault.trigger('delete', { path: tablePath });
  await timers.flush();
  assert.match(view.loadError, /未找到词汇表/);
  assert.equal(view.words.length, 0);
});

test('renaming the table away from and back into its configured path refreshes both times', async () => {
  const vault = memoryVault({ [tablePath]: row, [notePath]: note });
  const timers = fakeTimers();
  const { view } = await createView(vault, {}, timers);
  await view.onOpen();

  vault.contents.delete(tablePath);
  vault.contents.set('Archive.md', row);
  vault.trigger('rename', { path: 'Archive.md' }, tablePath);
  await timers.flush();
  assert.match(view.loadError, /未找到词汇表/);

  vault.contents.delete('Archive.md');
  vault.contents.set(tablePath, row);
  vault.trigger('rename', { path: tablePath }, 'Archive.md');
  await timers.flush();
  assert.equal(view.loadError, '');
  assert.equal(view.words.length, 1);
});

for (const renamed of ['note', 'folder']) {
  test(`renaming a ${renamed} out of and into Vocabulary updates note availability`, async () => {
    const vault = memoryVault({ [tablePath]: row, [notePath]: note });
    const timers = fakeTimers();
    const { view } = await createView(vault, {}, timers);
    await view.onOpen();
    const oldPath = renamed === 'note' ? notePath : 'Vocabulary';
    const newPath = renamed === 'note' ? 'Archive/apple.md' : 'Archive';

    vault.contents.delete(notePath);
    vault.contents.set('Archive/apple.md', note);
    vault.trigger('rename', { path: newPath }, oldPath);
    await timers.flush();
    assert.equal(view.words[0].hasNote, false);

    vault.contents.delete('Archive/apple.md');
    vault.contents.set(notePath, note);
    vault.trigger('rename', { path: oldPath }, newPath);
    await timers.flush();
    assert.equal(view.words[0].hasNote, true);
  });
}

test('unrelated file events are ignored and a related burst is debounced', async () => {
  const vault = memoryVault({ [tablePath]: row, [notePath]: note });
  const timers = fakeTimers();
  const { view, app } = await createView(vault, {}, timers);
  await view.onOpen();

  for (const event of ['create', 'modify', 'delete', 'rename']) {
    vault.trigger(event, { path: 'Other/note.md' }, 'Other/old.md');
  }
  app.metadataCache.trigger('changed', { path: 'Other/note.md' });
  assert.equal(timers.pendingCount, 0);

  vault.trigger('modify', { path: tablePath });
  vault.trigger('create', { path: notePath });
  app.metadataCache.trigger('changed', { path: notePath });
  assert.equal(timers.pendingCount, 1);
  await timers.flush();
  assert.equal(timers.pendingCount, 0);
});

test('closing the view cancels a pending file-event refresh', async () => {
  const vault = memoryVault({ [tablePath]: row, [notePath]: note });
  const timers = fakeTimers();
  const { view } = await createView(vault, {}, timers);
  await view.onOpen();
  vault.trigger('create', { path: notePath });
  assert.equal(timers.pendingCount, 1);

  await view.onClose();

  assert.equal(timers.pendingCount, 0);
});
