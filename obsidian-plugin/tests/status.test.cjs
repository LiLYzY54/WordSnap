const assert = require('node:assert/strict');
const test = require('node:test');
const { createView, memoryVault } = require('./helpers.cjs');

const notePath = 'Vocabulary/apple.md';
const settings = { notesFolder: 'Vocabulary' };

test('grading preserves a concurrent edit to the note body', async () => {
  const original = '---\nword: apple\nstatus: new\n---\nOriginal body\n';
  const added = '\nA new example saved by another editor.\n';
  const vault = memoryVault({ [notePath]: original });
  const { view } = await createView(vault, settings);
  view.words = [{ word: 'apple', status: 'new' }];

  // With separate read/modify calls, read has captured a stale snapshot here.
  const grading = view.setStatus('apple', 'mastered');
  await vault.process(vault.getAbstractFileByPath(notePath), (text) => text + added);
  await grading;

  assert.equal(vault.contents.get(notePath), original.replace('status: new', 'status: mastered') + added);
  assert.equal(view.words[0].status, 'mastered');
});

test('grading preserves unrelated frontmatter and the complete note body', async () => {
  const original = [
    '---', 'word: apple', 'status: new', 'custom: "keep this"', '---',
    '# apple', '', 'status: new', '---', 'User annotation', '', 'apple::fruit', '',
  ].join('\n');
  const vault = memoryVault({ [notePath]: original });
  const { view } = await createView(vault, settings);
  view.words = [{ word: 'apple', status: 'new' }];

  await view.setStatus('apple', 'familiar');

  assert.equal(vault.contents.get(notePath), original.replace('status: new', 'status: familiar'));
});

test('a failed atomic write leaves the displayed status unchanged and reports failure', async () => {
  const original = '---\nword: apple\nstatus: new\n---\nUser annotation\n';
  const vault = memoryVault({ [notePath]: original });
  vault.process = async () => { throw new Error('Disk is read-only'); };
  vault.modify = async () => { throw new Error('Disk is read-only'); };
  const { view, notices } = await createView(vault, settings);
  view.words = [{ word: 'apple', status: 'new' }];

  assert.equal(await view.setStatus('apple', 'mastered'), false);

  assert.equal(view.words[0].status, 'new');
  assert.equal(vault.contents.get(notePath), original);
  assert.match(notices[0], /Disk is read-only/);
});

test('grading adds a missing status without changing existing properties or body', async () => {
  const original = '---\nword: apple\ncustom: keep\n---\n# apple\nUser annotation\n';
  const vault = memoryVault({ [notePath]: original });
  const { view } = await createView(vault, settings);

  assert.equal(await view.setStatus('apple', 'mastered'), true);

  assert.equal(vault.contents.get(notePath), original.replace('custom: keep\n', 'custom: keep\nstatus: mastered\n'));
});

test('grading a note without frontmatter prepends status and leaves body separators alone', async () => {
  const body = '# apple\n\nMy example\n---\nstatus: this is body text\n';
  const vault = memoryVault({ [notePath]: body });
  const { view } = await createView(vault, settings);

  assert.equal(await view.setStatus('apple', 'learning'), true);

  assert.equal(vault.contents.get(notePath), '---\nstatus: learning\n---\n' + body);
});

test('grading preserves CRLF line endings and updates a quoted status key', async () => {
  const original = '\uFEFF---\r\n"status": new\r\nword: apple\r\n---\r\nUser annotation\r\n';
  const vault = memoryVault({ [notePath]: original });
  const { view } = await createView(vault, settings);

  assert.equal(await view.setStatus('apple', 'familiar'), true);

  assert.equal(vault.contents.get(notePath), original.replace('"status": new', 'status: familiar'));
});

test('malformed frontmatter is left intact and reports a retryable failure', async () => {
  const original = '---\nword: apple\nstatus: new\n';
  const vault = memoryVault({ [notePath]: original });
  const { view, notices } = await createView(vault, settings);

  assert.equal(await view.setStatus('apple', 'mastered'), false);

  assert.equal(vault.contents.get(notePath), original);
  assert.match(notices[0], /结束分隔线/);
  assert.equal(view.pendingStatus.size, 0);
});
