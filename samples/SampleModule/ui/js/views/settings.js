// Settings: an overlay with tabs (General, Data, Sync), plus a Sample tab for trying the launcher.
import * as S from '../store.js';
import * as bridge from '../bridge.js';
import { h, ago } from '../util.js';
import { itemArt } from '../components.js';
import { openUpdate } from './update.js';
import { openTraffic } from './traffic.js';

function overlay(content) {
  const root = document.getElementById('overlay-root');
  const close = () => { root.replaceChildren(); document.removeEventListener('keydown', esc); };
  const esc = (e) => { if (e.key === 'Escape') close(); };
  document.addEventListener('keydown', esc);
  const o = h('div', { class: 'overlay', onclick: (e) => { if (e.target === o) close(); } }, h('div', { class: 'card modal' }, content(close)));
  root.replaceChildren(o);
  return close;
}
export { overlay };

const TAB_KEY = 'sample.settingsTab';
let settingsTab = 'general';
try { const v = localStorage.getItem(TAB_KEY); if (['general', 'data', 'sync', 'sample'].includes(v)) settingsTab = v; } catch (e) { /* ignore */ }

const hr = () => h('hr', { style: { border: 0, borderTop: '1px solid var(--line)' } });

function generalTab(close, repaint) {
  const s = S.state.settings;
  const favs = S.favSet();
  return [
    S.inLauncher()
      ? h('p', null, h('b', null, 'Theme '), h('small', null, 'Follows MediaLauncher.'))
      : h('p', null, h('b', null, 'Theme '),
        [['system', 'System'], ['light', 'Light'], ['dark', 'Dark']].map(([t, label]) => h('button', { class: `btn ${s.theme === t ? 'primary' : ''}`, type: 'button', style: { marginRight: '6px' }, onclick: () => { S.saveSettings({ theme: t }); repaint(); } }, label))),
    hr(),
    h('p', null, h('b', null, 'Check for Updates')),
    h('p', null, h('label', null, h('input', { type: 'checkbox', checked: s.updateCheck ? true : null, onchange: (e) => S.saveSettings({ updateCheck: e.target.checked }) }),
      ' Check GitHub for a new version when the app starts '), h('button', { class: 'btn', type: 'button', style: { marginLeft: '8px' }, onclick: () => { close(); openUpdate(); } }, `v${S.state.version || '?'} - Check for updates`)),
    h('p', null, h('small', null, 'Off by default in the Sample, so it contacts nothing on its own. A real module turns it on.')),
    hr(),
    h('p', null, h('b', null, 'Favorites '), favs.size ? [...favs].map((a) => h('span', { style: { marginRight: '6px' } }, itemArt(a, 26))) : h('small', null, 'none yet – star an item')),
  ];
}

// Automatic refresh: off by default; turning it on needs the risk acknowledged .
let confirming = false;
function refreshPanel() {
  const box = h('div');
  const paint = () => {
    const s = S.state.settings;
    if (!s.autoRefresh) {
      const ack = h('input', { type: 'checkbox' });
      const go = h('button', { class: 'btn primary', type: 'button', disabled: true, onclick: () => { S.saveSettings({ autoRefresh: true }, true).catch(() => {}); confirming = false; paint(); } }, 'Turn on automatic refresh');
      ack.addEventListener('change', () => { go.disabled = !ack.checked; });
      box.replaceChildren(
        h('p', null, h('b', null, 'Data refresh: manual '), h('small', null, 'The module only contacts its source when you press the refresh button (or F5), open a page, or run a sync.')),
        confirming
          ? h('div', { class: 'card pad warn' },
              h('b', null, 'Before you turn this on'),
              h('p', null, 'Automatic refresh polls the data source repeatedly while the app is open. Polling too often can get your connection rate-limited or blocked. You are responsible for the cadence you choose; the default is deliberately gentle.'),
              h('label', null, ack, ' I understand and accept this risk'),
              h('div', { style: { marginTop: '8px', display: 'flex', gap: '8px' } }, go, h('button', { class: 'btn', type: 'button', onclick: () => { confirming = false; paint(); } }, 'Cancel')))
          : h('button', { class: 'btn', type: 'button', onclick: () => { confirming = true; paint(); } }, 'Enable automatic refresh…'));
      return;
    }
    const secs = h('input', { type: 'number', min: 20, max: 600, step: 10, value: s.refreshSeconds, class: 'tune-input', onchange: (e) => S.saveSettings({ refreshSeconds: Number(e.target.value) }) });
    box.replaceChildren(
      h('p', null, h('b', null, 'Data refresh: automatic '), h('button', { class: 'btn', type: 'button', style: { marginLeft: '8px' }, onclick: () => { S.saveSettings({ autoRefresh: false }); paint(); } }, 'Switch back to manual')),
      h('p', null, h('small', { class: 'warn-text' }, 'Automatic refresh can get you rate-limited or blocked if set too aggressively.')),
      h('p', null, 'The open page every ', secs, ' seconds while this tab is visible.'));
  };
  paint();
  return box;
}

function dataTab() {
  const t = S.state.sync;
  return [
    refreshPanel(),
    hr(),
    h('p', null, h('b', null, 'Data sources ')),
    h('p', null, h('small', null, 'Pretend servers (library.sample.invalid, details.sample.invalid). A real module lists each source here with a link to its terms, as in module.json.')),
    h('p', null, h('button', { class: 'btn', type: 'button', onclick: async () => { await bridge.request('cache.clear'); location.reload(); } }, 'Clear saved data'), ' ',
      h('button', { class: 'btn', type: 'button', onclick: () => openTraffic() }, 'Traffic details')),
    void t,
  ].filter(Boolean);
}

// Sync: one button, with progress here, in the strip under the top bar and on the launcher's rail.
function syncPanel() {
  const box = h('div', { class: 'syncpanel' });
  const paint = () => {
    if (!box.isConnected && box.dataset.mounted) { unsub(); return; }
    box.dataset.mounted = '1';
    const sy = S.state.sync;
    const status = sy.running
      ? h('div', null, h('b', null, `${sy.pct ? sy.pct + '% · ' : ''}${sy.text || 'Starting...'}`), h('div', { class: 'bar' }, h('i', { style: { width: `${sy.pct || 3}%` } })), h('button', { class: 'btn', type: 'button', onclick: () => bridge.request('sync.cancel') }, 'Cancel update'))
      : h('small', null, sy.summary ? `Last result: ${sy.summary}` : `Last sync ${sy.lastRun ? ago(Date.parse(sy.lastRun)) : 'never'}`);
    box.replaceChildren(
      h('div', { style: { display: 'flex', gap: '8px', flexWrap: 'wrap' } },
        h('button', { class: 'btn', type: 'button', title: 'The library and every item not saved yet', disabled: sy.running || S.state.halted ? true : null, onclick: () => S.runSync().catch((e) => alert(e.message)) }, 'Sync everything')),
      h('div', { style: { marginTop: '10px', minHeight: '38px' } }, status));
  };
  const unsub = S.subscribe((t) => { if (t.has('sync')) paint(); });
  paint();
  return box;
}
function syncTab() {
  return [h('p', null, h('b', null, 'Sync '), h('small', null, 'Downloads the library and every item not saved yet. Progress also shows in the strip under the top bar and on the launcher’s tab.')), syncPanel()];
}

// Sample tools: pretend states to try MediaLauncher's tab badges, and failing downloads to try the failed-request rule.
export const hostLog = [];
function sampleTab(repaint) {
  const p = S.state.pretend;
  const set = (k, v) => S.setPretend(k, v).then(repaint).catch(() => {});
  const box = (k, label) => h('p', null, h('label', null, h('input', { type: 'checkbox', checked: p[k] ? true : null, onchange: (e) => set(k, e.target.checked) }), ` ${label}`));
  return [
    h('p', null, h('small', null, 'Not saved. For trying the launcher and the module’s rules without a real source.')),
    h('p', null, h('b', null, 'Pretend live items '),
      h('button', { class: 'btn', type: 'button', onclick: () => set('live', p.live - 1) }, '−'), ` ${p.live} `,
      h('button', { class: 'btn', type: 'button', onclick: () => set('live', p.live + 1) }, '+')),
    box('update', 'Pretend an update is available (badge on the launcher tab)'),
    box('problem', 'Pretend there is a problem (warning on the launcher tab)'),
    box('fail', 'Pretend downloads fail (a failed item waits for Refresh)'),
    hr(),
    h('p', null, h('b', null, 'Messages from the host')),
    hostLog.length ? h('ol', { class: 'hostlog' }, hostLog.map((l) => h('li', null, h('small', { class: 'muted' }, l.t), ' ', l.text))) : h('p', null, h('small', null, 'Switch tabs or change the launcher theme to see messages here.')),
  ];
}

export function openSettings() {
  overlay((close) => {
    const body = h('div', { class: 'settings-body', role: 'tabpanel' });
    const tabs = h('div', { class: 'seg settings-tabs', role: 'tablist', 'aria-label': 'Settings sections' });
    const paint = () => {
      tabs.replaceChildren(...[['general', 'General'], ['data', 'Data'], ['sync', 'Sync'], ['sample', 'Sample tools']].map(([k, label]) => h('button', {
        type: 'button', role: 'tab', 'aria-selected': settingsTab === k ? 'true' : 'false', class: settingsTab === k ? 'active' : '',
        onclick: () => { settingsTab = k; try { localStorage.setItem(TAB_KEY, k); } catch (e) { /* ignore */ } paint(); } }, label)));
      body.replaceChildren(...(settingsTab === 'data' ? dataTab() : settingsTab === 'sync' ? syncTab() : settingsTab === 'sample' ? sampleTab(paint) : generalTab(close, paint)));
    };
    paint();
    return h('div', null,
      h('h2', null, 'Settings'),
      tabs,
      body,
      h('p', { style: { textAlign: 'right' } }, h('button', { class: 'btn primary', type: 'button', onclick: close }, 'Done')));
  });
}
