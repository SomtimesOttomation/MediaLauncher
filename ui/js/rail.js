// The tab rail: one tab per module, then theme and the kill switch at the bottom.
import * as bridge from './bridge.js';

const ICON = {
  system: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="8"/><path d="M12 4a8 8 0 0 1 0 16z" fill="currentColor"/></svg>',
  light: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"/></svg>',
  dark: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M19.5 14.5A8 8 0 1 1 9.5 4.5a6.5 6.5 0 0 0 10 10z"/></svg>',
  stop: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M8.3 3h7.4L21 8.3v7.4L15.7 21H8.3L3 15.7V8.3z"/><rect x="9" y="9" width="6" height="6" rx="1" fill="currentColor" stroke="none"/></svg>',
  scan: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 7a2 2 0 0 1 2-2h3.5l2 2.5h7.5a2 2 0 0 1 2 2V11"/><path d="M3.5 7v10.5a2 2 0 0 0 2 2H11"/><circle cx="16.5" cy="16.5" r="3.5"/><path d="m19 19 2 2"/></svg>',
  restart: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20 12a8 8 0 1 1-2.6-5.9"/><path d="M20 4v5h-5"/></svg>',
  lock: '<svg viewBox="0 0 12 12" fill="currentColor"><rect x="2" y="5" width="8" height="6" rx="1.2"/><path d="M4 5V3.8a2 2 0 0 1 4 0V5" fill="none" stroke="currentColor" stroke-width="1.4"/></svg>',
  up: '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6 10V2.5M2.8 5.5 6 2.3l3.2 3.2"/></svg>',
};
const THEME_NEXT = { system: 'light', light: 'dark', dark: 'system' };
const THEME_LABEL = { system: 'Theme: follows Windows', light: 'Theme: light', dark: 'Theme: dark' };
const STATE_TEXT = {
  unloaded: '', ready: '', locked: 'Open in its own window', error: "Couldn't start",
  broken: 'Problem with its module.json', declined: 'Not added', available: 'Not installed: click to get it', missing: 'Its folder was removed',
};

const tabsEl = document.getElementById('tabs');
const themeBtn = document.getElementById('btn-theme');
const killBtn = document.getElementById('btn-kill');
const scanBtn = document.getElementById('btn-scan');
const restartBtn = document.getElementById('btn-restart');
const verEl = document.getElementById('ver');

let state = { tabs: [], active: '', theme: 'system', launcherUpdate: '', overlay: '' };
let version = '';

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function tooltip(t) {
  const parts = [t.title || t.name];
  if (t.version) parts[0] += ` (v${t.version})`;
  if (STATE_TEXT[t.state]) parts.push(STATE_TEXT[t.state]);
  if (t.live > 0) parts.push(`${t.live} live`);
  if (t.syncing) parts.push(t.syncPct != null ? `Syncing ${t.syncPct}%` : 'Syncing');
  if (t.update) parts.push(`Update available: v${t.update}`);
  if (t.statusError) parts.push(t.statusError);
  parts.push('Drag to reorder');
  return parts.join('\n');
}

function badges(t) {
  let h = '';
  if (t.syncing) h += t.syncPct != null ? `<span class="ring" style="--p:${Math.max(4, Math.min(100, t.syncPct))}"></span>` : '<span class="ring spin"></span>';
  if (t.live > 0) h += '<span class="badge live"></span>';
  if (t.update) h += `<span class="badge update">${ICON.up}</span>`;
  if (t.state === 'locked') h += `<span class="badge lock">${ICON.lock}</span>`;
  else if (t.state === 'error' || t.state === 'broken' || t.state === 'missing' || t.statusError) h += '<span class="badge problem">!</span>';
  return h;
}

function render() {
  tabsEl.innerHTML = state.tabs.map((t) => {
    const icon = t.icon ? `<img src="${esc(t.icon)}" alt="" draggable="false">` : `<span class="tab-fallback">${esc((t.name || '?').slice(0, 2).toUpperCase())}</span>`;
    const cls = ['tab', t.id === state.active ? 'active' : '', (t.state === 'declined' || t.state === 'broken' || t.state === 'available') ? 'dim' : ''].join(' ').trim();
    return `<button class="${cls}" type="button" data-id="${esc(t.id)}" title="${esc(tooltip(t))}" aria-label="${esc(t.name)}" ${t.id === state.active ? 'aria-current="page"' : ''}>
      <span class="tab-icon">${icon}${badges(t)}</span><span class="tab-name">${esc(t.name)}</span></button>`;
  }).join('');
  verEl.textContent = version ? `v${version}` : '';
  verEl.classList.toggle('has-update', !!state.launcherUpdate);
  verEl.classList.toggle('open', state.overlay === 'update');
  verEl.title = state.launcherUpdate ? `MediaLauncher v${state.launcherUpdate} is available` : 'MediaLauncher updates';
  themeBtn.innerHTML = ICON[state.theme] || ICON.system;
  themeBtn.title = THEME_LABEL[state.theme] || THEME_LABEL.system;
  bridge.setTheme(state.theme);
}

// ---- drag to reorder: press on a tab and move it up or down; the order is saved by the launcher.
// Alt+Up / Alt+Down move the focused tab too. While dragging, the launcher's 2-second rail updates wait.
let drag = null;            // { el, id, startY, moved }
let held = null;            // a 'tabs' update that arrived during a drag
let swallowClick = false;

function orderFromDom() { return [...tabsEl.querySelectorAll('.tab')].map((b) => b.dataset.id); }
function saveOrder(ids) {
  const byId = new Map(state.tabs.map((t) => [t.id, t]));
  state.tabs = ids.map((id) => byId.get(id)).filter(Boolean);
  bridge.request('tabs.reorder', { ids }).catch((err) => console.warn(err.message));
}

tabsEl.addEventListener('pointerdown', (e) => {
  const b = e.target.closest('.tab');
  if (!b || e.button !== 0) return;
  drag = { el: b, id: b.dataset.id, startY: e.clientY, moved: false, before: orderFromDom().join(',') };
});
window.addEventListener('pointermove', (e) => {
  if (!drag) return;
  if (!drag.moved) {
    if (Math.abs(e.clientY - drag.startY) < 6) return;
    drag.moved = true;
    drag.el.classList.add('dragging');
    document.body.classList.add('reordering');
    try { drag.el.setPointerCapture(e.pointerId); } catch { /* ignore */ }
  }
  // move the dragged tab past any neighbour whose middle the pointer has crossed
  const prev = drag.el.previousElementSibling;
  const next = drag.el.nextElementSibling;
  if (prev && e.clientY < prev.getBoundingClientRect().top + prev.offsetHeight / 2) tabsEl.insertBefore(drag.el, prev);
  else if (next && e.clientY > next.getBoundingClientRect().top + next.offsetHeight / 2) tabsEl.insertBefore(next, drag.el);
  // scroll the rail when dragging near its ends
  const r = tabsEl.getBoundingClientRect();
  if (e.clientY < r.top + 24) tabsEl.scrollTop -= 8; else if (e.clientY > r.bottom - 24) tabsEl.scrollTop += 8;
});
function endDrag() {
  if (!drag) return;
  const d = drag;
  drag = null;
  if (d.moved) {
    d.el.classList.remove('dragging');
    document.body.classList.remove('reordering');
    swallowClick = true;                  // the click that ends a drag does not select the tab
    setTimeout(() => { swallowClick = false; }, 0);
  }
  if (held) { const h = held; held = null; state = { ...state, ...h }; }   // an update held during the drag
  if (d.moved) {
    const ids = orderFromDom();
    if (ids.join(',') !== d.before) saveOrder(ids);                       // after it, so the new order wins
  }
  if (d.moved) render();                  // a plain click must keep its element, or the click never arrives
}
tabsEl.addEventListener('dragstart', (e) => e.preventDefault());   // no native image drag: it would cancel ours
window.addEventListener('pointerup', endDrag);
window.addEventListener('pointercancel', endDrag);

tabsEl.addEventListener('keydown', (e) => {
  if (!e.altKey || (e.key !== 'ArrowUp' && e.key !== 'ArrowDown')) return;
  const b = e.target.closest('.tab');
  if (!b) return;
  e.preventDefault();
  const sib = e.key === 'ArrowUp' ? b.previousElementSibling : b.nextElementSibling;
  if (!sib) return;
  if (e.key === 'ArrowUp') tabsEl.insertBefore(b, sib); else tabsEl.insertBefore(sib, b);
  saveOrder(orderFromDom());
  render();
  const again = tabsEl.querySelector(`.tab[data-id="${CSS.escape(b.dataset.id)}"]`);
  if (again) again.focus();
});

tabsEl.addEventListener('click', (e) => {
  if (swallowClick) { swallowClick = false; return; }
  const b = e.target.closest('.tab');
  if (!b || b.dataset.id === state.active) return;
  state.active = b.dataset.id;            // show it straight away; the host confirms with a 'tabs' push
  render();
  bridge.request('tab.select', { id: b.dataset.id }).catch((err) => console.warn(err.message));
});

themeBtn.addEventListener('click', () => {
  const next = THEME_NEXT[state.theme] || 'system';
  state.theme = next;
  render();
  bridge.request('theme.set', { theme: next }).catch((err) => console.warn(err.message));
});

scanBtn.innerHTML = ICON.scan;
scanBtn.addEventListener('click', async () => {
  scanBtn.disabled = true;
  try { await bridge.request('modules.scan', {}, 600000); }    // may wait on approval dialogs; the host shows the result as a toast
  catch (err) { console.warn(err.message); }
  scanBtn.disabled = false;
});

restartBtn.innerHTML = ICON.restart;
restartBtn.addEventListener('click', async () => {
  restartBtn.disabled = true;
  restartBtn.classList.add('spin');
  let going = false;
  try { going = await bridge.request('app.restart', {}, 600000) === true; }     // may wait on a question; on success the window closes and comes back
  catch (err) { console.warn(err.message); }
  if (!going) { restartBtn.disabled = false; restartBtn.classList.remove('spin'); }
});

killBtn.innerHTML = ICON.stop;
killBtn.addEventListener('click', async () => {
  try {
    await bridge.request('traffic.stop', {}, 600000);     // waits on a confirmation dialog; the host shows the result as a toast
  } catch (err) { console.warn(err.message); }
});

bridge.on('tabs', (d) => {
  if (drag && drag.moved) { held = { ...(held || {}), ...d }; return; }    // applied when the drag ends
  state = { ...state, ...d };
  render();
});
verEl.addEventListener('click', () => bridge.request('update.open').catch((err) => console.warn(err.message)));

(async () => {
  try {
    const info = await bridge.request('rail.init');
    version = info.version || '';
    state.theme = info.theme || 'system';
    render();
  } catch (err) { console.warn(err.message); }
})();
