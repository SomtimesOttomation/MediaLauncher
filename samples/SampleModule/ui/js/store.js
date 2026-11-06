// App state and data loading. Views subscribe to topics and re-render.
//
// To start a real module, keep this file's shape and replace the data: the keys asked for in loadLibrary / loadItem
// and what onData does with each body. The plumbing (failed-request rule, notify, updates, pause switch, sync,
// settings, host events) stays as it is.
import * as bridge from './bridge.js';
import { asArray } from './util.js';

export const state = {
  ready: false,
  host: bridge.isHost,
  version: '',
  settings: { favorites: [], theme: 'system', updateCheck: false, autoRefresh: false, autoAck: false, refreshSeconds: 60 },
  items: [],                // the library list: [{ id, title, group, year, length, rating, color, added }]
  byId: new Map(),
  details: new Map(),       // id -> detail body
  live: { ok: true, at: 0, error: '' },
  sync: { running: false, lastRun: null, text: '', pct: 0, exitCode: null, summary: '', finishedAt: 0 },
  pretend: { live: 0, update: false, problem: false, fail: false },
  update: { phase: 'idle', info: null, pct: 0, text: '', error: '', quiet: false, note: null },
  halted: false,
};

// ---- requests and the failed-request rule --------------------------------------------------------------
// Every key the open page asked for is remembered, so Refresh (F5) can ask again. A key that failed is NOT asked for
// again when the page redraws: it waits for Refresh. (Without this, a source that is down gets hammered on every redraw.)
const req = new Map();            // key -> { loading, error, done }
let routeKeys = new Set();
export const newRoute = () => { routeKeys = new Set(); };
export const keyError = (key) => req.get(key)?.error || '';
async function want(key, { force = false, cacheOnly = false } = {}) {
  routeKeys.add(key);
  const r = req.get(key);
  if (!force && r && (r.loading || r.error || r.done)) return;
  req.set(key, { loading: true, error: '', done: false });
  try {
    const answer = await bridge.request('data.get', { key, force, cacheOnly });
    if (answer === 'missing') req.set(key, { loading: false, error: '', done: true });
  } catch (e) { req.set(key, { loading: false, error: e.message, done: false }); state.live = { ...state.live, error: e.message }; notify('live', 'items', 'item'); }
}
// Refresh: everything the open page shows, failed keys included.
export async function refresh() {
  if (state.halted) throw new Error('Data traffic is paused. Resume first.');
  const keys = [...routeKeys];
  if (!keys.length) keys.push('library');
  await Promise.all(keys.map((k) => want(k, { force: true })));
}
export const loading = () => [...routeKeys].some((k) => req.get(k)?.loading);

// ---- change notification -------------------------------------------------------------------------------
const subs = new Set();
let queued = new Set();
let raf = 0;
export function subscribe(fn) { subs.add(fn); return () => subs.delete(fn); }
export function notify(...topics) {
  topics.forEach((t) => queued.add(t));
  if (raf) return;
  raf = requestAnimationFrame(() => {
    const t = queued; queued = new Set(); raf = 0;
    subs.forEach((fn) => { try { fn(t); } catch (e) { console.error(e); } });
  });
}

// ---- helpers ---------------------------------------------------------------------------------------------
export const favSet = () => new Set(state.settings.favorites);
export const isFav = (id) => favSet().has(id);
export const item = (id) => state.byId.get(id);
export function orderedItems() {
  const fav = favSet();
  const byTitle = (a, b) => a.title.localeCompare(b.title);
  const f = state.items.filter((t) => fav.has(t.id)).sort(byTitle);
  const rest = state.items.filter((t) => !fav.has(t.id)).sort(byTitle);
  return { favorites: f, others: rest, all: [...f, ...rest] };
}

// ---- data from the host ------------------------------------------------------------------------------------
function onData(d) {
  if (!d.ok) {
    req.set(d.key, { loading: false, error: d.error, done: false });
    state.live = { ...state.live, error: d.error };
    notify('live', 'items', 'item');
    return;
  }
  req.set(d.key, { loading: false, error: '', done: true });
  const at = Date.parse(d.at) || Date.now();
  if (d.key === 'library') {
    state.items = asArray(d.body.items);
    state.byId = new Map(state.items.map((t) => [t.id, t]));
    state.live = { ok: true, at, error: '' };
    notify('items', 'live');
  } else if (d.key.startsWith('item:')) {
    state.details.set(d.key.slice(5), d.body); notify('item');
  }
}

// ---- loading (each view asks for what it shows) ---------------------------------------------------------------
export const loadLibrary = (force) => want('library', { force });
export const loadItem = (id, force) => want(`item:${id}`, { force });

// ---- app updates ----------------------------------------------------------------------------------------------
function onUpdate(d) {
  const u = state.update;
  if (d.running) {
    u.phase = d.action === 'Stage' ? 'downloading' : 'checking';
    u.pct = d.pct || 0; u.text = d.text || '';
  } else {
    const r = d.result || {};
    u.pct = 0; u.text = ''; u.error = '';
    if (r.status === 'error') { u.phase = 'error'; u.error = r.error || 'The update did not finish.'; }
    else { u.phase = r.status || 'idle'; u.info = r; }
  }
  notify('update');
}
export async function checkUpdate({ quiet = false } = {}) {
  const u = state.update;
  if (u.phase === 'checking' || u.phase === 'downloading') return;
  u.quiet = quiet; u.phase = 'checking'; u.error = ''; u.pct = 0; u.text = 'Asking GitHub for the latest release...';
  notify('update');
  try {
    const started = await bridge.request('update.check');
    if (started === false) { u.phase = u.info?.status === 'available' ? 'available' : 'idle'; notify('update'); }
  } catch (e) { u.phase = 'error'; u.error = e.message; notify('update'); }
}
export async function downloadUpdate() {
  const u = state.update;
  u.quiet = false; u.phase = 'downloading'; u.pct = 0; u.text = 'Starting...'; notify('update');
  try { await bridge.request('update.stage'); } catch (e) { u.phase = 'error'; u.error = e.message; notify('update'); }
}
export async function cancelUpdate() {
  try { await bridge.request('update.cancel'); } catch { /* ignore */ }
  state.update.phase = state.update.info?.status === 'available' ? 'available' : 'idle';
  notify('update');
}
export async function installUpdate() {
  try { await bridge.request('update.apply'); } catch (e) { state.update.phase = 'error'; state.update.error = e.message; notify('update'); }
}
export const updateReady = () => state.update.phase === 'available' || state.update.phase === 'staged';

// ---- actions ------------------------------------------------------------------------------------------------------
// In the launcher, the launcher's theme wins; standalone, the module's own setting.
export const inLauncher = () => state.hostMode === 'launcher';
export function applyTheme() {
  document.documentElement.dataset.theme = (inLauncher() && state.hostTheme) ? state.hostTheme : (state.settings.theme || 'system');
  notify('theme');
}
function takeSnapshot(snap) {
  if (!snap) return;
  state.settings = { ...state.settings, ...(snap.settings || {}) };
  state.halted = !!snap.halted;
  if (snap.pretend) state.pretend = snap.pretend;
}
// The live status button: same as the launcher's kill switch, started from inside the module.
export async function stopTraffic() { takeSnapshot(await bridge.request('traffic.stop')); req.forEach((v) => { v.loading = false; }); notify('traffic'); }
export async function resumeTraffic() { takeSnapshot(await bridge.request('traffic.resume')); state.live = { ...state.live, error: '' }; notify('traffic'); }
export async function saveSettings(patch, ack = false) {
  Object.assign(state.settings, patch);
  if ('theme' in patch) applyTheme();
  notify('settings', 'favorites');
  for (const [key, value] of Object.entries(patch)) {
    try { takeSnapshot(await bridge.request('settings.set', { key, value, ack })); } catch (e) { console.warn(e.message); throw e; }
  }
  notify('settings', 'favorites');
}
export function toggleFavorite(id) {
  const list = [...state.settings.favorites];
  const i = list.indexOf(id);
  if (i >= 0) list.splice(i, 1); else list.push(id);
  saveSettings({ favorites: list }).catch(() => {});
}
// Start a sync and show it immediately; the host then streams progress ({running, pct, text}) as 'sync' events.
export async function runSync() {
  const r = await bridge.request('sync.run');
  if (r && r.started) { state.sync = { ...state.sync, running: true, pct: 0, text: 'Starting...' }; notify('sync'); }
}
function onSync(d) {
  const wasRunning = state.sync.running;
  state.sync = { ...state.sync, ...d };
  if (wasRunning && d.running === false) state.sync.finishedAt = Date.now();
  notify('sync');
}
// Sample tools: pretend states for the launcher's tab badges, and failing downloads.
export async function setPretend(key, value) { takeSnapshot(await bridge.request('sample.set', { key, value })); notify('pretend', 'live'); }

export async function init() {
  await bridge.ready();
  const info = await bridge.request('init');
  takeSnapshot(info);
  state.version = info.version || '';
  state.update.note = info.updateNote || null;
  state.hostMode = info.mode || 'standalone';
  state.hostTheme = info.theme || '';
  applyTheme();

  // host events (module contract): launcher theme, tab shown again, kill switch
  bridge.on('host.theme', (d) => { state.hostTheme = (d && d.theme) || ''; applyTheme(); });
  bridge.on('host.visible', () => { if (state.settings.autoRefresh && !state.halted) refresh().catch(() => {}); notify('visible'); });
  bridge.on('host.hidden', () => notify('hidden'));
  bridge.on('traffic', (d) => { state.halted = !!(d && d.stopped); notify('traffic'); });
  bridge.on('data', onData);
  bridge.on('sync', onSync);
  bridge.on('update', onUpdate);

  state.ready = true;
  notify('items', 'favorites');
  if (state.host && state.settings.updateCheck && !state.update.note) setTimeout(() => checkUpdate({ quiet: true }), 4000);
  return state;
}
