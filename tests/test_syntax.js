'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const ctx = { console };
vm.createContext(ctx);
for (const name of ['highlight.min.js', 'syntax.js']) {
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'public', name), 'utf8'), ctx);
}

const { languageForPath, highlightLines } = ctx.Syntax;

let failures = 0;
function check(name, cond, detail) {
  if (!cond) { failures++; console.log('FAIL:', name, detail ?? ''); }
  else console.log('ok:', name);
}

const text = (html) => html.replace(/<[^>]*>/g, '')
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
  .replace(/&#x27;/g, "'").replace(/&amp;/g, '&');
const balanced = (html) =>
  (html.match(/<span /g) || []).length === (html.match(/<\/span>/g) || []).length;

// -- language lookup
check('swift', languageForPath('Sources/App/Foo.swift') === 'swift');
check('markdown alias', languageForPath('docs/README.md') !== null);
check('extension case', languageForPath('a/B.SWIFT') === 'swift');
check('unknown ext', languageForPath('a/b.zzz') === null);
check('no ext', languageForPath('LICENSE') === null);
check('Makefile by name', languageForPath('sub/Makefile') === 'makefile');
check('GNUmakefile by name', languageForPath('GNUmakefile') === 'makefile');
check('.mk by hljs alias', languageForPath('rules.mk') === 'mk');
check('.m is Objective-C', languageForPath('Foo/Bar.m') === 'objectivec');
check('prototype key is not a language', languageForPath('a.constructor') === null);
check('dot dir, no ext', languageForPath('a.b/c') === null);

// -- splitting
let lines = [
  'let a = 1 /* starts',
  '   middle of a comment',
  'ends */ let s = "x \\(f(1)) <&>"',
  '',
];
let out = highlightLines('swift', lines);
check('one html line per line', out.length === lines.length, out.length);
out.forEach((h, i) => {
  check('text round-trips ' + i, text(h) === lines[i], JSON.stringify(text(h)));
  check('spans balanced ' + i, balanced(h), h);
});
check('comment carries across lines', /^<span class="hljs-comment">/.test(out[1]), out[1]);
check('code resumes after comment', out[2].includes('<span class="hljs-keyword">let</span>'), out[2]);

lines = ['# Title', 'Some **bold** and `code`.', '```', 'inside', '```'];
out = highlightLines('md', lines);
check('md heading', out[0].includes('hljs-section'), out[0]);
check('md strong', out[1].includes('hljs-strong'), out[1]);
check('md fence spans lines', out[3].includes('hljs-code'), out[3]);
check('md round-trips', out.every((h, i) => text(h) === lines[i]));

out = highlightLines('objectivec', ['@interface Foo : NSObject', '@end']);
check('objc highlights', out[0].includes('hljs-'), out[0]);
out = highlightLines('makefile', ['all: build', '\tswift build $(FLAGS)']);
check('makefile highlights', out[0].includes('hljs-'), out[0]);

check('single empty line', highlightLines('swift', ['']).length === 1);

process.exit(failures ? 1 : 0);
