'use strict';
const fs = require('fs');
const vm = require('vm');

// Minimal DOM/fetch stubs so app.js can be evaluated headlessly.
const stubEl = () => ({
  addEventListener() {}, textContent: '', innerHTML: '', hidden: false,
  appendChild() {}, querySelector: () => null, querySelectorAll: () => [],
  setAttribute() {}, focus() {}, select() {}, blur() {},
  classList: { toggle() {}, add() {}, remove() {}, contains: () => false },
  dataset: {},
});
const ctx = {
  document: {
    body: stubEl(),
    querySelector: () => stubEl(),
    querySelectorAll: () => [],
    addEventListener() {},
    createElement: () => stubEl(),
    documentElement: { style: { setProperty() {} } },
  },
  ResizeObserver: class { observe() {} },
  getComputedStyle: () => ({ getPropertyValue: () => '' }),
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  sessionStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  fetch: () => new Promise(() => {}), // never resolves; load() just hangs
  setTimeout, clearTimeout, console, Map, Set, Promise, JSON, Math, Date, Number, Array, Object, String,
  setInterval: () => 0, clearInterval: () => {},
};
vm.createContext(ctx);
const path = require('path');
vm.runInContext(
  fs.readFileSync(path.join(__dirname, '..', 'public', 'app.js'), 'utf8'), ctx);

const buildRows = ctx.buildRows;
let failures = 0;
function check(name, cond, detail) {
  if (!cond) { failures++; console.log('FAIL:', name, detail ?? ''); }
  else console.log('ok:', name);
}

// A modified file: two hunks, 120-line new file.
// Hunk 1: new 2-8 (old 2-8, delta 0 at start), one del+add at line 5.
// Hunk 2: old 48-53 (6), new 48-54 (7) — insertion at new 51.
const file = {
  path: 'f', status: 'modified', binary: false, newTotal: 121,
  hunks: [
    { oldStart: 2, oldCount: 7, newStart: 2, newCount: 7, lines: [
      { t: 'ctx', old: 2, new: 2, text: 'l2' }, { t: 'ctx', old: 3, new: 3, text: 'l3' },
      { t: 'ctx', old: 4, new: 4, text: 'l4' },
      { t: 'del', old: 5, new: null, text: 'old5' }, { t: 'add', old: null, new: 5, text: 'new5' },
      { t: 'ctx', old: 6, new: 6, text: 'l6' }, { t: 'ctx', old: 7, new: 7, text: 'l7' },
      { t: 'ctx', old: 8, new: 8, text: 'l8' },
    ]},
    { oldStart: 48, oldCount: 6, newStart: 48, newCount: 7, lines: [
      { t: 'ctx', old: 48, new: 48, text: 'l48' }, { t: 'ctx', old: 49, new: 49, text: 'l49' },
      { t: 'ctx', old: 50, new: 50, text: 'l50' }, { t: 'add', old: null, new: 51, text: 'inserted' },
      { t: 'ctx', old: 51, new: 52, text: 'l52' }, { t: 'ctx', old: 52, new: 53, text: 'l53' },
      { t: 'ctx', old: 53, new: 54, text: 'l54' },
    ]},
  ],
};
const content = Array.from({ length: 121 }, (_, i) => 'content-' + (i + 1));

// 1. No expansion: expect gaps lead (1 hidden: line 1), mid (39: 9..47), tail (67: 55..121)
let rows = buildRows(file, { expansions: {}, content: null });
let gaps = rows.filter((r) => r.kind === 'gap');
check('three gaps', gaps.length === 3, JSON.stringify(gaps));
check('lead gap size', gaps[0].hidden === 1 && gaps[0].pos === 'lead');
check('mid gap size', gaps[1].hidden === 39 && gaps[1].pos === 'mid');
check('tail gap size', gaps[2].hidden === 67 && gaps[2].pos === 'tail');

// 2. Expand mid gap down 20: reveals new lines 9..28 (old === new, delta 0)
rows = buildRows(file, { expansions: { g1: { down: 20, up: 0 } }, content });
let ctxRows = rows.filter((r) => r.kind === 'line' && r.text.startsWith('content-'));
check('20 revealed', ctxRows.length === 20, ctxRows.length);
check('first revealed is new 9', ctxRows[0].new === 9 && ctxRows[0].old === 9);
check('text from content', ctxRows[0].text === 'content-9');
let midGap = rows.find((r) => r.kind === 'gap' && r.id === 'g1');
check('mid gap shrank to 19', midGap.hidden === 19, midGap && midGap.hidden);

// 3. Expand mid gap up 20: reveals new 28..47, old = new (delta 0 before hunk2)
rows = buildRows(file, { expansions: { g1: { down: 0, up: 20 } }, content });
ctxRows = rows.filter((r) => r.kind === 'line' && r.text.startsWith('content-'));
check('up reveals bottom of gap', ctxRows[0].new === 28 && ctxRows[ctxRows.length - 1].new === 47);

// 4. Tail gap: delta after hunk2 is (48+7)-(48+6)=1 → old = new - 1
rows = buildRows(file, { expansions: { g2: { down: 5, up: 0 } }, content });
ctxRows = rows.filter((r) => r.kind === 'line' && r.text.startsWith('content-'));
check('tail old numbers offset by delta', ctxRows[0].new === 55 && ctxRows[0].old === 54,
  JSON.stringify(ctxRows[0]));

// 5. Expand all: gap disappears entirely
rows = buildRows(file, { expansions: { g1: { down: Number.MAX_SAFE_INTEGER, up: 0 } }, content });
check('expand-all removes gap', !rows.some((r) => r.kind === 'gap' && r.id === 'g1'));
ctxRows = rows.filter((r) => r.kind === 'line' && r.text.startsWith('content-'));
check('expand-all reveals all 39', ctxRows.length === 39, ctxRows.length);

// 6. over-expansion clamps (down 100 + up 100 on a 39-line gap)
rows = buildRows(file, { expansions: { g1: { down: 100, up: 100 } }, content });
ctxRows = rows.filter((r) => r.kind === 'line' && r.text.startsWith('content-'));
check('over-expansion clamps to gap size', ctxRows.length === 39, ctxRows.length);
const dupes = new Set(ctxRows.map((r) => r.new));
check('no duplicate revealed lines', dupes.size === 39);

// 7. deleted file: no gaps at all
const del = { path: 'd', status: 'deleted', binary: false, newTotal: null,
  hunks: [{ oldStart: 1, oldCount: 2, newStart: 0, newCount: 0, lines: [
    { t: 'del', old: 1, new: null, text: 'a' }, { t: 'del', old: 2, new: null, text: 'b' }] }] };
rows = buildRows(del, { expansions: {}, content: null });
check('deleted file has no gaps', !rows.some((r) => r.kind === 'gap'));

// 8. display indices are sequential over line rows
rows = buildRows(file, { expansions: { g1: { down: 20, up: 0 } }, content });
const dis = rows.filter((r) => r.kind === 'line').map((r) => r.di);
check('di sequential', dis.every((d, i) => d === i));

// 9. old-side comments only anchor in the view they were made in
const comments = [
  { id: 'a', side: 'new', startLine: 5, endLine: 5, text: 'n' },
  { id: 'b', side: 'old', startLine: 5, endLine: 5, text: 'full-view old' },
  { id: 'c', side: 'old', startLine: 5, endLine: 5, baseline: 3, text: 'delta-view old' },
];
let anchors = ctx.commentsByAnchor(comments, null);
check('full view: new + unbaselined old anchor',
  anchors.get('new:5').length === 1 && anchors.get('old:5').length === 1);
check('full view: delta-baselined old excluded',
  !anchors.get('old:5').some((c) => c.id === 'c'));
anchors = ctx.commentsByAnchor(comments, 3);
check('delta view: matching-baseline old anchors',
  anchors.get('old:5').length === 1 && anchors.get('old:5')[0].id === 'c');
check('delta view: new-side always anchors', anchors.get('new:5').length === 1);
const cov = ctx.coverageSet(comments, null);
check('coverage respects view', cov.has('new:5') && cov.has('old:5'));

// 10. file-level comments never anchor to lines or cover them
const withFile = comments.concat([{ id: 'f', fileLevel: true, text: 'whole file' }]);
check('file-level comment not anchored',
  ![...ctx.commentsByAnchor(withFile, null).values()].flat().some((c) => c.id === 'f'));
check('file-level comment not in coverage',
  ctx.coverageSet(withFile, null).size === cov.size);
check('labels', ctx.rangeLabel({ fileLevel: true }) === 'file comment'
  && ctx.rangeLabel({ reviewLevel: true }) === 'review comment'
  && ctx.rangeLabel({ parentId: 'x' }) === 'reply');

// 11. replies never anchor or cover; they render inside their parent's thread
const withReply = comments.concat([{ id: 'r', parentId: 'a', text: 'follow-up' }]);
check('reply not anchored',
  ![...ctx.commentsByAnchor(withReply, null).values()].flat().some((c) => c.id === 'r'));
check('reply not in coverage', ctx.coverageSet(withReply, null).size === cov.size);
const thread = ctx.threadHtml(withReply[0], withReply, { form: null }, false);
check('thread contains root and reply text',
  thread.includes('follow-up') && thread.includes('Reply'));

// 12. split view: rows zip into side-by-side pairs
const pairRows = ctx.pairRows;
rows = buildRows(file, { expansions: {}, content: null });
let pairs = pairRows(rows);
check('gaps and hunk heads pass through',
  pairs.filter((p) => p.kind === 'gap').length === 3
  && pairs.filter((p) => p.kind === 'hunkhead').length === 2);
check('every line row appears exactly once',
  pairs.filter((p) => p.kind === 'pair')
    .flatMap((p) => (p.left === p.right ? [p.left] : [p.left, p.right]))
    .filter(Boolean).length === rows.filter((r) => r.kind === 'line').length);
check('context spans both columns',
  pairs.filter((p) => p.kind === 'pair' && p.left && p.left.t === 'ctx')
    .every((p) => p.left === p.right));
const replaced = pairs.find((p) => p.kind === 'pair' && p.left && p.left.t === 'del');
check('a replacement pairs del with add',
  replaced.left.text === 'old5' && replaced.right.text === 'new5');
const inserted = pairs.find((p) => p.kind === 'pair' && p.left === null);
check('a lone insertion pairs with a blank left',
  inserted.right.text === 'inserted' && inserted.right.t === 'add');

// 13. uneven change blocks: the longer side's leftovers get blank partners
const uneven = { path: 'u', status: 'modified', binary: false, newTotal: null, hunks: [
  { oldStart: 1, oldCount: 4, newStart: 1, newCount: 2, lines: [
    { t: 'ctx', old: 1, new: 1, text: 'keep' },
    { t: 'del', old: 2, new: null, text: 'd1' }, { t: 'del', old: 3, new: null, text: 'd2' },
    { t: 'del', old: 4, new: null, text: 'd3' }, { t: 'add', old: null, new: 2, text: 'a1' },
  ] }] };
pairs = pairRows(buildRows(uneven, { expansions: {}, content: null }))
  .filter((p) => p.kind === 'pair');
check('context + 3 dels + 1 add make 4 rows', pairs.length === 4, pairs.length);
check('first del takes the add', pairs[1].left.text === 'd1' && pairs[1].right.text === 'a1');
check('later dels get blank right cells',
  pairs[2].right === null && pairs[3].right === null);

// 14. an add run followed by a del run starts a new block (dels stay left)
const blocks = [
  { kind: 'line', di: 0, t: 'add', old: null, new: 1, text: 'a' },
  { kind: 'line', di: 1, t: 'del', old: 1, new: null, text: 'd' },
];
pairs = pairRows(blocks);
check('add then del does not share a row',
  pairs.length === 2 && pairs[0].left === null && pairs[1].right === null);

// 15. a split-view selection is scoped to the column it was dragged in
const selectionRows = ctx.selectionRows;
const selectionAnchor = ctx.selectionAnchor;
rows = buildRows(file, { expansions: {}, content: null });
const di = (text) => rows.find((r) => r.kind === 'line' && r.text === text).di;
const span = [di('old5'), di('l8')]; // del5, add5, l6, l7, l8

check('inline selection keeps both sides',
  selectionRows(rows, span[0], span[1], null).length === 5);
check('old column drops the additions',
  selectionRows(rows, span[0], span[1], 'old').map((r) => r.text)
    .join(',') === 'old5,l6,l7,l8');
check('new column drops the deletions',
  selectionRows(rows, span[0], span[1], 'new').map((r) => r.text)
    .join(',') === 'new5,l6,l7,l8');

// Deletions plus context anchor on the new side (an old-side anchor over
// context would detach), but the excerpt still quotes the deleted line.
let anchor = selectionAnchor(selectionRows(rows, span[0], span[1], 'old'));
check('mixed old-column selection anchors on the new side',
  anchor.side === 'new' && anchor.startLine === 6 && anchor.endLine === 8,
  JSON.stringify(anchor));
check('excerpt keeps the deleted line', anchor.excerpt[0] === '-old5');

// An all-deletions selection is the one case that anchors on the old side.
anchor = selectionAnchor(selectionRows(rows, di('old5'), di('old5'), 'old'));
check('pure deletion selection anchors on the old side',
  anchor.side === 'old' && anchor.startLine === 5 && anchor.endLine === 5);

anchor = selectionAnchor(selectionRows(rows, span[0], span[1], 'new'));
check('new-column selection anchors on its own lines',
  anchor.side === 'new' && anchor.startLine === 5 && anchor.endLine === 8);

process.exit(failures ? 1 : 0);
