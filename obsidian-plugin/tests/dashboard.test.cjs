const test = require('node:test');
const assert = require('node:assert/strict');
const { createView, memoryVault } = require('./helpers.cjs');
test('dashboard review action excludes mastered words and starts with oldest learning word', async () => {
  const {view} = await createView(memoryVault({}));
  view.words = [
    {word:'known', status:'mastered', date:'2020-01-01'},
    {word:'recent', status:'new', date:'2026-11-21'},
    {word:'earlier', status:'learning', date:'2026-11-01'},
  ];
  view.render();
  const start = view.contentEl.findAll(e => e.cls === 'ws-start')[0];
  assert.equal(start.text, '开始复习 · 2 个词 →');
  start.onclick();
  assert.equal(view.tab, 'review');
  assert.deepEqual(Array.from(view.review.queue, w => w.word), ['earlier', 'recent']);
  assert.equal(view.review.revealed, false);
});
test('dashboard disables review when every word is mastered', async () => {
  const {view} = await createView(memoryVault({}));
  view.words = [{word:'known', status:'mastered'}];
  view.render();
  assert.equal(view.contentEl.findAll(e => e.cls === 'ws-start')[0].disabled, true);
});
