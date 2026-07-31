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
    if (c.fileLevel || c.detached || !inView(c, viewBaseline)) continue;
    for (let n = c.startLine; n <= c.endLine; n++) s.add(c.side + ':' + n);
  }
  return s;
}

function rangeLabel(c) {
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
  return `<div class="comment-box form">
    <div class="chead"><span class="range">${f.editingId ? 'Edit comment' : 'New comment'} · ${esc(rangeLabel(f))}</span></div>
    <textarea class="cform-text" placeholder="Leave a comment…">${esc(ui.formText || '')}</textarea>
    <div class="form-actions">
      <button class="primary" data-fact="save">Save</button>
      <button data-fact="cancel">Cancel</button>
      <span class="form-hint">⌘⏎ save · esc cancel</span>
    </div>
  </div>`;
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

function gapRowHtml(r, readOnly) {
  if (readOnly) {
    return `<tr class="gap"><td colspan="5"><div class="gap-inner">
      <span class="gap-count">⋯ ${r.hidden} unchanged line${r.hidden === 1 ? '' : 's'} not shown</span>
    </div></td></tr>`;
  }
  const btns = [];
  if (r.hidden > EXPAND_STEP) {
    if (r.pos !== 'lead') btns.push(`<button data-act="down" data-gap="${r.id}" title="Show the next ${EXPAND_STEP} lines below the code above">↓ ${EXPAND_STEP}</button>`);
    if (r.pos !== 'tail') btns.push(`<button data-act="up" data-gap="${r.id}" title="Show the ${EXPAND_STEP} lines above the code below">↑ ${EXPAND_STEP}</button>`);
  }
  btns.push(`<button data-act="all" data-gap="${r.id}">Show all</button>`);
  return `<tr class="gap"><td colspan="5"><div class="gap-inner">
    ${btns.join('')}
    <span class="gap-count">${r.hidden} unchanged line${r.hidden === 1 ? '' : 's'} hidden</span>
  </div></td></tr>`;
}

function hunkHeadHtml(file, r, readOnly) {
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
  return `<tr class="hunk-head"><td colspan="5"><div class="hh-inner">
    <span class="hh-label">${esc(label)}</span><span class="spacer"></span>${btn}
  </div></td></tr>`;
}

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
    <button class="caret" data-fold title="${ui.collapsed ? 'Expand file' : 'Collapse file'}">${ui.collapsed ? '▸' : '▾'}</button>
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
      strip.push((!readOnly && ui.form && ui.form.editingId === c.id)
        ? formBoxHtml(ui) : commentBoxHtml(c, readOnly));
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
      const rows = buildRows(file, ui);
      const viewBaseline = (opts && opts.baseline) ?? null;
      const anchors = commentsByAnchor(comments, viewBaseline);
      const covered = coverageSet(comments, viewBaseline);
      const rendered = new Set();
      const hl = makeHighlighter(file.path);
      parts.push('<div class="diff-wrap"><table class="diff"><tbody>');
      for (const r of rows) {
        if (r.kind === 'gap') { if (hl) hl.reset(); parts.push(gapRowHtml(r, readOnly)); continue; }
        if (r.kind === 'hunkhead') { parts.push(hunkHeadHtml(file, r, readOnly)); continue; }
        parts.push(lineRowHtml(r, covered, readOnly, hl && hl.html(r)));
        for (const side of ['old', 'new']) {
          const num = r[side];
          if (num == null) continue;
          for (const c of anchors.get(side + ':' + num) || []) {
            if (rendered.has(c.id)) continue;
            rendered.add(c.id);
            const inner = (!readOnly && ui.form && ui.form.editingId === c.id)
              ? formBoxHtml(ui) : commentBoxHtml(c, readOnly);
            parts.push(`<tr class="crow"><td colspan="5">${inner}</td></tr>`);
          }
        }
        if (!readOnly && ui.form && !ui.form.editingId && ui.form.endDi === r.di) {
          parts.push(`<tr class="crow"><td colspan="5">${formBoxHtml(ui)}</td></tr>`);
        }
      }
      parts.push('</tbody></table></div>');
      const orphans = comments.filter((c) => !c.fileLevel && !rendered.has(c.id));
      if (orphans.length) {
        parts.push('<div class="orphan-note">Comments not attached to visible lines:</div>');
        for (const c of orphans) {
          const inner = (!readOnly && ui.form && ui.form.editingId === c.id)
            ? formBoxHtml(ui) : commentBoxHtml(c, readOnly);
          parts.push(`<div class="orphan-comment">${inner}</div>`);
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
    { readOnly: false, baseline: review.since });
  const old = fileSections.get(path);
  if (old) old.replaceWith(fresh);
  fileSections.set(path, fresh);
  const ta = fresh.querySelector('textarea.cform-text');
  if (ta) {
    ta.focus();
    ta.selectionStart = ta.selectionEnd = ta.value.length;
  }
  updateTopbar();
}

function renderFiles() {
  const container = $('#files');
  container.textContent = '';
  fileSections.clear();
  for (const f of review.files) {
    const sec = buildFileSection(f, draftsFor(f.path), getUI(f.path),
      { readOnly: false, baseline: review.since });
    fileSections.set(f.path, sec);
    container.appendChild(sec);
  }
  $('#empty-state').hidden = review.files.length > 0;
  $('#empty-state p').textContent = review.since
    ? `No changes since review r${review.since}.`
    : 'No changes between the working tree and the base ref.';
  updateTopbar();
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
    : 'No file or line comments — the overall comment will be the whole review.')
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
      <span class="rev-title">Review r${meta.revision}</span>
      <span class="muted">${esc(when)} · ${meta.commentCount} comment${meta.commentCount === 1 ? '' : 's'} · head ${esc(meta.head)}</span>
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
      body.appendChild(buildFileSection(f, comments, ui, { readOnly: true }));
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

function openForm(path, startDi, endDi) {
  stashForm(path);
  const file = review.files.find((f) => f.path === path);
  const ui = getUI(path);
  const rows = buildRows(file, ui).filter((r) => r.kind === 'line' && r.di >= startDi && r.di <= endDi);
  if (!rows.length) return;
  const side = rows.some((r) => r.new != null) ? 'new' : 'old';
  const nums = rows.map((r) => r[side]).filter((n) => n != null);
  const startLine = nums[0];
  const endLine = nums[nums.length - 1];
  ui.form = {
    startDi, endDi, side, startLine, endLine,
    // Old-side line numbers are meaningful only in the view they came from.
    baseline: side === 'old' ? (review.since ?? null) : null,
    excerpt: rows.map((r) => (r.t === 'add' ? '+' : r.t === 'del' ? '-' : ' ') + r.text),
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

let dragSel = null; // {path, anchor, head} in display-row indices

function paintSelection(sec) {
  const lo = Math.min(dragSel.anchor, dragSel.head);
  const hi = Math.max(dragSel.anchor, dragSel.head);
  sec.querySelectorAll('tr.ln').forEach((tr) => {
    const di = +tr.dataset.di;
    tr.classList.toggle('selrange', di >= lo && di <= hi);
  });
}

function clearSelectionPaint() {
  document.querySelectorAll('tr.ln.selrange').forEach((tr) => tr.classList.remove('selrange'));
}

function wireEvents() {
  const files = $('#files');

  files.addEventListener('mousedown', (e) => {
    const btn = e.target.closest('button.addc');
    if (!btn) return;
    e.preventDefault();
    const tr = btn.closest('tr.ln');
    const sec = btn.closest('section.file');
    dragSel = { path: sec.dataset.path, anchor: +tr.dataset.di, head: +tr.dataset.di };
    paintSelection(sec);
  });

  files.addEventListener('mouseover', (e) => {
    if (!dragSel) return;
    const tr = e.target.closest('tr.ln');
    if (!tr) return;
    const sec = tr.closest('section.file');
    if (!sec || sec.dataset.path !== dragSel.path) return;
    dragSel.head = +tr.dataset.di;
    paintSelection(sec);
  });

  document.addEventListener('mouseup', () => {
    if (!dragSel) return;
    const { path, anchor, head } = dragSel;
    dragSel = null;
    clearSelectionPaint();
    openForm(path, Math.min(anchor, head), Math.max(anchor, head));
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

    const cact = e.target.closest('button[data-cact]');
    if (cact) {
      const id = cact.dataset.id;
      if (cact.dataset.cact === 'delete') {
        drafts = drafts.filter((c) => c.id !== id);
        scheduleDraftSave();
        renderFile(path);
      } else {
        stashForm(path);
        const c = drafts.find((c) => c.id === id);
        if (!c) return;
        const ui = getUI(path);
        ui.form = { editingId: id, fileLevel: c.fileLevel,
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
    fold.textContent = collapsed ? '▸' : '▾';
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
  if (!drafts.length) { toast('Nothing to submit — leave a comment first.'); return; }
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
