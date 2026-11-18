'use strict';

/*
 * Word-level highlighting within a changed line: given a deleted line and the added line that
 * replaced it, finds the stretches of each that differ, so a line where one word changed can
 * emphasize that word.
 */

// Words, runs of whitespace, and single other characters.
var WORD_RE = /\w+|\s+|[^\w\s]/g;

// Past this many tokens per line, skip the quadratic diff.
var MAX_TOKENS = 400;

// Below this share of text in common, the lines are rewrites rather than edits, and emphasizing
// nearly everything is noise.
var MIN_SIMILARITY = 0.5;

// Changed character ranges, `[start, end)`, in `a` and in `b`; null when the lines are too
// different (or too long) to be worth highlighting within.
function changedRanges(a, b) {
  const ta = a.match(WORD_RE) || [];
  const tb = b.match(WORD_RE) || [];
  if (ta.length > MAX_TOKENS || tb.length > MAX_TOKENS) return null;

  // Longest common subsequence of tokens; lcs[i][j] covers ta[i..], tb[j..].
  const lcs = Array.from({ length: ta.length + 1 }, () => new Int32Array(tb.length + 1));
  for (let i = ta.length - 1; i >= 0; i--) {
    for (let j = tb.length - 1; j >= 0; j--) {
      lcs[i][j] = ta[i] === tb[j]
        ? lcs[i + 1][j + 1] + 1
        : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }

  const rangesA = [];
  const rangesB = [];
  // Extends the last range when only whitespace separates it from this one.
  const mark = (ranges, line, start, len) => {
    const last = ranges[ranges.length - 1];
    if (last && !line.slice(last[1], start).trim()) last[1] = start + len;
    else ranges.push([start, start + len]);
  };
  let i = 0, j = 0, pa = 0, pb = 0, common = 0;
  while (i < ta.length || j < tb.length) {
    if (i < ta.length && j < tb.length && ta[i] === tb[j]) {
      common += ta[i].length;
      pa += ta[i++].length;
      pb += tb[j++].length;
    } else if (j < tb.length && (i === ta.length || lcs[i][j + 1] >= lcs[i + 1][j])) {
      mark(rangesB, b, pb, tb[j].length);
      pb += tb[j++].length;
    } else {
      mark(rangesA, a, pa, ta[i].length);
      pa += ta[i++].length;
    }
  }

  if (2 * common < MIN_SIMILARITY * (a.length + b.length)) return null;
  return { a: rangesA, b: rangesB };
}

var TAG_OR_ENTITY_RE = /<[^>]*>|&[^;]*;/g;

// Wraps the text in character ranges of `html` (escaped text, optionally with tags) in
// `<mark class="wd">`, closing and reopening the mark around tags so nesting stays valid.
function markRanges(html, ranges) {
  if (!ranges.length) return html;
  let out = '';
  let pos = 0; // offset in the unescaped text
  let r = 0;
  let open = false;
  const sync = () => {
    while (r < ranges.length && pos >= ranges[r][1]) r++;
    const want = r < ranges.length && pos >= ranges[r][0];
    if (want !== open) { out += want ? '<mark class="wd">' : '</mark>'; open = want; }
  };
  const text = (s) => { for (const ch of s) { sync(); out += ch; pos += ch.length; } };
  let last = 0;
  for (const m of html.matchAll(TAG_OR_ENTITY_RE)) {
    text(html.slice(last, m.index));
    last = m.index + m[0].length;
    if (m[0][0] === '&') {
      sync();
      out += m[0];
      pos += 1;
    } else {
      if (open) { out += '</mark>'; open = false; }
      out += m[0];
    }
  }
  text(html.slice(last));
  if (open) out += '</mark>';
  return out;
}

var WordDiff = { changedRanges, markRanges };
