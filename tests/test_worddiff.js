'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const ctx = { console };
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'public', 'worddiff.js'), 'utf8'), ctx);

const { changedRanges, markRanges } = ctx.WordDiff;

let failures = 0;
function check(name, cond, detail) {
  if (!cond) { failures++; console.log('FAIL:', name, detail ?? ''); }
  else console.log('ok:', name);
}
const same = (x, y) => JSON.stringify(x) === JSON.stringify(y);

// -- ranges
let r = changedRanges('let count = 1', 'let total = 1');
check('one word', same(r, { a: [[4, 9]], b: [[4, 9]] }), JSON.stringify(r));
r = changedRanges('foo(a)', 'foo(a, b)');
check('pure insertion', same(r, { a: [], b: [[5, 8]] }), JSON.stringify(r));
r = changedRanges('return x', 'return x;');
check('trailing punctuation', same(r, { a: [], b: [[8, 9]] }), JSON.stringify(r));
r = changedRanges('a b c d', 'a x y d');
check('adjacent tokens merge', same(r, { a: [[2, 5]], b: [[2, 5]] }), JSON.stringify(r));
check('rewrite is skipped', changedRanges('import Foundation', 'let x = makeThing()') === null);
check('empty lines', same(changedRanges('', ''), { a: [], b: [] }));

// -- marking
check('plain text', markRanges('let total = 1', [[4, 9]]) === 'let <mark class="wd">total</mark> = 1');
check('no ranges', markRanges('a &lt; b', []) === 'a &lt; b');
check('entity counts as one char',
  markRanges('a &lt; b', [[2, 3]]) === 'a <mark class="wd">&lt;</mark> b');
check('mark splits around tags',
  markRanges('<span class="k">let</span> x', [[1, 5]])
    === '<span class="k">l<mark class="wd">et</mark></span><mark class="wd"> x</mark>');
check('mark inside a span',
  markRanges('<span class="s">"abc"</span>', [[1, 4]])
    === '<span class="s">"<mark class="wd">abc</mark>"</span>');

console.log(failures ? `\n${failures} failure(s)` : '\nall passed');
process.exit(failures ? 1 : 0);
