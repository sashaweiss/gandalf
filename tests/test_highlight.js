'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const ctx = { console };
vm.createContext(ctx);
vm.runInContext(
  fs.readFileSync(path.join(__dirname, '..', 'public', 'highlight.js'), 'utf8'), ctx);

const { specForPath, tokenizeLine } = ctx.Highlight;
const swift = specForPath('Sources/App/Foo.swift');

let failures = 0;
function check(name, cond, detail) {
  if (!cond) { failures++; console.log('FAIL:', name, detail ?? ''); }
  else console.log('ok:', name);
}

// Tokenize a sequence of lines, threading the carry; returns array of token arrays.
function run(lines) {
  let carry = null;
  return lines.map((l) => {
    const res = tokenizeLine(swift, l, carry);
    carry = res.carry;
    res.tokens.carry = carry;
    return res.tokens;
  });
}
const joined = (toks) => toks.map((t) => t.s).join('');
const has = (toks, t, s) => toks.some((x) => x.t === t && x.s === s);

// -- spec lookup
check('swift by extension', swift !== null);
check('unknown ext is null', specForPath('a/b.rs') === null);
check('no ext is null', specForPath('Makefile') === null);

// -- round-tripping: tokens always reassemble the exact line
for (const line of [
  'let x = "a \\(f(1, g(2))) b" // tail',
  'value += 0x1F_e2 /* a /* b */ c */ @MainActor #if',
  '   indented && weird ##"raw"## chars…',
]) {
  const toks = tokenizeLine(swift, line, null).tokens;
  check('round-trip: ' + line.slice(0, 24), joined(toks) === line, JSON.stringify(joined(toks)));
}

// -- keywords, types, plain identifiers, numbers
let [t] = run(['let count: Int = compute(previous: 49)']);
check('kw let', has(t, 'kw', 'let'));
check('type Int', has(t, 'type', 'Int'));
check('plain ident stays plain', !t.some((x) => x.t !== 'plain' && x.s === 'compute'));
check('number', has(t, 'num', '49'));

[t] = run(['let big = 1_000_000.5, hex = 0xFF, r = 1...5']);
check('underscored float', has(t, 'num', '1_000_000.5'));
check('hex', has(t, 'num', '0xFF'));
check('range does not eat dots', has(t, 'num', '1') && has(t, 'num', '5'));

// -- comments
[t] = run(['let a = 1 // trailing note']);
check('line comment to EOL', has(t, 'com', '// trailing note'));

let ls = run(['before /* one', 'still /* nested */ inside', 'done */ let after = 2']);
check('block comment carries', ls[0].carry && ls[0].carry.mode === 'comment');
check('nested depth carries', ls[1].carry && ls[1].carry.depth === 1);
check('whole middle line is comment', ls[1].every((x) => x.t === 'com'));
check('comment closes, code resumes', has(ls[2], 'kw', 'let'));
check('carry cleared after close', ls[2].carry === null);

// -- strings
[t] = run(['let s = "hello \\"quoted\\" world"']);
check('escaped quotes stay in string', has(t, 'str', '"hello \\"quoted\\" world"'));

[t] = run(['let s = "count \\(items.count) end"']);
check('interpolation opens', has(t, 'int', '\\('));
check('interpolation closes', has(t, 'int', ')'));
check('string resumes after interpolation', has(t, 'str', ' end"'));

[t] = run(['let s = "n \\(f(a, (b))) m"']);
check('nested parens balance', has(t, 'str', ' m"'));

[t] = run(['let raw = #"no \\(interp) here"#']);
check('raw string swallows plain interpolation', has(t, 'str', '#"no \\(interp) here"#'));

[t] = run(['let raw = #"but \\#(x) works"#']);
check('raw-string interpolation', has(t, 'int', '\\#('));

ls = run(['let s = """', 'plain "quotes" fine', '""" + tail']);
check('triple string carries', ls[0].carry && ls[0].carry.mode === 'string3');
check('triple body all string', ls[1].every((x) => x.t === 'str'));
check('triple closes', has(ls[2], 'str', '"""') && ls[2].carry === null);

[t] = run(['let bad = "unterminated']);
check('unterminated string does not carry', t.carry === null);

// -- attributes / directives
[t] = run(['@MainActor func f() {}']);
check('attribute', has(t, 'attr', '@MainActor'));
check('kw func after attr', has(t, 'kw', 'func'));

[t] = run(['#if DEBUG']);
check('directive', has(t, 'attr', '#if'));

// -- Self is a keyword, not a type
[t] = run(['return Self.shared']);
check('Self keyword', has(t, 'kw', 'Self'));

process.exit(failures ? 1 : 0);
