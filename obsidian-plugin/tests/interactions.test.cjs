const assert = require('node:assert/strict');
const test = require('node:test');
const { createView, memoryVault, deferred } = require('./helpers.cjs');

const notePath = 'Vocabulary/apple.md';
const original = '---\nword: apple\nstatus: new\n---\nMy example\n';
const settings = { notesFolder: 'Vocabulary' };

function showReview(view) {
  view.words = ['apple', 'banana', 'cherry'].map((word) => ({ word, status: 'new' }));
  view.tab = 'review';
  view.startReview();
  view.review.revealed = true;
  view.render();
}

function grades(view) {
  return view.contentEl.findAll((element) => element.cls === 'ws-grade');
}

function pill(view) {
  return view.contentEl.findAll((element) => element.cls?.startsWith('ws-pill '))[0];
}

test('two different grades clicked before saving write and advance only once', async () => {
  const vault = memoryVault({ [notePath]: original });
  const gate = deferred();
  const process = vault.process.bind(vault);
  let writes = 0;
  vault.process = async (...args) => { writes++; await gate.promise; return process(...args); };
  const { view } = await createView(vault, settings);
  showReview(view);
  const buttons = grades(view);

  const first = buttons[3].onclick();
  const second = buttons[0].onclick();
  assert.equal(buttons.every((button) => button.disabled), true);
  assert.equal(writes, 1);
  gate.resolve();
  await Promise.all([first, second]);

  assert.equal(view.review.index, 1);
  assert.equal(view.review.queue[view.review.index].word, 'banana');
  assert.match(vault.contents.get(notePath), /status: mastered/);
  assert.equal(view.review.saving, false);
});

test('a failed grade remains on the same revealed card and can be retried', async () => {
  const vault = memoryVault({ [notePath]: original });
  const process = vault.process.bind(vault);
  vault.process = async () => { throw new Error('Disk is read-only'); };
  const { view, notices } = await createView(vault, settings);
  showReview(view);

  await grades(view)[3].onclick();

  assert.equal(view.review.index, 0);
  assert.equal(view.review.revealed, true);
  assert.equal(view.words[0].status, 'new');
  assert.equal(grades(view).every((button) => !button.disabled), true);
  assert.match(notices[0], /状态未保存/);
  vault.process = process;
  await grades(view)[3].onclick();

  assert.equal(view.review.index, 1);
  assert.equal(view.words[0].status, 'mastered');
});

test('a missing note does not advance review and can be retried once created', async () => {
  const vault = memoryVault({});
  const { view, notices } = await createView(vault, settings);
  showReview(view);

  await grades(view)[3].onclick();

  assert.equal(view.review.index, 0);
  assert.equal(view.review.revealed, true);
  assert.equal(view.words[0].status, 'new');
  assert.match(notices[0], /词笔记不存在/);
  vault.contents.set(notePath, original);
  await grades(view)[3].onclick();
  assert.equal(view.review.index, 1);
});

for (const failure of ['missing note', 'failed write']) {
  test(`a status badge does not change after ${failure}`, async () => {
    const vault = memoryVault(failure === 'missing note' ? {} : { [notePath]: original });
    if (failure === 'failed write') vault.process = async () => { throw new Error('Disk is read-only'); };
    const { view } = await createView(vault, settings);
    view.words = [{ word: 'apple', status: 'new' }];
    view.render();

    await pill(view).onclick();

    assert.equal(view.words[0].status, 'new');
    assert.equal(pill(view).text, '新词');
    assert.equal(pill(view).disabled, false);
  });
}

test('a status badge locks synchronously and can retry a failed write', async () => {
  const vault = memoryVault({ [notePath]: original });
  const gate = deferred();
  const process = vault.process.bind(vault);
  let writes = 0;
  vault.process = async () => { writes++; await gate.promise; throw new Error('Disk is read-only'); };
  const { view } = await createView(vault, settings);
  view.words = [{ word: 'apple', status: 'new' }];
  view.render();
  const button = pill(view);

  const first = button.onclick();
  const second = button.onclick();
  assert.equal(writes, 1);
  assert.equal(button.disabled, true);
  gate.resolve();
  await Promise.all([first, second]);
  vault.process = process;
  await pill(view).onclick();

  assert.equal(view.words[0].status, 'learning');
  assert.equal(pill(view).text, '学习中');
});
