'use strict';

/*
 * Zero-dependency syntax highlighting for diff lines.
 *
 * A small spec-driven tokenizer: the engine below understands comments,
 * strings, keywords, numbers, attributes/directives, and types-by-
 * capitalization; each language is just a spec object plus an extension
 * mapping. Adding a language means adding both — no engine changes.
 *
 * Lines are tokenized in display order with a `carry` threaded between
 * consecutive lines, so block comments and multiline strings survive line
 * breaks. A hunk that *starts* inside such a construct can't know it (the
 * opening is off-screen); those lines render unstyled until the construct
 * closes. Deliberate: cheap and predictable beats fetching whole files.
 *
 * Token types: com, str, int (string-interpolation delimiters), kw, num,
 * attr, type, plain.
 */

var SWIFT_KEYWORDS = new Set((
  'actor any as associatedtype async await borrowing break case catch class ' +
  'consuming continue convenience default defer deinit didSet do dynamic else ' +
  'enum extension fallthrough false fileprivate final for func get guard if ' +
  'import in indirect infix init inout internal is isolated lazy let macro ' +
  'mutating nil nonisolated nonmutating open operator optional override ' +
  'package postfix precedencegroup prefix private protocol public repeat ' +
  'required rethrows return self Self set some static struct subscript super ' +
  'switch throw throws true try typealias unowned var weak where while willSet'
).split(' '));

var LANG_SPECS = {
  swift: {
    keywords: SWIFT_KEYWORDS,
    lineComment: '//',
    blockComment: true,   // /* … */, and Swift's nest
    tripleStrings: true,  // """ … """
    hashStrings: true,    // #"…"#, ##"…"## (raw)
    interpolation: true,  // \( … ) — \#( … ) in raw strings
    attributes: true,     // @MainActor
    directives: true,     // #if, #available, …
  },
};

var EXT_LANG = { swift: 'swift' };

function specForPath(path) {
  const m = /\.([^./]+)$/.exec(path || '');
  const lang = m && EXT_LANG[m[1].toLowerCase()];
  return lang ? LANG_SPECS[lang] : null;
}

var IDENT_RE = /^[A-Za-z_][A-Za-z0-9_]*/;
var NUM_RE = /^(?:0x[0-9a-fA-F_]+|0b[01_]+|0o[0-7_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d[\d_]*)?)/;

// Tokenize one line. `carry` is null or the value returned by the previous
// line; returns {tokens: [{t, s}], carry}. Token strings concatenate back to
// exactly `text`.
function tokenizeLine(spec, text, carry) {
  const tokens = [];
  let i = 0;
  let plainFrom = 0;
  const out = (t, from, to) => { if (to > from) tokens.push({ t, s: text.slice(from, to) }); };
  const flushPlain = () => out('plain', plainFrom, i);

  // Inside /* … */ (possibly nested); `from` is where this comment token
  // starts on this line. Returns a carry if the line ends first.
  function blockComment(from, depth) {
    while (i < text.length) {
      if (text.startsWith('/*', i)) { depth += 1; i += 2; continue; }
      if (text.startsWith('*/', i)) {
        depth -= 1;
        i += 2;
        if (depth === 0) { out('com', from, i); plainFrom = i; return null; }
        continue;
      }
      i += 1;
    }
    out('com', from, i);
    return { mode: 'comment', depth };
  }

  // Inside a """ string; closes at """ followed by the raw-string hashes.
  function tripleBody(hashes, from) {
    const close = '"""' + '#'.repeat(hashes);
    const at = text.indexOf(close, i);
    if (at === -1) { i = text.length; out('str', from, i); return { mode: 'string3', hashes }; }
    i = at + close.length;
    out('str', from, i);
    plainFrom = i;
    return null;
  }

  // Single-line string body; `from` is the token start (hashes + quote
  // included). Unterminated single-line strings just end at EOL.
  function stringBody(hashes, from) {
    const close = '"' + '#'.repeat(hashes);
    const interp = '\\' + '#'.repeat(hashes) + '(';
    while (i < text.length) {
      if (spec.interpolation && text.startsWith(interp, i)) {
        out('str', from, i);
        out('int', i, i + interp.length);
        i += interp.length;
        plainFrom = i;
        code(true); // the interpolated expression, up to its closing ')'
        from = i;
        continue;
      }
      if (text[i] === '\\') { i += 2; continue; }
      if (text.startsWith(close, i)) {
        i += close.length;
        out('str', from, i);
        plainFrom = i;
        return;
      }
      i += 1;
    }
    out('str', from, i);
    plainFrom = i;
  }

  // The main scanner. interp=true means we're inside \( … ): return as soon
  // as the matching ')' closes. Returns a carry if the line ends inside a
  // multiline construct.
  function code(interp) {
    let depth = interp ? 1 : 0;
    plainFrom = i;
    while (i < text.length) {
      const c = text[i];
      if (interp && c === '(') { depth += 1; i += 1; continue; }
      if (interp && c === ')') {
        depth -= 1;
        if (depth === 0) {
          flushPlain();
          out('int', i, i + 1);
          i += 1;
          plainFrom = i;
          return null;
        }
        i += 1;
        continue;
      }
      if (spec.lineComment && text.startsWith(spec.lineComment, i)) {
        flushPlain();
        out('com', i, text.length);
        i = text.length;
        plainFrom = i;
        return null;
      }
      if (spec.blockComment && text.startsWith('/*', i)) {
        flushPlain();
        const from = i;
        i += 2;
        const c2 = blockComment(from, 1);
        if (c2) return c2;
        continue;
      }
      if (c === '"' || (spec.hashStrings && c === '#' && /^#+"/.test(text.slice(i)))) {
        flushPlain();
        const from = i;
        let hashes = 0;
        while (text[i] === '#') { hashes += 1; i += 1; }
        if (spec.tripleStrings && text.startsWith('"""', i)) {
          i += 3;
          const c2 = tripleBody(hashes, from);
          if (c2) return c2;
        } else {
          i += 1;
          stringBody(hashes, from);
        }
        continue;
      }
      if (spec.directives && c === '#' && IDENT_RE.test(text.slice(i + 1))) {
        flushPlain();
        const w = IDENT_RE.exec(text.slice(i + 1))[0];
        out('attr', i, i + 1 + w.length);
        i += 1 + w.length;
        plainFrom = i;
        continue;
      }
      if (spec.attributes && c === '@' && IDENT_RE.test(text.slice(i + 1))) {
        flushPlain();
        const w = IDENT_RE.exec(text.slice(i + 1))[0];
        out('attr', i, i + 1 + w.length);
        i += 1 + w.length;
        plainFrom = i;
        continue;
      }
      if (c >= '0' && c <= '9') {
        flushPlain();
        const m = NUM_RE.exec(text.slice(i));
        out('num', i, i + m[0].length);
        i += m[0].length;
        plainFrom = i;
        continue;
      }
      const idm = IDENT_RE.exec(text.slice(i));
      if (idm) {
        const w = idm[0];
        const t = spec.keywords.has(w) ? 'kw' : (/^[A-Z]/.test(w) ? 'type' : 'plain');
        if (t !== 'plain') {
          flushPlain();
          out(t, i, i + w.length);
          i += w.length;
          plainFrom = i;
        } else {
          i += w.length; // stays in the current plain run
        }
        continue;
      }
      i += 1; // operators / punctuation / whitespace: plain run
    }
    flushPlain();
    return null;
  }

  let endCarry;
  if (carry && carry.mode === 'comment') {
    endCarry = blockComment(0, carry.depth);
    if (!endCarry) endCarry = code(false);
  } else if (carry && carry.mode === 'string3') {
    endCarry = tripleBody(carry.hashes, 0);
    if (!endCarry) endCarry = code(false);
  } else {
    endCarry = code(false);
  }
  return { tokens, carry: endCarry };
}

var Highlight = { specForPath, tokenizeLine };
