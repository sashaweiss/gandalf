'use strict';
const fs = require('fs');
const vm = require('vm');

// Minimal DOM/fetch stubs so app.js can be evaluated headlessly.
const stubEl = () => ({
  addEventListener() {}, textContent: '', innerHTML: '', hidden: false, value: '',
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
  window: { addEventListener() {} },
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

const { buildTree, treeRows, treeDirPaths, filterTokens, matchesFilter, markName } = ctx;
let failures = 0;
function check(name, cond, detail) {
  if (!cond) { failures++; console.log('FAIL:', name, detail ?? ''); }
  else console.log('ok:', name);
}
const eq = (name, got, want) =>
  check(name, JSON.stringify(got) === JSON.stringify(want), `got ${JSON.stringify(got)}`);

const f = (p, extra) => Object.assign(
  { path: p, status: 'modified', binary: false, additions: 1, deletions: 0 }, extra);

// A tree with a nested chain (docs/design), two files sharing a folder, and
// a file at the root.
const files = [
  f('README.md'),
  f('public/app.js'),
  f('public/style.css'),
  f('docs/design/notes.md'),
  f('tests/test_filetree.js', { status: 'added' }),
];

const rows = (fs_, folded) => treeRows(buildTree(fs_), folded || new Set())
  .map((r) => r.type[0] + ':' + (r.type === 'dir' ? r.name : r.path) + '@' + r.depth);

// Folders first (alphabetical), then files; a lone sub-folder chain is one row.
eq('rows: folders before files, chain compressed', rows(files), [
  'd:docs/design@0', 'f:docs/design/notes.md@1',
  'd:public@0', 'f:public/app.js@1', 'f:public/style.css@1',
  'd:tests@0', 'f:tests/test_filetree.js@1',
  'f:README.md@0',
]);

// The compressed row is keyed by its deepest path, so folding it hides the
// files under it and nothing else.
eq('folding a compressed folder hides its files', rows(files, new Set(['docs/design'])), [
  'd:docs/design@0',
  'd:public@0', 'f:public/app.js@1', 'f:public/style.css@1',
  'd:tests@0', 'f:tests/test_filetree.js@1',
  'f:README.md@0',
]);

const dirRow = treeRows(buildTree(files), new Set())[0];
check('folder rows carry a file count', dirRow.count === 1, JSON.stringify(dirRow.count));
eq('folder paths are the fold keys', treeDirPaths(buildTree(files)).sort(),
  ['docs/design', 'public', 'tests']);

// A folder with files *and* one sub-folder is not merged.
eq('a folder with its own files is not merged',
  rows([f('a/x.js'), f('a/b/y.js')]),
  ['d:a@0', 'd:b@1', 'f:a/b/y.js@2', 'f:a/x.js@1']);

// ---- filtering ----
eq('tokens split on whitespace', filterTokens('  Public  STYLE '), ['public', 'style']);
eq('empty query has no tokens', filterTokens('   '), []);
check('all tokens must match the path',
  matchesFilter(f('public/style.css'), ['public', 'css']));
check('a token that misses rejects the file',
  !matchesFilter(f('public/style.css'), ['public', 'swift']));
check('matching is case-insensitive',
  matchesFilter(f('Public/App.js'), ['app']));
check('a rename matches its old path too',
  matchesFilter(f('new.js', { status: 'renamed', oldPath: 'legacy/old.js' }), ['legacy']));

// ---- match marking ----
eq('marks every hit, merging overlaps', markName('style.css', ['sty', 'yle']),
  '<mark>style</mark>.css');
eq('a folder-only match marks nothing in the name', markName('app.js', ['public']), 'app.js');
eq('marking escapes the name', markName('a<b>&c.js', ['<b>']),
  'a<mark>&lt;b&gt;</mark>&amp;c.js');

console.log(failures ? `\n${failures} failure(s)` : '\nall passed');
process.exit(failures ? 1 : 0);
