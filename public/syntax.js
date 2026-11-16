'use strict';

/*
 * Syntax highlighting for diff lines, on top of the vendored highlight.js (`hljs`).
 *
 * hljs highlights whole documents, so callers pass a run of consecutive lines (one side of a
 * stretch of diff) and get back one HTML string per line. A run that starts inside a construct
 * whose opening is off-screen (a block comment, a fenced code block) can't know it; those lines
 * render as if it weren't there. Deliberate: cheap and predictable beats fetching whole files.
 */

// Paths hljs doesn't map on its own, by lowercased file name or extension.
var EXTRA_FILE_NAMES = { makefile: 'makefile', gnumakefile: 'makefile' };
var EXTRA_EXTENSIONS = { m: 'objectivec' };

// The hljs language for a path; null when hljs doesn't know it.
function languageForPath(path) {
  if (typeof hljs === 'undefined') return null;
  const name = (path || '').split('/').pop().toLowerCase();
  if (Object.hasOwn(EXTRA_FILE_NAMES, name)) return EXTRA_FILE_NAMES[name];
  const m = /\.([^.]+)$/.exec(name);
  if (!m) return null;
  if (Object.hasOwn(EXTRA_EXTENSIONS, m[1])) return EXTRA_EXTENSIONS[m[1]];
  return hljs.getLanguage(m[1]) ? m[1] : null;
}

var TAG_RE = /<span [^>]*>|<\/span>|\n/g;

// Highlights `lines` as one document, then splits the HTML back into lines, closing spans that
// are open at a line break and reopening them on the next line.
function highlightLines(language, lines) {
  const html = hljs.highlight(lines.join('\n'), { language, ignoreIllegals: true }).value;
  const out = [];
  const open = [];
  let line = '';
  let last = 0;
  for (const m of html.matchAll(TAG_RE)) {
    line += html.slice(last, m.index);
    last = m.index + m[0].length;
    if (m[0] === '\n') {
      out.push(line + '</span>'.repeat(open.length));
      line = open.join('');
    } else {
      if (m[0] === '</span>') open.pop(); else open.push(m[0]);
      line += m[0];
    }
  }
  out.push(line + html.slice(last));
  return out;
}

var Syntax = { languageForPath, highlightLines };
