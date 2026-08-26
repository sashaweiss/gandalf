'use strict';

/* ------------------------------------------------------------------ utils */

const $ = (sel) => document.querySelector(sel);

const ESC_MAP = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ESC_MAP[c]);

async function api(path, opts) {
  const res = await fetch(path, opts);
  let data = null;
  try { data = await res.json(); } catch (_) { /* non-JSON body */ }
  if (!res.ok) throw new Error((data && data.error) || res.status + ' ' + res.statusText);
  return data;
}

function postJson(path, body) {
  return api(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

let toastTimer = null;
function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 3500);
}

function showError(msg) {
  const b = $('#banner');
  b.textContent = msg;
  b.hidden = false;
}

/* ------------------------------------------------------------------ state */

const EXPAND_STEP = 20;

let review = null; // /api/review payload
let drafts = [];   // draft comments, mirrored to the server as they change

// What the working tree is diffed against: null = the base ref (the full
// diff), a revision number = that review's snapshot (only what changed since
// it). Remembered per tab so a mid-loop page reload keeps the lens.
const BASELINE_KEY = 'gandalf.baseline';
let baseline = null;
try { baseline = +sessionStorage.getItem(BASELINE_KEY) || null; } catch (_) { /* fine */ }

function setBaseline(n) {
  baseline = n;
  try {
    if (n == null) sessionStorage.removeItem(BASELINE_KEY);
    else sessionStorage.setItem(BASELINE_KEY, String(n));
  } catch (_) { /* private mode etc.; the in-memory value still works */ }
}

// Ignore-whitespace is a per-machine display preference (like the code
// font): the server diffs with `-w`, so whitespace-only changes neither
// render nor trip the staleness banner while it's on.
const WS_KEY = 'gandalf.ignoreWs';
let ignoreWs = false;
try { ignoreWs = localStorage.getItem(WS_KEY) === '1'; } catch (_) { /* fine */ }

// Inline (unified, one column) vs split (side-by-side) diffs — a per-machine
// display preference like the code font. Below MIN_SPLIT_PX there is no room
// for two code columns, so split renders inline until the window grows again
// (GitHub does the same); the toggle keeps showing what was chosen.
const VIEW_KEY = 'gandalf.diffView';
const MIN_SPLIT_PX = 1000;
let diffView = 'inline';
try { if (localStorage.getItem(VIEW_KEY) === 'split') diffView = 'split'; } catch (_) { /* fine */ }

// Whether the sidebar is up at all (per-machine, like the code font). The
// tree only navigates; hiding it changes nothing about the review.
const TREE_KEY = 'gandalf.fileTree';
let treeShown = true;
try { treeShown = localStorage.getItem(TREE_KEY) !== '0'; } catch (_) { /* fine */ }

// The file tree is a sidebar, so it takes width away from the diff: split
// needs MIN_SPLIT_PX of *diff* room, which is MIN_SPLIT_PX + TREE_PX of
// window while the tree is up. Below MIN_TREE_PX the sidebar hides itself
// (the same breakpoint as the CSS rule), and the diff gets the window back.
// TREE_PX/MIN_TREE_PX mirror --tree-w and the media query in style.css.
const TREE_PX = 260;
const MIN_TREE_PX = 900;
// Guarded so the headless test harness (no matchMedia/rAF) still loads app.js.
const raf = typeof requestAnimationFrame === 'function'
  ? requestAnimationFrame : (fn) => setTimeout(fn, 16);
const mq = (px) => (typeof matchMedia === 'function' ? matchMedia(`(min-width: ${px}px)`) : null);
const wideQuery = mq(MIN_SPLIT_PX);
const wideTreeQuery = mq(MIN_SPLIT_PX + TREE_PX);
const treeQuery = mq(MIN_TREE_PX);
const roomForTree = () => !treeQuery || treeQuery.matches;
const treeVisible = () => treeShown && roomForTree();
const wideEnough = () => {
  const q = treeVisible() ? wideTreeQuery : wideQuery;
  return !q || q.matches;
};
const splitView = () => diffView === 'split' && wideEnough();


function fetchReview() {
  const params = new URLSearchParams();
  if (baseline) params.set('since', baseline);
  if (ignoreWs) params.set('ws', '1');
  const qs = params.toString();
  return api('/api/review' + (qs ? '?' + qs : ''));
}

// Per-file UI state for the *current* (editable) view.
// path -> { collapsed, expansions: {gapId: {down, up}}, content, form, formText }
const fileUI = new Map();
const fileSections = new Map(); // path -> <section> element in #files

function getUI(path) {
  if (!fileUI.has(path)) {
    fileUI.set(path, { collapsed: false, expansions: {}, content: null, form: null, formText: '' });
  }
  return fileUI.get(path);
}

function draftsFor(path) {
  return drafts.filter((c) => c.file === path);
}

function reviewLevelDrafts() {
  return drafts.filter((c) => c.reviewLevel);
}

const genId = () => 'c' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7);

let draftSaveTimer = null;
function scheduleDraftSave() {
  clearTimeout(draftSaveTimer);
  draftSaveTimer = setTimeout(flushDrafts, 400);
}
function flushDrafts() {
  if (draftSaveTimer === null) return Promise.resolve();
  clearTimeout(draftSaveTimer);
  draftSaveTimer = null;
  return postJson('/api/drafts', { drafts }).catch((e) => toast('Draft save failed: ' + e.message));
}

/* --------------------------------------------------- display-row building */

// Flattens a file's hunks (plus any expanded context) into display rows.
// Rows: {kind:'line', di, t:'add'|'del'|'ctx', old, new, text}
//       {kind:'gap', id, hidden, pos:'lead'|'mid'|'tail'}
function buildRows(file, ui) {
  const rows = [];
  let di = 0;
  const content = ui.content; // working-tree lines (new side), lazily fetched
  const line = (t, o, n, text) => rows.push({ kind: 'line', di: di++, t, old: o, new: n, text });

  const emitGap = (id, from, to, delta, pos) => {
    const size = to - from + 1;
    if (size <= 0) return;
    const exp = ui.expansions[id] || { down: 0, up: 0 };
    const down = Math.min(exp.down, size);
    const up = Math.min(exp.up, size - down);
    const ctx = (n) => line('ctx', n - delta, n, content ? (content[n - 1] ?? '') : '');
    for (let n = from; n < from + down; n++) ctx(n);
    const hidden = size - down - up;
    if (hidden > 0) rows.push({ kind: 'gap', id, hidden, pos });
    for (let n = to - up + 1; n <= to; n++) ctx(n);
  };

  const hunks = file.hunks || [];
  const expandable = file.newTotal != null && !file.binary && file.status !== 'deleted';
  for (let h = 0; h < hunks.length; h++) {
    const hunk = hunks[h];
    if (expandable) {
      const from = h === 0 ? 1 : hunks[h - 1].newStart + hunks[h - 1].newCount;
      emitGap('g' + h, from, hunk.newStart - 1, hunk.newStart - hunk.oldStart, h === 0 ? 'lead' : 'mid');
    }
    rows.push({ kind: 'hunkhead', hunkIdx: h, hunk });
    for (const l of hunk.lines) line(l.t, l.old, l.new, l.text);
  }
  if (expandable && hunks.length) {
    const last = hunks[hunks.length - 1];
    const from = last.newStart + last.newCount;
    emitGap('g' + hunks.length, from, file.newTotal, from - (last.oldStart + last.oldCount), 'tail');
  }
  return rows;
}

// Zips a file's display rows into side-by-side rows: deletions on the left,
// additions on the right, context spanning both (`left === right`). Runs of
// del/add within a change block pair up positionally, GitHub-style, and the
// longer side's leftovers pair with a blank cell. Gap and hunk-header rows
// pass through unchanged and still span the full width.
function pairRows(rows) {
  const out = [];
  let dels = [];
  let adds = [];
  const flush = () => {
    const n = Math.max(dels.length, adds.length);
    for (let i = 0; i < n; i++) {
      out.push({ kind: 'pair', left: dels[i] || null, right: adds[i] || null });
    }
    dels = [];
    adds = [];
  };
  for (const r of rows) {
    if (r.kind === 'line' && r.t === 'del') {
      if (adds.length) flush(); // a new change block started
      dels.push(r);
    } else if (r.kind === 'line' && r.t === 'add') {
      adds.push(r);
    } else {
      flush();
      out.push(r.kind === 'line' ? { kind: 'pair', left: r, right: r } : r);
    }
  }
  flush();
  return out;
}

/* -------------------------------------------------------------- rendering */

// A comment on deleted lines belongs to the view it was drafted in (its
// "old" line numbers point into that view's old side — the base ref, or a
// review snapshot). In any other view it renders unattached rather than on
// a coincidentally same-numbered line.
function inView(c, viewBaseline) {
  return c.side !== 'old' || (c.baseline ?? null) === (viewBaseline ?? null);
}

function commentsByAnchor(comments, viewBaseline) {
  const m = new Map();
  for (const c of comments) {
    if (c.fileLevel) continue; // rendered at the top of the file card
    if (c.parentId) continue;  // replies render inside their parent's thread
    if (c.detached || !inView(c, viewBaseline)) continue; // both render in the bottom bucket
    const k = c.side + ':' + c.endLine;
    if (!m.has(k)) m.set(k, []);
    m.get(k).push(c);
  }
  // Comments may overlap; when several end on the same line, show the widest
  // range first, then oldest first.
  for (const arr of m.values()) {
    arr.sort((a, b) => (a.startLine - b.startLine)
      || String(a.createdAt).localeCompare(String(b.createdAt)));
  }
  return m;
}

function coverageSet(comments, viewBaseline) {
  const s = new Set();
  for (const c of comments) {
    if (c.fileLevel || c.parentId || c.detached || !inView(c, viewBaseline)) continue;
    for (let n = c.startLine; n <= c.endLine; n++) s.add(c.side + ':' + n);
  }
  return s;
}

function rangeLabel(c) {
  if (c.parentId || c.replyTo) return 'reply';
  if (c.reviewLevel) return 'review comment';
  if (c.fileLevel) return 'file comment';
  const r = c.startLine === c.endLine ? 'line ' + c.startLine : 'lines ' + c.startLine + '–' + c.endLine;
  return r + (c.side === 'old' ? ' (old)' : '');
}

function commentBoxHtml(c, readOnly) {
  const actions = readOnly ? '' : `
    <span class="spacer"></span>
    <button class="plain-link" data-cact="edit" data-id="${esc(c.id)}">Edit</button>
    <button class="danger-link" data-cact="delete" data-id="${esc(c.id)}">Delete</button>`;
  let note = '';
  if (c.detached) {
    note = '<span class="cnote warn">⚠ the quoted code changed since this was drafted</span>';
  } else if (c.wip && !readOnly) {
    note = '<span class="cnote wip-note">unfinished — Edit to continue</span>';
  } else if (c.origStart != null && c.startLine !== c.origStart) {
    note = `<span class="cnote">followed code from line ${c.origStart}</span>`;
  }
  const excerpt = c.detached && c.excerpt && c.excerpt.length
    ? `<pre class="cexcerpt">${esc(c.excerpt.join('\n'))}</pre>` : '';
  return `<div class="comment-box${readOnly ? ' submitted' : ''}${c.detached ? ' detached' : ''}${c.wip && !readOnly ? ' wip' : ''}">
    <div class="chead"><span class="range">${esc(rangeLabel(c))}</span>${note}${actions}</div>
    ${excerpt}
    <div class="cbody">${esc(c.text)}</div>
  </div>`;
}

function formBoxHtml(ui) {
  const f = ui.form;
  const kind = f.replyTo ? 'Reply' : f.editingId ? 'Edit comment' : 'New comment';
  const label = f.replyTo ? kind : `${kind} · ${esc(rangeLabel(f))}`;
  return `<div class="comment-box form">
    <div class="chead"><span class="range">${label}</span></div>
    <textarea class="cform-text" placeholder="Leave a comment…">${esc(ui.formText || '')}</textarea>
    <div class="form-actions">
      <button class="primary" data-fact="save">Save</button>
      <button data-fact="cancel">Cancel</button>
      <span class="form-hint">⌘⏎ save · esc cancel</span>
    </div>
  </div>`;
}

// A comment plus its replies (single-level; replies always point at the
// thread root and inherit its anchor). The entry being edited — root or
// reply — swaps for the form in place; the footer offers Reply or holds the
// open reply form.
function threadHtml(c, comments, ui, readOnly) {
  const replies = comments
    .filter((r) => r.parentId === c.id)
    .sort((a, b) => String(a.createdAt).localeCompare(String(b.createdAt)));
  const entry = (e) => (!readOnly && ui.form && ui.form.editingId === e.id)
    ? formBoxHtml(ui) : commentBoxHtml(e, readOnly);
  const parts = [entry(c), ...replies.map(entry)];
  if (!readOnly && ui.form && ui.form.replyTo === c.id) {
    parts.push(formBoxHtml(ui));
  } else if (!readOnly) {
    parts.push(`<div class="thread-foot"><button class="plain-link" data-reply="${esc(c.id)}">Reply</button></div>`);
  }
  return `<div class="thread">${parts.join('')}</div>`;
}

// highlight.js is a separate script; guarded so the headless test harness can
// load app.js on its own.
const HL = typeof Highlight === 'undefined' ? null : Highlight;

function tokensHtml(tokens) {
  let h = '';
  for (const tok of tokens) {
    h += tok.t === 'plain' ? esc(tok.s) : `<span class="tok-${tok.t}">${esc(tok.s)}</span>`;
  }
  return h;
}

// Per-file highlighter for rows in display order. Old and new sides are
// separate documents, so each gets its own carry (a deleted `/*` must not
// bleed comment state into the lines that replaced it); context lines belong
// to both. Hidden context (an unexpanded gap) breaks the carries.
function makeHighlighter(path) {
  const spec = HL && HL.specForPath(path);
  if (!spec) return null;
  let carryOld = null;
  let carryNew = null;
  return {
    reset() { carryOld = null; carryNew = null; },
    html(r) {
      if (r.t === 'del') {
        const res = HL.tokenizeLine(spec, r.text, carryOld);
        carryOld = res.carry;
        return tokensHtml(res.tokens);
      }
      if (r.t === 'add') {
        const res = HL.tokenizeLine(spec, r.text, carryNew);
        carryNew = res.carry;
        return tokensHtml(res.tokens);
      }
      carryOld = HL.tokenizeLine(spec, r.text, carryOld).carry;
      const res = HL.tokenizeLine(spec, r.text, carryNew);
      carryNew = res.carry;
      return tokensHtml(res.tokens);
    },
  };
}

function lineRowHtml(r, covered, readOnly, codeHtml) {
  const cls = r.t === 'add' ? 'add' : r.t === 'del' ? 'del' : 'ctx';
  const isCov = (r.new != null && covered.has('new:' + r.new)) ||
                (r.old != null && covered.has('old:' + r.old));
  const sign = r.t === 'add' ? '+' : r.t === 'del' ? '-' : '';
  const plus = readOnly ? '' : '<button class="addc" tabindex="-1" title="Add comment (drag to select a range)">+</button>';
  return `<tr class="ln ${cls}${isCov ? ' commented' : ''}" data-di="${r.di}">
    <td class="plus-cell">${plus}</td>
    <td class="num">${r.old ?? ''}</td>
    <td class="num">${r.new ?? ''}</td>
    <td class="sign">${sign}</td>
    <td class="code">${codeHtml ?? esc(r.text)}</td>
  </tr>`;
}

// One side of a split row: four cells (comment button, line number, sign,
// code) carrying the display index and which column they are, so a drag knows
// what it swept. A missing row (the shorter side of a change block) renders as
// a blank, unselectable group.
function sideCellsHtml(r, side, covered, readOnly) {
  const edge = side === 'new' ? ' edge' : '';
  if (!r) {
    return `<td class="plus-cell blank${edge}"></td><td class="num blank"></td>`
      + '<td class="sign blank"></td><td class="code half blank"></td>';
  }
  const cls = r.t === 'add' ? 'add' : r.t === 'del' ? 'del' : 'ctx';
  const num = side === 'old' ? r.old : r.new;
  const isCov = num != null && covered.has(side + ':' + num);
  const sign = r.t === 'add' ? '+' : r.t === 'del' ? '-' : '';
  const plus = readOnly ? '' : '<button class="addc" tabindex="-1" title="Add comment (drag to select a range)">+</button>';
  const at = ` data-di="${r.di}" data-dside="${side}"`;
  return `<td class="plus-cell s-${cls}${edge}"${at}>${plus}</td>`
    + `<td class="num s-${cls}"${at}>${num ?? ''}</td>`
    + `<td class="sign s-${cls}"${at}>${sign}</td>`
    + `<td class="code half s-${cls}${isCov ? ' commented' : ''}"${at}>${r.codeHtml ?? esc(r.text)}</td>`;
}

// `pair.left === pair.right` for context, which is highlighted once and shown
// in both columns.
function pairRowHtml(pair, covered, readOnly, htmlL, htmlR) {
  const withHtml = (r, h) => (r == null ? null : (h == null ? r : { ...r, codeHtml: h }));
  return '<tr class="ln-pair">'
    + sideCellsHtml(withHtml(pair.left, htmlL), 'old', covered, readOnly)
    + sideCellsHtml(withHtml(pair.right, htmlR), 'new', covered, readOnly)
    + '</tr>';
}

function gapRowHtml(r, readOnly, cols) {
  if (readOnly) {
    return `<tr class="gap"><td colspan="${cols}"><div class="gap-inner">
      <span class="gap-count">⋯ ${r.hidden} unchanged line${r.hidden === 1 ? '' : 's'} not shown</span>
    </div></td></tr>`;
  }
  const btns = [];
  if (r.hidden > EXPAND_STEP) {
    if (r.pos !== 'lead') btns.push(`<button data-act="down" data-gap="${r.id}" title="Show the next ${EXPAND_STEP} lines below the code above">↓ ${EXPAND_STEP}</button>`);
    if (r.pos !== 'tail') btns.push(`<button data-act="up" data-gap="${r.id}" title="Show the ${EXPAND_STEP} lines above the code below">↑ ${EXPAND_STEP}</button>`);
  }
  btns.push(`<button data-act="all" data-gap="${r.id}">Show all</button>`);
  return `<tr class="gap"><td colspan="${cols}"><div class="gap-inner">
    ${btns.join('')}
    <span class="gap-count">${r.hidden} unchanged line${r.hidden === 1 ? '' : 's'} hidden</span>
  </div></td></tr>`;
}

function hunkHeadHtml(file, r, readOnly, cols) {
  const h = r.hunk;
  const label = `@@ -${h.oldStart},${h.oldCount} +${h.newStart},${h.newCount} @@` +
    (h.section ? ' ' + h.section : '');
  let btn = '';
  // Delta-view hunks are relative to a review snapshot, not HEAD, and a
  // hunk parsed from a `-w` diff is not a valid patch — neither can be
  // staged. (File-level staging stays available.)
  const hunkStageable = !readOnly && !file.binary && file.status === 'modified'
    && !file.delta && !(review && review.ignoreWhitespace);
  if (hunkStageable) {
    btn = h.staged
      ? `<span class="staged-tick">staged ✓</span><button class="hh-btn" data-hact="unstage-hunk" data-hunk="${r.hunkIdx}">Unstage hunk</button>`
      : `<button class="hh-btn" data-hact="stage-hunk" data-hunk="${r.hunkIdx}">Stage hunk</button>`;
  }
  return `<tr class="hunk-head"><td colspan="${cols}"><div class="hh-inner">
    <span class="hh-label">${esc(label)}</span><span class="spacer"></span>${btn}
  </div></td></tr>`;
}

// One chevron for every disclosure control (file cards, tree folders). Which
// way it points is decided by the container's collapsed/folded class, so a
// fold is a class toggle and never swapped markup.
const caretSvg = (size) => `<svg class="caret-icon" width="${size}" height="${size}"`
  + ' viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"'
  + ' stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
  + '<path d="M6 9l6 6 6-6"/></svg>';

function fileStageControls(file) {
  const s = file.stagedState;
  if (s == null) return '';
  const badge = s === 'full' ? '<span class="staged-badge full">staged</span>'
    : s === 'partial' ? '<span class="staged-badge">partially staged</span>' : '';
  const btns = [];
  if (s !== 'full') btns.push('<button class="file-act" data-sact="stage-file">Stage file</button>');
  if (s !== 'none') btns.push('<button class="file-act" data-sact="unstage-file">Unstage file</button>');
  return badge + btns.join('');
}

function buildFileSection(file, comments, ui, opts) {
  const readOnly = !!(opts && opts.readOnly);
  const parts = [];
  const pathHtml = file.status === 'renamed'
    ? `${esc(file.oldPath)} <span class="arrow">→</span> ${esc(file.path)}`
    : esc(file.path);
  const chip = (file.binary || file.status !== 'modified')
    ? `<span class="file-status ${file.status}">${file.binary ? 'binary' : esc(file.status)}</span>`
    : '';

  const viewed = !readOnly && !!file.viewed;
  parts.push(`<section class="file${ui.collapsed ? ' collapsed' : ''}${viewed ? ' viewed' : ''}" data-path="${esc(file.path)}">`);
  parts.push(`<header class="file-header">
    <button class="caret" data-fold title="${ui.collapsed ? 'Expand file' : 'Collapse file'}">${caretSvg(16)}</button>
    <span class="file-path">${pathHtml}</span>${chip}
    <span class="stats"><span class="stat-add">+${file.additions}</span> <span class="stat-del">−${file.deletions}</span></span>
    ${comments.length ? `<span class="file-comment-count">☗ ${comments.length}</span>` : ''}
    <span class="spacer"></span>
    ${readOnly ? '' : '<button class="file-act" data-fcomment title="Comment on the whole file">Comment</button>'}
    ${readOnly ? '' : fileStageControls(file)}
    ${readOnly ? '' : `<label class="viewed-toggle"><input type="checkbox" class="viewed-box"${viewed ? ' checked' : ''}> Viewed</label>`}
  </header>`);

  // A collapsed file renders no body; its expansion state lives in `ui`, so
  // folding via the caret keeps it and re-expanding restores it. Only marking
  // a file Viewed wipes that state (see the viewed-box change handler).
  // In read-only history the body is kept and just hidden with CSS.
  if (!ui.collapsed || readOnly) {
    // File-level comments sit above the diff; they have no lines to anchor to.
    const strip = [];
    for (const c of comments.filter((c) => c.fileLevel)) {
      strip.push(threadHtml(c, comments, ui, readOnly));
    }
    if (!readOnly && ui.form && ui.form.fileLevel && !ui.form.editingId) {
      strip.push(formBoxHtml(ui));
    }
    if (strip.length) parts.push(`<div class="file-comments">${strip.join('')}</div>`);
    if (file.binary) {
      parts.push(`<div class="file-note">Binary file — not rendered.</div>`);
    } else if (!file.hunks.length) {
      const note = file.status === 'renamed' ? 'Renamed with no content changes.'
        : file.untracked ? 'New empty file.' : 'No content changes.';
      parts.push(`<div class="file-note">${note}</div>`);
    } else {
      const split = !!(opts && opts.split);
      const cols = split ? 8 : 5;
      const rows = buildRows(file, ui);
      const viewBaseline = (opts && opts.baseline) ?? null;
      const anchors = commentsByAnchor(comments, viewBaseline);
      const covered = coverageSet(comments, viewBaseline);
      const rendered = new Set();
      const hl = makeHighlighter(file.path);
      // Split declares its columns up front: with `table-layout: fixed` the two
      // sides stay exactly equal, so the divider is centred and content can
      // never widen a column (rows that span the table would otherwise decide
      // the layout).
      // In split view a comment (or the open form) sits under the column it
      // annotates, so which side it is about is unmistakable; inline spans the
      // whole row.
      const crow = (html, side) => split
        ? '<tr class="crow">' + (side === 'old'
            ? `<td colspan="4">${html}</td><td colspan="4"></td>`
            : `<td colspan="4"></td><td colspan="4">${html}</td>`) + '</tr>'
        : `<tr class="crow"><td colspan="${cols}">${html}</td></tr>`;
      const colgroup = split
        ? '<colgroup>' + ('<col class="c-plus"><col class="c-num"><col class="c-sign"><col class="c-code">').repeat(2) + '</colgroup>'
        : '';
      parts.push(`<div class="diff-wrap"><table class="diff${split ? ' split' : ''}">${colgroup}<tbody>`);
      for (const u of split ? pairRows(rows) : rows) {
        if (u.kind === 'gap') { if (hl) hl.reset(); parts.push(gapRowHtml(u, readOnly, cols)); continue; }
        if (u.kind === 'hunkhead') { parts.push(hunkHeadHtml(file, u, readOnly, cols)); continue; }
        // A unified row shows one line; a split row shows a deletion beside
        // its replacement, or the same context line in both columns. Threads
        // and the open form go under whichever row holds their line.
        let lineRows;
        if (u.kind === 'pair') {
          // Each side keeps its own highlighter carry, so alternating between
          // the columns still feeds each side its own lines in order.
          const hL = hl && u.left ? hl.html(u.left) : null;
          const hR = hl && u.right ? (u.right === u.left ? hL : hl.html(u.right)) : null;
          parts.push(pairRowHtml(u, covered, readOnly, hL, hR));
          lineRows = (u.left === u.right ? [u.left] : [u.left, u.right]).filter(Boolean);
        } else {
          parts.push(lineRowHtml(u, covered, readOnly, hl && hl.html(u)));
          lineRows = [u];
        }
        for (const r of lineRows) {
          for (const side of ['old', 'new']) {
            const num = r[side];
            if (num == null) continue;
            for (const c of anchors.get(side + ':' + num) || []) {
              if (rendered.has(c.id)) continue;
              rendered.add(c.id);
              parts.push(crow(threadHtml(c, comments, ui, readOnly), side));
            }
          }
        }
        if (!readOnly && ui.form && !ui.form.editingId
            && lineRows.some((r) => r.di === ui.form.endDi)) {
          parts.push(crow(formBoxHtml(ui), ui.form.side));
        }
      }
      parts.push('</tbody></table></div>');
      const orphans = comments.filter((c) => !c.fileLevel && !c.parentId && !rendered.has(c.id));
      if (orphans.length) {
        parts.push('<div class="orphan-note">Comments not attached to visible lines:</div>');
        for (const c of orphans) {
          parts.push(`<div class="orphan-comment">${threadHtml(c, comments, ui, readOnly)}</div>`);
        }
      }
    }
  }
  parts.push('</section>');

  const tpl = document.createElement('template');
  tpl.innerHTML = parts.join('');
  return tpl.content.firstElementChild;
}

function renderFile(path) {
  const file = review.files.find((f) => f.path === path);
  if (!file) return;
  const fresh = buildFileSection(file, draftsFor(path), getUI(path),
    { readOnly: false, baseline: review.since, split: splitView() });
  const old = fileSections.get(path);
  if (old) old.replaceWith(fresh);
  fileSections.set(path, fresh);
  const ta = fresh.querySelector('textarea.cform-text');
  if (ta) {
    ta.focus();
    ta.selectionStart = ta.selectionEnd = ta.value.length;
  }
  updateTopbar();
  renderTree();
}

function renderFiles() {
  const container = $('#files');
  container.textContent = '';
  fileSections.clear();
  for (const f of review.files) {
    const sec = buildFileSection(f, draftsFor(f.path), getUI(f.path),
      { readOnly: false, baseline: review.since, split: splitView() });
    fileSections.set(f.path, sec);
    container.appendChild(sec);
  }
  $('#empty-state').hidden = review.files.length > 0;
  $('#empty-state p').textContent = review.since
    ? `No changes since review r${review.since}.`
    : 'No changes between the working tree and the base ref.';
  updateTopbar();
  renderTree();
  syncActiveFromScroll();
}

function updateTopbar() {
  const info = $('#repo-info');
  if (!review) { info.textContent = ''; return; }
  document.title = `gandalf: ${review.branch}:${review.repo}`;
  const adds = review.files.reduce((s, f) => s + f.additions, 0);
  const dels = review.files.reduce((s, f) => s + f.deletions, 0);
  // "Working tree vs HEAD" is the default and goes unsaid; only a custom
  // --base is worth calling out.
  const baseNote = review.base === 'HEAD' ? '' : ` vs <code>${esc(review.base)}</code>`;
  const sinceNote = review.since ? ` · <span class="delta-note">since review r${review.since}</span>` : '';
  const wsNote = review.ignoreWhitespace ? ' · <span class="delta-note">ignoring whitespace</span>' : '';
  info.innerHTML = `<span class="info-line"><code>${esc(review.repo)}</code> on <code>${esc(review.branch)}</code>${baseNote}</span>
    <span class="info-line muted">${review.files.length} file${review.files.length === 1 ? '' : 's'}
    · <span class="stat-add">+${adds}</span> <span class="stat-del">−${dels}</span>${sinceNote}${wsNote}</span>`;
  const btn = $('#btn-submit');
  // Always enabled: a review can be just an overall comment from the dialog.
  btn.disabled = false;
  btn.textContent = drafts.length ? `Finish review (${drafts.length})` : 'Finish review';
}

// The baseline picker only appears once there is a snapshot to diff against.
// Selecting a review shows just what changed since it was finished.
function renderBaselineSelect() {
  const sel = $('#baseline-select');
  const snaps = (review.revisions || []).filter((r) => r.hasSnapshot).reverse();
  sel.hidden = snaps.length === 0;
  sel.textContent = '';
  for (const [value, label] of [['', 'All changes'],
      ...snaps.map((r) => [String(r.revision), `Since review r${r.revision}`])]) {
    const o = document.createElement('option');
    o.value = value;
    o.textContent = label;
    sel.appendChild(o);
  }
  sel.value = review.since ? String(review.since) : '';
  sel.classList.toggle('delta-on', !!review.since);
}

/* -------------------------------------------------------------- file tree */

// A GitHub-style navigator for the files in the diff: the paths in
// `review.files` as a folder tree, with foldable folders and a filter box.
// It only navigates — clicking a file scrolls to its card and never touches
// fold state, comments or the diff itself.

// Folders the reviewer has folded, by folder path. Folders start expanded;
// the set survives re-renders and refreshes within the page session.
const treeFolded = new Set();
let treeFilter = '';
let activeFilePath = null;

// Paths -> nested nodes. A folder holding a single sub-folder and nothing
// else is merged into it, so `docs/design/notes` is one row rather than
// three (GitHub does the same); deep source trees stay readable.
function buildTree(files) {
  const root = { name: '', path: '', dirs: new Map(), files: [] };
  for (const f of files) {
    const parts = String(f.path).split('/');
    const name = parts.pop();
    let node = root;
    let acc = '';
    for (const part of parts) {
      acc = acc ? acc + '/' + part : part;
      if (!node.dirs.has(part)) {
        node.dirs.set(part, { name: part, path: acc, dirs: new Map(), files: [] });
      }
      node = node.dirs.get(part);
    }
    node.files.push({ name, file: f });
  }
  return compressTree(root);
}

// Depth-first, so a merged child is already compressed when it is folded
// into its parent. The merged node keeps the deepest path as its key, so
// fold state follows the row the reviewer actually clicked.
function compressTree(node) {
  const dirs = new Map();
  for (const dir of node.dirs.values()) {
    let d = compressTree(dir);
    while (!d.files.length && d.dirs.size === 1) {
      const only = d.dirs.values().next().value;
      d = { name: d.name + '/' + only.name, path: only.path, dirs: only.dirs, files: only.files };
    }
    dirs.set(d.name, d);
  }
  node.dirs = dirs;
  return node;
}

function countTreeFiles(node) {
  let n = node.files.length;
  for (const d of node.dirs.values()) n += countTreeFiles(d);
  return n;
}

// Flattens the tree into display rows: folders before files, each side
// alphabetical, children only while their folder is open.
function treeRows(root, folded) {
  const byName = (a, b) => a.name.localeCompare(b.name);
  const out = [];
  const walk = (node, depth) => {
    for (const d of [...node.dirs.values()].sort(byName)) {
      const open = !folded.has(d.path);
      out.push({ type: 'dir', name: d.name, path: d.path, depth, open, count: countTreeFiles(d) });
      if (open) walk(d, depth + 1);
    }
    for (const f of [...node.files].sort(byName)) {
      out.push({ type: 'file', name: f.name, path: f.file.path, depth, file: f.file });
    }
  };
  walk(root, 0);
  return out;
}

function treeDirPaths(node, out = []) {
  for (const d of node.dirs.values()) {
    out.push(d.path);
    treeDirPaths(d, out);
  }
  return out;
}

// Whitespace-separated substrings, all of which must appear in the path
// (case-insensitive). Deliberately plain: no fuzzy matching, so what the
// filter shows is always explainable from what was typed.
function filterTokens(q) {
  return String(q || '').toLowerCase().split(/\s+/).filter(Boolean);
}

function matchesFilter(file, tokens) {
  const hay = (file.path + ' ' + (file.oldPath || '')).toLowerCase();
  return tokens.every((t) => hay.includes(t));
}

// Escaped file name with every filter hit wrapped in <mark>. Tokens that
// only matched the folder part of the path simply don't mark anything.
function markName(name, tokens) {
  const lower = name.toLowerCase();
  const hits = [];
  for (const t of tokens) {
    for (let i = lower.indexOf(t); i !== -1; i = lower.indexOf(t, i + 1)) hits.push([i, i + t.length]);
  }
  if (!hits.length) return esc(name);
  hits.sort((a, b) => a[0] - b[0]);
  const merged = [];
  for (const [start, end] of hits) {
    const last = merged[merged.length - 1];
    if (last && start <= last[1]) last[1] = Math.max(last[1], end);
    else merged.push([start, end]);
  }
  let html = '';
  let pos = 0;
  for (const [start, end] of merged) {
    html += esc(name.slice(pos, start)) + '<mark>' + esc(name.slice(start, end)) + '</mark>';
    pos = end;
  }
  return html + esc(name.slice(pos));
}

const STATUS_LETTER = { added: 'A', deleted: 'D', renamed: 'R', modified: 'M' };

function treeRowHtml(r, tokens, filtering) {
  // Indent guides instead of a padding style attribute: the CSP forbids
  // inline styles, and the rules double as GitHub's tree lines.
  const indent = '<span class="tindent"></span>'.repeat(r.depth);
  if (r.type === 'dir') {
    const body = `${indent}<span class="tcaret">${caretSvg(14)}</span>`
      + `<span class="tname">${markName(r.name, tokens)}</span>`
      + `<span class="tmeta">${r.count}</span>`;
    // While filtering, folders are forced open (below), so a fold control
    // there would be a button that does nothing.
    return filtering
      ? `<div class="trow dir static">${body}</div>`
      : `<button class="trow dir${r.open ? '' : ' folded'}" data-tdir="${esc(r.path)}"
          aria-expanded="${r.open}" title="${esc(r.path)}">${body}</button>`;
  }
  const f = r.file;
  const count = draftsFor(r.path).length;
  const meta = (count ? `<span class="tcomments">☗ ${count}</span>` : '')
    + (f.viewed ? '<span class="tviewed" title="Viewed">✓</span>' : '');
  const letter = f.binary ? 'B' : (STATUS_LETTER[f.status] || 'M');
  const title = `${f.oldPath && f.status === 'renamed' ? f.oldPath + ' → ' : ''}${f.path}`
    + ` · +${f.additions} −${f.deletions}${f.binary ? ' · binary' : ''}`;
  return `<button class="trow file${r.path === activeFilePath ? ' active' : ''}"
      data-tfile="${esc(r.path)}" title="${esc(title)}">${indent}<span
      class="tstatus s-${esc(f.status)}" aria-hidden="true">${letter}</span><span
      class="tname">${markName(r.name, tokens)}</span><span class="tmeta">${meta}</span></button>`;
}

function renderTree() {
  document.body.classList.toggle('tree-hidden', !treeShown);
  const list = $('#tree-list');
  const count = $('#tree-count');
  if (!review) { list.innerHTML = ''; count.textContent = ''; return; }
  const tokens = filterTokens(treeFilter);
  const filtering = tokens.length > 0;
  const files = filtering ? review.files.filter((f) => matchesFilter(f, tokens)) : review.files;
  // A filter that hid its own hits behind a folded folder would be a lie:
  // while filtering, everything that matched is shown. Fold state is kept
  // and resumes the moment the box is cleared.
  const rows = treeRows(buildTree(files), filtering ? new Set() : treeFolded);
  list.innerHTML = rows.length
    ? rows.map((r) => treeRowHtml(r, tokens, filtering)).join('')
    : '<div class="tree-empty">No files match.</div>';
  const total = review.files.length;
  count.textContent = filtering
    ? `${files.length} of ${total} file${total === 1 ? '' : 's'}`
    : `${total} file${total === 1 ? '' : 's'}`;
  // One control for both directions, labelled for whichever way it will go.
  // It always acts on the whole tree, not just the filtered rows.
  const dirs = treeDirPaths(buildTree(review.files));
  const fold = $('#btn-tree-fold');
  const anyOpen = dirs.some((d) => !treeFolded.has(d));
  fold.hidden = dirs.length === 0;
  fold.textContent = anyOpen ? '⊟' : '⊞';
  fold.title = anyOpen ? 'Collapse all folders' : 'Expand all folders';
  fold.setAttribute('aria-label', fold.title);
}

// The topbar toggle. Below MIN_TREE_PX the sidebar hides itself and the
// button goes away with it (CSS), so the choice only matters when there is
// room for a sidebar at all.
function renderTreeToggle() {
  const btn = $('#btn-tree');
  btn.classList.toggle('on', treeShown);
  btn.setAttribute('aria-pressed', treeShown ? 'true' : 'false');
}

function setTreeShown(on) {
  treeShown = on;
  try {
    if (on) localStorage.removeItem(TREE_KEY);
    else localStorage.setItem(TREE_KEY, '0');
  } catch (_) { /* fine */ }
  renderTreeToggle();
  renderTree();
  // Showing/hiding the sidebar changes how much room the diff has, which can
  // flip split into inline and back (see wideEnough).
  renderViewToggle();
  if (review && diffView === 'split') renderFiles();
  if (diffView === 'split' && !wideEnough()) toast(narrowMessage());
}

// Why split is rendering inline right now: a window too narrow either way,
// or one that would have been wide enough without the sidebar's slice of it.
function narrowedByTree() {
  return treeVisible() && (!wideQuery || wideQuery.matches);
}

function narrowMessage() {
  return narrowedByTree()
    ? 'No room for two code columns beside the file tree — showing inline.'
    : `The window is under ${MIN_SPLIT_PX}px — showing inline until it is wider.`;
}

function setActiveFile(path) {
  if (path === activeFilePath) return;
  activeFilePath = path;
  for (const el of $('#tree-list').querySelectorAll('[data-tfile]')) {
    el.classList.toggle('active', el.dataset.tfile === activeFilePath);
  }
}

function jumpToFile(path) {
  const sec = fileSections.get(path);
  if (!sec) return;
  // Fold state is the reviewer's; jumping to a file never changes it. The
  // card's scroll-margin clears the sticky topbar.
  sec.scrollIntoView({ block: 'start' });
  setActiveFile(path);
}

// Which file card the reviewer is looking at — the first one whose bottom is
// still below the sticky header. Cheap enough to run per scroll frame at
// these file counts, and it needs no observers to survive re-renders.
function syncActiveFromScroll() {
  const top = ($('#topbar').offsetHeight || 43) + 8;
  let current = null;
  for (const [path, sec] of fileSections) {
    if (sec.getBoundingClientRect().bottom > top) { current = path; break; }
  }
  // At the end of the page no card is "topmost" in any useful sense — the
  // last one is what the reviewer is looking at, so it never goes unlit.
  if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2) {
    for (const path of fileSections.keys()) current = path;
  }
  if (current) setActiveFile(current);
}

/* -------------------------------------------------- review-level comment */

// The comment on the review as a whole (GitHub-style summary), written in
// the Finish review dialog. It lives in the same drafts array (file: null,
// reviewLevel: true) so it survives reloads and a cancelled or failed
// finish, and it leads the markdown as an "Overall" section.

function upsertOverallDraft(text) {
  const t = (text || '').trim();
  const existing = reviewLevelDrafts();
  if (existing.length === 1 && existing[0].text === t) return;
  drafts = drafts.filter((c) => !c.reviewLevel);
  if (t) {
    drafts.push({
      id: genId(),
      file: null,
      reviewLevel: true,
      text: t,
      createdAt: new Date().toISOString(),
    });
  }
  scheduleDraftSave();
  updateTopbar();
}

function openFinishDialog() {
  stashAllForms(); // half-written comments join the review as unfinished drafts
  renderFiles();
  const others = drafts.filter((c) => !c.reviewLevel);
  const files = new Set(others.map((c) => c.file)).size;
  const wip = others.filter((c) => c.wip).length;
  const wipNote = wip
    ? ` ${wip} unfinished draft${wip === 1 ? '' : 's'} will be included as-is.` : '';
  $('#finish-dialog-sub').textContent = (others.length
    ? `${others.length} comment${others.length === 1 ? '' : 's'} on `
      + `${files} file${files === 1 ? '' : 's'}, plus whatever you write below.`
    : 'No comments — finishing approves the changes as-is and checkpoints '
      + 'the review. Add an overall note below if you like.')
    + wipNote;
  const ta = $('#finish-overall');
  ta.value = reviewLevelDrafts().map((c) => c.text).join('\n\n');
  $('#finish-dialog').showModal();
  ta.focus();
  ta.selectionStart = ta.selectionEnd = ta.value.length;
}

/* ------------------------------------------------------------ audit trail */

function renderHistory() {
  // Chronological: the most recent review sits last, adjacent to the fresh
  // changes below it.
  const revs = review.revisions || [];
  $('#history').hidden = revs.length === 0;
  const list = $('#history-list');
  list.textContent = '';
  for (const meta of revs) {
    const d = document.createElement('details');
    d.className = 'revision';
    const when = new Date(meta.submittedAt).toLocaleString();
    d.innerHTML = `<summary>
      <span class="rev-caret">${caretSvg(14)}</span>
      <span class="rev-title">Review r${meta.revision}</span>
      <span class="muted">${esc(when)} · ${meta.commentCount
        ? `${meta.commentCount} comment${meta.commentCount === 1 ? '' : 's'}`
        : 'approved — no comments'} · head ${esc(meta.head)}</span>
      <span class="spacer"></span>
      <button class="plain-link" data-rcopy="${meta.revision}" title="Copy this review as text to paste to an agent">Copy for agent</button>
    </summary><div class="rev-body"><div class="rev-note">Loading…</div></div>`;
    d.addEventListener('toggle', () => {
      if (d.open && !d.dataset.loaded) loadRevision(d, meta.revision);
    });
    list.appendChild(d);
  }
}

async function loadRevision(details, n) {
  details.dataset.loaded = '1';
  const body = details.querySelector('.rev-body');
  try {
    const snap = await api('/api/revision?n=' + n);
    body.textContent = '';
    const note = document.createElement('div');
    note.className = 'rev-note';
    note.textContent = `Submitted ${new Date(snap.submittedAt).toLocaleString()} against ${snap.base}`
      + ` (head ${snap.head}). The diff is shown as it was at submit time.`;
    body.appendChild(note);
    const overall = (snap.comments || []).filter((c) => c.reviewLevel);
    if (overall.length) {
      const wrap = document.createElement('div');
      wrap.className = 'rev-overall';
      wrap.innerHTML = overall.map((c) => commentBoxHtml(c, true)).join('');
      body.appendChild(wrap);
    }
    for (const f of snap.files) {
      const comments = snap.comments.filter((c) => c.file === f.path);
      const ui = { collapsed: comments.length === 0, expansions: {}, content: null, form: null };
      body.appendChild(buildFileSection(f, comments, ui,
        { readOnly: true, split: splitView() }));
    }
    if (!snap.files.length) {
      body.appendChild(Object.assign(document.createElement('div'),
        { className: 'rev-note', textContent: 'No diff was captured for this revision.' }));
    }
  } catch (e) {
    body.innerHTML = `<div class="rev-note">Failed to load revision: ${esc(e.message)}</div>`;
  }
}

/* -------------------------------------------------------- comment editing */

// The line rows a selection covers. `col` ('old' | 'new' | null inline) is the
// split-view column it was dragged in: the other column's rows fall inside the
// same display-index range but were never swept, so they drop out.
function selectionRows(rows, startDi, endDi, col) {
  const sel = rows.filter((r) => r.kind === 'line' && r.di >= startDi && r.di <= endDi);
  if (col === 'old') return sel.filter((r) => r.old != null);
  if (col === 'new') return sel.filter((r) => r.new != null);
  return sel;
}

// What a selection anchors to, decided the same way in both views: anything
// with a working-tree line number anchors on the new side and follows the code
// from then on; only an all-deletions selection anchors on the old side. (An
// old-side anchor spanning context lines would detach on the next load, since
// only wholly-deleted ranges stay attached.) The excerpt keeps every selected
// line, including deletions the anchor itself skips.
function selectionAnchor(rows) {
  const side = rows.some((r) => r.new != null) ? 'new' : 'old';
  const nums = rows.map((r) => r[side]).filter((n) => n != null);
  return {
    side,
    startLine: nums[0],
    endLine: nums[nums.length - 1],
    excerpt: rows.map((r) => (r.t === 'add' ? '+' : r.t === 'del' ? '-' : ' ') + r.text),
  };
}

function openForm(path, startDi, endDi, col) {
  stashForm(path);
  const file = review.files.find((f) => f.path === path);
  const ui = getUI(path);
  const rows = selectionRows(buildRows(file, ui), startDi, endDi, col);
  if (!rows.length) return;
  const a = selectionAnchor(rows);
  ui.form = {
    startDi, endDi, side: a.side, startLine: a.startLine, endLine: a.endLine,
    // Old-side line numbers are meaningful only in the view they came from.
    baseline: a.side === 'old' ? (review.since ?? null) : null,
    excerpt: a.excerpt,
  };
  ui.formText = '';
  renderFile(path);
}

// Never lose typed text: stash an open form's state before anything replaces
// it. Non-empty text becomes (or updates) a draft marked unfinished (`wip`);
// the reviewer resumes via Edit, and a real save clears the marker. Explicit
// Cancel/esc still discards — this guards the implicit paths only (opening
// another comment, marking Viewed, Refresh, finishing).
function stashForm(path) {
  const ui = getUI(path);
  const f = ui.form;
  if (!f) return;
  const text = (ui.formText || '').trim();
  ui.form = null;
  ui.formText = '';
  if (!text) return; // nothing typed, nothing to keep
  if (f.editingId) {
    const c = drafts.find((c) => c.id === f.editingId);
    if (c && c.text !== text) {
      c.text = text;
      c.wip = true;
      scheduleDraftSave();
    }
    return;
  }
  const c = { id: genId(), file: path, text, wip: true, createdAt: new Date().toISOString() };
  if (f.fileLevel) {
    c.fileLevel = true;
  } else if (f.replyTo) {
    c.parentId = f.replyTo;
  } else {
    Object.assign(c, {
      side: f.side, baseline: f.baseline ?? null,
      startLine: f.startLine, endLine: f.endLine,
      origStart: f.startLine, excerpt: f.excerpt,
    });
  }
  drafts.push(c);
  scheduleDraftSave();
}

function stashAllForms() {
  for (const path of fileUI.keys()) stashForm(path);
}

function openFileForm(path) {
  stashForm(path);
  const ui = getUI(path);
  ui.collapsed = false; // the form lives in the body
  ui.form = { fileLevel: true };
  ui.formText = '';
  renderFile(path);
}

function saveForm(path) {
  const ui = getUI(path);
  const f = ui.form;
  if (!f) return;
  const text = (ui.formText || '').trim();
  if (!text) { toast('Comment is empty.'); return; }
  if (f.editingId) {
    const c = drafts.find((c) => c.id === f.editingId);
    if (c) {
      c.text = text;
      delete c.wip; // explicitly saved: no longer unfinished
    }
  } else if (f.fileLevel) {
    drafts.push({
      id: genId(),
      file: path,
      fileLevel: true,
      text,
      createdAt: new Date().toISOString(),
    });
  } else if (f.replyTo) {
    drafts.push({
      id: genId(),
      file: path,
      parentId: f.replyTo,
      text,
      createdAt: new Date().toISOString(),
    });
  } else {
    drafts.push({
      id: genId(),
      file: path,
      side: f.side,
      baseline: f.baseline ?? null,
      startLine: f.startLine,
      endLine: f.endLine,
      origStart: f.startLine, // where it was drafted; anchors may follow the code
      excerpt: f.excerpt,
      text,
      createdAt: new Date().toISOString(),
    });
  }
  ui.form = null;
  ui.formText = '';
  scheduleDraftSave();
  renderFile(path);
}

function cancelForm(path) {
  const ui = getUI(path);
  ui.form = null;
  ui.formText = '';
  renderFile(path);
}

/* ------------------------------------------------------- context expansion */

async function expandGap(path, gapId, act) {
  const ui = getUI(path);
  if (!ui.content) {
    try {
      const res = await api('/api/file?path=' + encodeURIComponent(path));
      ui.content = res.lines;
    } catch (e) {
      toast('Cannot expand context: ' + e.message);
      return;
    }
  }
  const exp = ui.expansions[gapId] || (ui.expansions[gapId] = { down: 0, up: 0 });
  if (act === 'down') exp.down += EXPAND_STEP;
  else if (act === 'up') exp.up += EXPAND_STEP;
  else { exp.down = Number.MAX_SAFE_INTEGER; exp.up = 0; }
  renderFile(path);
}

/* ----------------------------------------------------------- interactions */

// {path, anchor, head} in display-row indices, plus the split-view column the
// drag started in (null inline). Inline carries the index on the <tr>, split on
// each side's cells, so both paint through the same `[data-di]` selector.
let dragSel = null;

function paintSelection(sec) {
  const lo = Math.min(dragSel.anchor, dragSel.head);
  const hi = Math.max(dragSel.anchor, dragSel.head);
  sec.querySelectorAll('[data-di]').forEach((el) => {
    const di = +el.dataset.di;
    const sameCol = !dragSel.col || el.dataset.dside === dragSel.col;
    el.classList.toggle('selrange', sameCol && di >= lo && di <= hi);
  });
}

function clearSelectionPaint() {
  document.querySelectorAll('.selrange').forEach((el) => el.classList.remove('selrange'));
}

function wireEvents() {
  const files = $('#files');

  files.addEventListener('mousedown', (e) => {
    const btn = e.target.closest('button.addc');
    if (!btn) return;
    e.preventDefault();
    const cell = btn.closest('[data-di]');
    const sec = btn.closest('section.file');
    if (!cell || !sec) return;
    dragSel = { path: sec.dataset.path, anchor: +cell.dataset.di, head: +cell.dataset.di,
      col: cell.dataset.dside || null };
    paintSelection(sec);
  });

  files.addEventListener('mouseover', (e) => {
    if (!dragSel) return;
    const cell = e.target.closest('[data-di]');
    if (!cell) return;
    // A split-view selection stays in the column it started in; the blank
    // cells of a shorter change block carry no index and are simply skipped.
    if (dragSel.col && cell.dataset.dside !== dragSel.col) return;
    const sec = cell.closest('section.file');
    if (!sec || sec.dataset.path !== dragSel.path) return;
    dragSel.head = +cell.dataset.di;
    paintSelection(sec);
  });

  document.addEventListener('mouseup', () => {
    if (!dragSel) return;
    const { path, anchor, head, col } = dragSel;
    dragSel = null;
    clearSelectionPaint();
    openForm(path, Math.min(anchor, head), Math.max(anchor, head), col);
  });

  files.addEventListener('click', (e) => {
    const sec = e.target.closest('section.file');
    if (!sec) return;
    const path = sec.dataset.path;

    const fold = e.target.closest('button[data-fold]');
    if (fold) {
      const ui = getUI(path);
      ui.collapsed = !ui.collapsed; // fold only — expansions survive
      renderFile(path);
      return;
    }

    const fcomment = e.target.closest('button[data-fcomment]');
    if (fcomment) { openFileForm(path); return; }

    const gapBtn = e.target.closest('tr.gap button');
    if (gapBtn) { expandGap(path, gapBtn.dataset.gap, gapBtn.dataset.act); return; }

    const sact = e.target.closest('button[data-sact]');
    if (sact) {
      const file = review.files.find((f) => f.path === path);
      stageAction({ action: sact.dataset.sact, path, oldPath: file && file.oldPath });
      return;
    }

    const hact = e.target.closest('button[data-hact]');
    if (hact) {
      const file = review.files.find((f) => f.path === path);
      const hunk = file && file.hunks[+hact.dataset.hunk];
      if (hunk) stageAction({ action: hact.dataset.hact, path, hunk });
      return;
    }

    const reply = e.target.closest('button[data-reply]');
    if (reply) {
      stashForm(path);
      getUI(path).form = { replyTo: reply.dataset.reply };
      renderFile(path);
      return;
    }

    const cact = e.target.closest('button[data-cact]');
    if (cact) {
      const id = cact.dataset.id;
      if (cact.dataset.cact === 'delete') {
        // Deleting a thread root takes its replies with it.
        drafts = drafts.filter((c) => c.id !== id && c.parentId !== id);
        scheduleDraftSave();
        renderFile(path);
      } else {
        stashForm(path);
        const c = drafts.find((c) => c.id === id);
        if (!c) return;
        const ui = getUI(path);
        ui.form = { editingId: id, fileLevel: c.fileLevel, parentId: c.parentId,
          side: c.side, startLine: c.startLine, endLine: c.endLine };
        ui.formText = c.text;
        renderFile(path);
      }
      return;
    }

    const fact = e.target.closest('button[data-fact]');
    if (fact) {
      if (fact.dataset.fact === 'save') saveForm(path);
      else cancelForm(path);
    }
  });

  files.addEventListener('change', (e) => {
    if (!e.target.classList.contains('viewed-box')) return;
    const sec = e.target.closest('section.file');
    const path = sec.dataset.path;
    const file = review.files.find((f) => f.path === path);
    const ui = getUI(path);
    const on = e.target.checked;
    file.viewed = on;
    ui.collapsed = on;
    if (on) {
      stashForm(path); // keep any half-written comment as an unfinished draft
      ui.expansions = {}; // marking viewed resets any expanded context
    }
    renderFile(path);
    // Persisted per branch; the server drops it if the file's diff changes.
    postJson('/api/viewed', { path, viewed: on, sig: file.sig })
      .catch((err) => toast('Could not save viewed state: ' + err.message));
  });

  files.addEventListener('input', (e) => {
    if (!e.target.classList.contains('cform-text')) return;
    const sec = e.target.closest('section.file');
    getUI(sec.dataset.path).formText = e.target.value;
  });

  files.addEventListener('keydown', (e) => {
    if (!e.target.classList.contains('cform-text')) return;
    const sec = e.target.closest('section.file');
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
      e.preventDefault();
      saveForm(sec.dataset.path);
    } else if (e.key === 'Escape') {
      cancelForm(sec.dataset.path);
    }
  });

  // Finish dialog: whatever is typed is kept as a draft on every way out
  // (confirm, Cancel, esc), so the text is never lost — only confirming
  // actually submits.
  $('#finish-dialog').addEventListener('close', () =>
    upsertOverallDraft($('#finish-overall').value));
  $('#btn-finish-confirm').addEventListener('click', submitReview);
  $('#btn-finish-cancel').addEventListener('click', () => $('#finish-dialog').close());
  $('#finish-overall').addEventListener('keydown', (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
      e.preventDefault();
      submitReview();
    }
  });

  // Destructive, so it lives behind the gear and its own confirmation, and
  // takes a real click — no keyboard shortcut.
  $('#btn-wipe-history').addEventListener('click', openResetDialog);
  $('#btn-reset-confirm').addEventListener('click', resetHistory);
  $('#btn-reset-cancel').addEventListener('click', () => $('#reset-dialog').close());

  $('#history-list').addEventListener('click', async (e) => {
    // "Copy for agent" sits inside the <summary>: stop the toggle.
    const rcopy = e.target.closest('button[data-rcopy]');
    if (rcopy) {
      e.preventDefault();
      const n = rcopy.dataset.rcopy;
      const ok = await copyToClipboard(() =>
        api('/api/revision-md?n=' + n).then((r) => r.markdown));
      toast(ok ? `Review r${n} copied, ready to paste to your agent.`
               : 'Could not copy to the clipboard.');
      return;
    }
    // Read-only sections in the audit trail: the caret just hides the body.
    const fold = e.target.closest('button[data-fold]');
    if (!fold) return;
    const collapsed = fold.closest('section.file').classList.toggle('collapsed');
    fold.title = collapsed ? 'Expand file' : 'Collapse file';
  });

  $('#btn-copy-feedback').addEventListener('click', async () => {
    const ok = await copyToClipboard(() => Promise.resolve(dialogMarkdown));
    const btn = $('#btn-copy-feedback');
    btn.textContent = ok ? 'Copied ✓' : 'Copy failed — select the text above';
    setTimeout(() => { btn.textContent = 'Copy feedback'; }, 2000);
  });
  $('#btn-review-dialog-close').addEventListener('click', () => $('#review-dialog').close());

  $('#baseline-select').addEventListener('change', () => {
    const v = $('#baseline-select').value;
    setBaseline(v ? +v : null);
    load(false);
  });

  // ---- file tree (navigation only; nothing here edits the review) ----
  const treeList = $('#tree-list');
  treeList.addEventListener('click', (e) => {
    const dir = e.target.closest('button[data-tdir]');
    if (dir) {
      const path = dir.dataset.tdir;
      if (treeFolded.has(path)) treeFolded.delete(path);
      else treeFolded.add(path);
      renderTree();
      return;
    }
    const file = e.target.closest('button[data-tfile]');
    if (file) jumpToFile(file.dataset.tfile);
  });

  const search = $('#tree-search');
  search.addEventListener('input', () => {
    treeFilter = search.value;
    renderTree();
  });
  search.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      // esc empties the box first, and only then gives up the focus.
      if (search.value) { search.value = ''; treeFilter = ''; renderTree(); }
      else search.blur();
    } else if (e.key === 'Enter') {
      e.preventDefault();
      const first = treeList.querySelector('button[data-tfile]');
      if (first) jumpToFile(first.dataset.tfile);
    }
  });

  $('#btn-tree-fold').addEventListener('click', () => {
    if (!review) return;
    const dirs = treeDirPaths(buildTree(review.files));
    // One control, whichever way there is more to do: fold everything while
    // any folder is open, otherwise open everything back up.
    if (dirs.some((d) => !treeFolded.has(d))) dirs.forEach((d) => treeFolded.add(d));
    else treeFolded.clear();
    renderTree();
  });

  $('#btn-tree').addEventListener('click', () => setTreeShown(!treeShown));

  // `/` jumps to the filter box, the way it does in most file trees — but
  // never while typing a comment.
  document.addEventListener('keydown', (e) => {
    if (e.key !== '/' || e.metaKey || e.ctrlKey || e.altKey) return;
    const t = e.target;
    const tag = t && t.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || (t && t.isContentEditable)) return;
    if (!roomForTree()) return; // no sidebar at this width
    e.preventDefault();
    if (!treeShown) setTreeShown(true);
    search.focus();
    search.select();
  });

  // Keep the tree's highlight on the file card being read.
  let spyQueued = false;
  document.addEventListener('scroll', () => {
    if (spyQueued || !review) return;
    spyQueued = true;
    raf(() => { spyQueued = false; syncActiveFromScroll(); });
  }, { passive: true });

  $('#btn-refresh').addEventListener('click', () => load(true));
  $('#btn-stale-refresh').addEventListener('click', () => load(true));
  $('#btn-collapse-all').addEventListener('click', () => setAllCollapsed(true));
  $('#btn-expand-all').addEventListener('click', () => setAllCollapsed(false));
  $('#btn-submit').addEventListener('click', openFinishDialog);

  // Poll the local server for working-tree changes; on drift, show a nudge
  // rather than yanking the view out from under the reviewer.
  setInterval(async () => {
    if (document.hidden || !review || !review.fingerprint) return;
    try {
      const s = await api('/api/status' + (ignoreWs ? '?ws=1' : ''));
      $('#stale').hidden = s.fingerprint === review.fingerprint;
    } catch (_) { /* server briefly unavailable; try again next tick */ }
  }, 4000);
}

function setAllCollapsed(v) {
  // Fold/unfold only — like the per-file caret, this never resets expansions.
  for (const f of review.files) getUI(f.path).collapsed = v;
  renderFiles();
}

/* ---------------------------------------------------------------- actions */

async function stageAction(body) {
  try {
    await postJson('/api/stage', body);
    await reloadPreservingUI();
    toast(body.action.replace('-', 'd ') + '.');
  } catch (e) {
    toast('Staging failed (writable .git required): ' + e.message);
  }
}

// Wiping review history is the escape hatch for git surgery: after a rebase,
// reset or re-created branch, the snapshots the "since review rN" baselines
// diff against describe a tree that no longer exists. Drafts and Viewed
// marks survive — they are the review in progress, not history.
function openResetDialog() {
  const n = (review && review.revisions ? review.revisions.length : 0);
  const branch = `<code>${esc(review ? review.branch : '?')}</code>`;
  $('#reset-dialog-sub').innerHTML = n
    ? `Deletes the ${n} review${n === 1 ? '' : 's'} on ${branch} —`
      + ` ${n === 1 ? 'its' : 'their'} snapshots, the`
      + ' audit trail and every “since review” baseline. The next review starts again'
      + ' at r1, and the <code>.gandalf/pending-review.md</code> handoff is cleared.'
    : `${branch} has no finished reviews. Wiping still clears the`
      + ' <code>.gandalf/pending-review.md</code> handoff — and, with the box below'
      + ' ticked, every other branch’s review history.';
  $('#reset-all-branches').checked = false;
  $('#settings').open = false;
  $('#reset-dialog').showModal();
}

async function resetHistory() {
  const scope = $('#reset-all-branches').checked ? 'all' : 'branch';
  $('#reset-dialog').close();
  try {
    const res = await postJson('/api/reset-history', { scope });
    // Every baseline just stopped existing; the full diff is the only view left.
    setBaseline(null);
    await load(false);
    toast(res.reviews
      ? `Wiped ${res.reviews} review${res.reviews === 1 ? '' : 's'}`
        + (scope === 'all' ? ` across ${res.branches} branch${res.branches === 1 ? '' : 'es'}.` : '.')
      : 'No review history to wipe.');
  } catch (e) {
    toast('Could not wipe review history: ' + e.message);
  }
}

// Re-fetch review data without resetting collapse/expansion state — used after
// staging, which changes badges but not the HEAD-vs-worktree diff itself.
async function reloadPreservingUI() {
  await flushDrafts();
  const data = await fetchReview();
  review = data;
  drafts = Array.isArray(data.drafts) ? data.drafts : [];
  renderFiles();
  renderHistory();
}

// Safari only allows clipboard writes inside the user gesture that triggered
// them, so when the text comes from a fetch we hand the clipboard a promise
// (ClipboardItem) synchronously instead of awaiting first. Resolves to
// whether the copy landed.
function copyToClipboard(getText) {
  try {
    if (typeof ClipboardItem !== 'undefined' && navigator.clipboard.write) {
      const blob = getText().then((t) => new Blob([t], { type: 'text/plain' }));
      return navigator.clipboard.write([new ClipboardItem({ 'text/plain': blob })])
        .then(() => true, () => false);
    }
    return getText()
      .then((t) => navigator.clipboard.writeText(t))
      .then(() => true, () => false);
  } catch (_) {
    return Promise.resolve(false);
  }
}

// The finish dialog: shows the rendered feedback so copying is explicit and
// repeatable (the clipboard write happens on its own click, which every
// browser allows), rather than a one-shot side effect of finishing.
let dialogMarkdown = '';
function openReviewDialog(revision, markdown) {
  dialogMarkdown = markdown;
  $('#review-dialog-title').textContent = `Review r${revision} finished`;
  $('#review-dialog-md').textContent = markdown;
  $('#btn-copy-feedback').textContent = 'Copy feedback';
  $('#review-dialog').showModal();
}

async function submitReview() {
  upsertOverallDraft($('#finish-overall').value);
  $('#finish-dialog').close();
  const btn = $('#btn-submit');
  btn.disabled = true;
  try {
    // Settle the pending draft save first so it can't land mid-submit and
    // resurrect the drafts this submission consumes.
    await flushDrafts();
    const res = await postJson('/api/submit', { comments: drafts, ignoreWs });
    drafts = [];
    openReviewDialog(res.revision, res.markdown);
    // The next loop starts here: advance the baseline so the view behind the
    // dialog becomes "what changed since the review just finished".
    setBaseline(res.revision);
    await load(false);
  } catch (e) {
    toast('Finishing the review failed: ' + e.message);
  } finally {
    updateTopbar();
  }
}

async function load(isRefresh) {
  try {
    // A refresh rebuilds all file UI; stash open forms (and settle the
    // save) first so the refetched drafts include them.
    stashAllForms();
    await flushDrafts();
    let data;
    try {
      data = await fetchReview();
    } catch (e) {
      // A remembered baseline can outlive its snapshot (cleared state, new
      // branch): fall back to the full diff instead of a dead page.
      if (baseline == null) throw e;
      const missing = baseline;
      setBaseline(null);
      data = await fetchReview();
      toast(`No snapshot for review r${missing} — showing all changes.`);
    }
    review = data;
    drafts = Array.isArray(data.drafts) ? data.drafts : [];
    fileUI.clear(); // cached content / expansions may be stale after a refresh
    for (const f of data.files) getUI(f.path).collapsed = !!f.viewed;
    $('#banner').hidden = true;
    $('#stale').hidden = true;
    renderFiles();
    renderHistory();
    renderBaselineSelect();
    if (isRefresh) toast('Diff refreshed.');
  } catch (e) {
    showError('Failed to load review: ' + e.message);
  }
}

// Per-machine code font, prepended to the default monospace stack: a font
// that isn't installed simply falls through to the system monospace, so a
// personal choice here never breaks anyone else's setup.
const MONO_FONT_KEY = 'gandalf.monoFont';
const defaultMono = getComputedStyle(document.documentElement).getPropertyValue('--mono').trim();
function applyMonoFont(name) {
  const stack = name ? `"${name.replace(/["\\]/g, '')}", ${defaultMono}` : defaultMono;
  document.documentElement.style.setProperty('--mono', stack);
}
const fontInput = $('#mono-font-input');
fontInput.value = localStorage.getItem(MONO_FONT_KEY) || '';
applyMonoFont(fontInput.value.trim());
fontInput.addEventListener('input', () => {
  const name = fontInput.value.trim();
  if (name) localStorage.setItem(MONO_FONT_KEY, name);
  else localStorage.removeItem(MONO_FONT_KEY);
  applyMonoFont(name);
});
const wsToggle = $('#ws-toggle');
wsToggle.checked = ignoreWs;
wsToggle.addEventListener('change', () => {
  ignoreWs = wsToggle.checked;
  try {
    if (ignoreWs) localStorage.setItem(WS_KEY, '1');
    else localStorage.removeItem(WS_KEY);
  } catch (_) { /* fine */ }
  load(false);
  toast(ignoreWs ? 'Ignoring whitespace changes.' : 'Showing whitespace changes.');
});
// Inline/split toggle. Purely a rendering choice: no refetch, and the diff,
// the comments and any expanded context are untouched, so flipping views keeps
// every open form and every revealed line right where it was.
const viewToggle = $('#view-toggle');
function renderViewToggle() {
  const narrowed = diffView === 'split' && !wideEnough();
  viewToggle.classList.toggle('narrowed', narrowed);
  for (const b of viewToggle.querySelectorAll('button')) {
    const on = b.dataset.view === diffView;
    b.classList.toggle('on', on);
    b.setAttribute('aria-pressed', on ? 'true' : 'false');
    if (b.dataset.view === 'split') {
      b.title = !narrowed
        ? 'Side-by-side diff: old on the left, new on the right'
        : narrowedByTree()
          ? 'Side-by-side — no room beside the file tree, so the diff shows inline;'
            + ' hide the tree or widen the window'
          : `Side-by-side — the window is under ${MIN_SPLIT_PX}px, so the diff shows inline`;
    }
  }
}
viewToggle.addEventListener('click', (e) => {
  const btn = e.target.closest('button[data-view]');
  if (!btn || btn.dataset.view === diffView) return;
  diffView = btn.dataset.view;
  try {
    if (diffView === 'split') localStorage.setItem(VIEW_KEY, 'split');
    else localStorage.removeItem(VIEW_KEY);
  } catch (_) { /* fine */ }
  renderViewToggle();
  if (review) renderFiles();
  if (diffView === 'split' && !wideEnough()) toast(narrowMessage());
});
// Crossing a width threshold re-renders the working diff in place; forms and
// expansions live in fileUI, so nothing is lost. Audit-trail diffs already on
// screen keep their shape until they are collapsed and reopened. All three
// queries matter: whether split fits depends on the window *and* on whether
// the sidebar is up (and the sidebar hides itself below MIN_TREE_PX).
for (const q of [wideQuery, wideTreeQuery, treeQuery]) {
  if (!q) continue;
  q.addEventListener('change', () => {
    renderViewToggle();
    if (diffView === 'split' && review) renderFiles();
  });
}
renderViewToggle();
renderTreeToggle();

$('#settings').addEventListener('toggle', () => {
  if ($('#settings').open) fontInput.focus();
});
document.addEventListener('click', (e) => {
  const s = $('#settings');
  if (s.open && !s.contains(e.target)) s.open = false;
});

// Sticky offsets (#stale, .file-header) must clear the topbar, whose height
// depends on font size — measure it rather than hardcoding.
const syncTopbarHeight = () =>
  document.documentElement.style.setProperty('--topbar-h', $('#topbar').offsetHeight + 'px');
new ResizeObserver(syncTopbarHeight).observe($('#topbar'));
syncTopbarHeight();

wireEvents();
load(false);
