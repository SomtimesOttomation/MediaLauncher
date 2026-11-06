// Sample module page shell: routing, the sync progress strip, the live status pause switch, the kill-switch bar, the
// version button, the hidden traffic counter and the navigation bar. Keep this plumbing; change the views.
import * as S from './store.js';
import * as bridge from './bridge.js';
import { h, ago } from './util.js';
import { renderBanner } from './components.js';
import * as home from './views/home.js';
import * as itemV from './views/item.js';
import { openSettings, hostLog } from './views/settings.js';
import { openTraffic } from './views/traffic.js';
import { openUpdate } from './views/update.js';
import { installCalcTips } from './formulas.js';

const $ = (s) => document.querySelector(s);
const view = $('#view');
let current = null; // { mod, ctx, cleanup }

export function toast(msg) {
  const t = h('div', { class: 'toast' }, msg);
  $('#toasts').append(t);
  setTimeout(() => t.remove(), 3500);
}

function route() {
  const hash = location.hash.replace(/^#\/?/, '');
  const [name, arg] = hash.split('/');
  const map = { '': home, item: itemV };
  const mod = map[name] || home;
  const routeName = map[name] ? (name || 'home') : 'home';
  document.querySelectorAll('#nav a, #btn-home').forEach((a) => a.classList.toggle('active', a.dataset.route === routeName));
  current?.cleanup?.();
  view.replaceChildren();
  S.newRoute();
  const ctx = { el: view, arg: arg ? decodeURIComponent(arg) : '' };
  current = { mod, ctx, cleanup: mod.mount(ctx) };
  renderBanner($('#banner'), routeName === 'item' ? ctx.arg : '');
  // what the opt-in refresh timer may refetch: the keys the open page shows
  bridge.request('watch.set', { keys: routeName === 'home' ? ['library'] : routeName === 'item' ? [`item:${ctx.arg}`] : [] }).catch(() => {});
  window.scrollTo(0, 0);
}

function themeIcon() {
  const t = S.state.settings.theme;
  $('#btn-theme').textContent = t === 'dark' ? '☾' : t === 'light' ? '☀' : '◐';
  $('#btn-theme').title = `Theme: ${t} (click to change)`;
}

// ---- updates: one quiet nudge when the startup check finds something; the version chip carries the rest
let nudged = '';
function updateToast() {
  const u = S.state.update;
  if (u.phase === 'available' && u.quiet && nudged !== u.info?.latest) { nudged = u.info.latest; toast(`Version ${u.info.latest} is available. Click the version number to update.`); }
}

// ---- sync progress strip --------------------------------------------------------------------
let lastRunning = false;
function syncBar() {
  const bar = $('#syncbar'), sy = S.state.sync;
  const fill = bar.querySelector('.syncbar-fill'), txt = bar.querySelector('.syncbar-text');
  if (sy.running) {
    bar.hidden = false; bar.classList.remove('fail');
    bar.classList.toggle('indeterminate', !sy.pct);
    fill.style.width = `${sy.pct || 0}%`;
    txt.textContent = `Updating data · ${sy.pct ? sy.pct + '% · ' : ''}${sy.text || sy.line || ''}`;
  } else if (lastRunning) {
    const ok = sy.exitCode === 0 || sy.exitCode == null;
    bar.classList.remove('indeterminate'); bar.classList.toggle('fail', !ok);
    fill.style.width = '100%';
    txt.textContent = sy.cancelled ? 'Update stopped' : ok ? `Update finished${sy.summary ? ' · ' + sy.summary : ''}` : `Update finished with errors${sy.summary ? ' · ' + sy.summary : ''}`;
    toast(txt.textContent);
    setTimeout(() => { if (!S.state.sync.running) bar.hidden = true; }, 6000);
  }
  lastRunning = !!sy.running;
}

function liveStatus() {
  const el = $('#live-status');
  const l = S.state.live;
  const anyLive = S.state.pretend.live > 0;      // a real module: whatever "live" means for it (playing, downloading...)
  const halted = !!S.state.halted;
  const err = l.error || (S.state.pretend.problem ? 'Pretend problem from the Sample module.' : '');
  el.className = `live-status np-live ${anyLive && !halted ? 'on' : ''} ${err && !halted ? 'err' : ''} ${halted ? 'halted' : ''}`;
  el.setAttribute('aria-pressed', halted ? 'true' : 'false');
  const manual = !S.state.settings.autoRefresh;
  el.textContent = err ? 'Offline' : manual ? (l.at ? `Manual · updated ${ago(l.at)}` : 'Manual refresh') : anyLive ? 'Live' : (l.at ? `Updated ${ago(l.at)}` : '');
  if (halted) el.textContent = 'Paused';
  el.title = halted ? 'All data traffic is paused. Click to resume.' : `${err ? `${err}\n` : ''}Click to pause all data traffic`;
}

// secret: five clicks on the brand within 3 seconds opens the traffic panel; otherwise it goes home
let clicks = [];
$('#brand').addEventListener('click', () => {
  const now = Date.now();
  clicks = clicks.filter((t) => now - t < 3000).concat(now);
  if (clicks.length >= 5) { clicks = []; openTraffic(); } else if (clicks.length === 1) location.hash = '#/';
});

$('#btn-theme').addEventListener('click', () => {
  const order = ['system', 'light', 'dark'];
  const next = order[(order.indexOf(S.state.settings.theme) + 1) % 3];
  S.saveSettings({ theme: next });
});
// Back: the page's own history (every view is a #/ route). Also Alt+Left and the mouse's back button.
let navDepth = 0;
window.addEventListener('hashchange', () => { navDepth++; });
const goBack = () => { if (navDepth > 0) { navDepth -= 2; history.back(); } else location.hash = '#/'; };
$('#btn-fwd').addEventListener('click', () => history.forward());
document.addEventListener('keydown', (e) => { if (e.altKey && e.key === 'ArrowRight') { e.preventDefault(); history.forward(); } });
window.addEventListener('mouseup', (e) => { if (e.button === 4) { e.preventDefault(); history.forward(); } });
$('#btn-back').addEventListener('click', goBack);
document.addEventListener('keydown', (e) => { if (e.altKey && e.key === 'ArrowLeft') { e.preventDefault(); goBack(); } });
window.addEventListener('mouseup', (e) => { if (e.button === 3) { e.preventDefault(); goBack(); } });
$('#btn-settings').addEventListener('click', openSettings);
// Live status doubles as a pause switch: one click stops every data request until clicked again.
$('#live-status').addEventListener('click', () => (S.state.halted ? S.resumeTraffic() : S.stopTraffic()).catch((e) => toast(e.message)));
$('#btn-version').addEventListener('click', openUpdate);

// Kill switch (MediaLauncher): a bar until the person resumes.
function haltBar() {
  const b = $('#haltbar');
  b.hidden = !S.state.halted;
  if (!S.state.halted) { b.replaceChildren(); return; }
  b.replaceChildren(h('span', null, 'Data refresh stopped. The module will not fetch anything until you resume.'),
    h('button', { class: 'btn primary', type: 'button', onclick: () => S.resumeTraffic().catch((e) => toast(e.message)) }, 'Resume'));
}

function versionChip() {
  const b = $('#btn-version'), u = S.state.update;
  b.textContent = S.state.version ? `v${S.state.version}` : '';
  b.hidden = !S.state.version;
  b.classList.toggle('has-update', S.updateReady());
  b.title = u.phase === 'available' ? `Version ${u.info?.latest} is available` : u.phase === 'staged' ? 'Update downloaded: click to install' : 'Check for updates';
}
// Refresh: everything the open page shows, including anything that failed (nothing is retried on its own).
$('#btn-refresh').addEventListener('click', async () => {
  const b = $('#btn-refresh'); b.classList.add('spin');
  try { await S.refresh(); } catch (e) { toast(e.message); }
  const t0 = Date.now();
  const iv = setInterval(() => { if (!S.loading() || Date.now() - t0 > 20000) { clearInterval(iv); b.classList.remove('spin'); } }, 200);
});
document.addEventListener('keydown', (e) => { if (e.key === 'F5') { e.preventDefault(); $('#btn-refresh').click(); } });

// Search: each module decides what it searches. The Sample searches item titles.
const res = $('#psearch-results');
$('#psearch').addEventListener('input', (e) => {
  const q = e.target.value.trim().toLowerCase();
  if (!q) { res.hidden = true; return; }
  const items = S.state.items.map((t) => ({ label: `${t.title} (${t.year})`, href: `#/item/${t.id}`, text: `${t.title} ${t.id}`.toLowerCase() }));
  const hits = items.filter((x) => x.text.includes(q)).slice(0, 12);
  res.replaceChildren(...(hits.length ? hits.map((x) => h('a', { href: x.href }, x.label)) : [h('div', { class: 'empty' }, 'No matches')]));
  res.hidden = false;
});
res.addEventListener('click', () => { res.hidden = true; $('#psearch').value = ''; });
document.addEventListener('click', (e) => { if (!e.target.closest('.psearch')) res.hidden = true; });

// Host messages, shown in Settings > Sample tools.
const log = (text) => { hostLog.unshift({ t: new Date().toLocaleTimeString(), text }); hostLog.length = Math.min(hostLog.length, 8); };
bridge.on('host.visible', () => log('host.visible: tab shown'));
bridge.on('host.hidden', () => log('host.hidden: tab hidden'));
bridge.on('host.theme', (d) => log(`host.theme: ${d && d.theme}`));
bridge.on('traffic', (d) => log(`traffic: ${d && d.stopped ? 'stopped' : 'resumed'}`));

S.subscribe((topics) => {
  if (topics.has('theme') || topics.has('settings')) themeIcon();
  if (topics.has('traffic')) { haltBar(); liveStatus(); }
  if (topics.has('settings') || topics.has('pretend')) liveStatus();
  if (topics.has('items') || topics.has('favorites')) renderBanner($('#banner'), location.hash.startsWith('#/item/') ? decodeURIComponent(location.hash.slice(7)) : '');
  if (topics.has('live') || topics.has('items')) liveStatus();
  if (topics.has('sync')) syncBar();
  if (topics.has('update')) { versionChip(); updateToast(); }
  current?.mod.update?.(topics, current.ctx);
});
setInterval(liveStatus, 15000);

window.addEventListener('hashchange', route);
S.init().then(() => {
  if (S.inLauncher()) $('#btn-theme').hidden = true;      // the launcher owns the theme
  haltBar();
  themeIcon(); liveStatus(); route(); versionChip(); installCalcTips();
  const n = S.state.update.note;
  if (n) toast(n.ok ? `Updated to v${n.to}.` : `The update to v${n.to} did not work (${n.reason || 'unknown reason'}). v${n.from} was restored.`);
}).catch((e) => {
  view.replaceChildren(h('div', { class: 'empty' }, h('h3', null, 'Could not start'), h('p', null, e.message)));
});
