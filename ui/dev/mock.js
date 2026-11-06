// Mock host for previewing the rail and notice pages in a normal browser.
//   rail.html?theme=dark        panel.html#locked  (locked | error | broken | declined | empty)
const alphaIcon = 'data:image/svg+xml;base64,' + btoa('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect x="3" y="3" width="26" height="26" rx="7" fill="#0f766e"/><circle cx="16" cy="16" r="6" fill="#fff"/></svg>');
const betaIcon = 'data:image/svg+xml;base64,' + btoa('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect x="3" y="3" width="26" height="26" rx="7" fill="#7c3aed"/><path d="M10 22 16 9l6 13z" fill="#fff"/></svg>');

const params = new URLSearchParams(location.search);
let theme = params.get('theme') || 'system';
let emit = () => {};
const tabs = [
  { id: 'alpha', name: 'Alpha', title: 'Alpha module', version: '0.11.0', state: 'ready', icon: alphaIcon, live: 3, syncing: false, syncPct: null, update: '0.12.0', statusError: null, error: '' },
  { id: 'beta', name: 'Beta', title: 'Beta module', version: '0.1.0', state: 'ready', icon: betaIcon, live: 0, syncing: true, syncPct: 40, update: null, statusError: null, error: '' },
  { id: 'delta', name: 'Delta', title: 'Delta module', version: '0.1.0', state: 'locked', icon: '', live: 0, syncing: false, syncPct: null, update: null, statusError: null, error: '' },
  { id: 'gamma', name: 'Gamma', title: 'Gamma module', version: '0.3.0', state: 'available', icon: betaIcon, live: 0, syncing: false, syncPct: null, update: null, statusError: null, error: '' },
  { id: 'sample', name: 'Sample', title: 'Sample Module', version: '0.1.0', state: 'declined', icon: '', live: 0, syncing: false, syncPct: null, update: null, statusError: null, error: '' },
  { id: 'broken1', name: 'OldModule', title: '', version: '', state: 'broken', icon: '', live: 0, syncing: false, syncPct: null, update: null, statusError: null, error: '"backend" not found: modules/Old.Host.psm1' },
];
let active = 'alpha';

const notices = {
  locked: { kind: 'locked', id: 'delta', name: 'Delta', title: 'Delta module', version: '0.1.0', folder: 'C:\\Tools\\MediaLauncher\\modules\\AlphaModule' },
  error: { kind: 'error', id: 'beta', name: 'Beta', title: 'Beta module', version: '0.1.0', folder: 'C:\\Tools\\MediaLauncher\\modules\\AlphaModule', message: 'Its backend does not export Stop-ModuleTraffic (module contract 1).' },
  broken: { kind: 'broken', id: 'broken1', name: 'OldModule', folder: 'C:\\Tools\\MediaLauncher\\modules\\OldModule', message: '"backend" not found: modules/Old.Host.psm1' },
  declined: { kind: 'declined', id: 'sample', name: 'Sample', title: 'Sample Module', version: '0.1.0', folder: 'C:\\Tools\\MediaLauncher\\modules\\SampleModule' },
  available: { kind: 'available', id: 'alpha', name: 'Alpha', title: 'Alpha module', repo: 'SomtimesOttomation/AlphaModule', version: '0.12.0', publishedAt: '2026-10-26T14:00:00Z', assetName: 'AlphaModule-v0.12.0.zip', hasAsset: true, hasSha: true, source: 'github', install: location.search.includes('installing') ? { id: 'alpha', status: 'installing', pct: 46, text: 'Downloading 0.3 of 0.7 MB' } : null, modulesDir: 'C:\\Tools\\MediaLauncher\\modules', target: 'C:\\Tools\\MediaLauncher\\modules\\AlphaModule' },
  missing: { kind: 'missing', id: 'alpha', name: 'Alpha', title: 'Alpha module', version: '0.12.0', folder: 'C:\\Tools\\MediaLauncher\\modules\\AlphaModule' },
  update: { kind: 'update', updateCheck: true,
    modules: {
      enabled: !location.search.includes('modoff'), checking: false, checkedAt: '2026-10-28T13:10:00Z',
      run: location.search.includes('modrun') ? { status: 'updating', total: 2, index: 1, current: 'alpha', pct: 46, text: 'Downloading 0.3 of 0.7 MB' } : { status: 'idle' },
      items: [
        { id: 'alpha', name: 'Alpha', title: 'Alpha module', current: '0.12.0', latest: '0.15.0', state: 'update', note: '' },
        { id: 'beta', name: 'Beta', title: 'Beta module', current: '0.1.0', latest: '0.2.0', state: 'update', note: '' },
        { id: 'delta', name: 'Delta', title: 'Delta module', current: '0.3.0', latest: '0.3.0', state: 'current', note: '' },
        { id: 'sample', name: 'Sample', title: 'Sample Module', current: '0.1.0', latest: '', state: 'notlisted', note: "Not in MediaLauncher's list of modules: update it from inside the module." },
      ],
    }, update: { status: location.search.includes('staged') ? 'staged' : 'available', current: '0.2.0', latest: '0.3.0', published: '2026-11-02T12:00:00Z', installable: true, pct: 0, text: '',
    notes: '**Feature**\n- Settings page for the launcher\n- Drag tabs to reorder\n\n**Bug/Fix**\n- Fixed the stop button toast in dark mode.' } },
  empty: { kind: 'empty', modulesDir: 'C:\\Tools\\MediaLauncher\\modules', scanFolders: ['C:\\Tools\\MediaLauncher\\modules'] },
};

export function attach(fn) { emit = fn; window.__pushTabs = () => emit('tabs', { tabs, active, theme }); }

export async function request(cmd, args) {
  await new Promise((r) => setTimeout(r, 30));
  switch (cmd) {
    case 'rail.init':
      setTimeout(() => emit('tabs', { tabs, active, theme, launcherUpdate: '0.3.0', overlay: location.hash === '#update' ? 'update' : '' }), 10);
      return { version: '0.2.0', theme, debug: true };
    case 'tabs.reorder': {
      const by = new Map(tabs.map((t) => [t.id, t]));
      const next = args.ids.map((id) => by.get(id)).filter(Boolean);
      tabs.splice(0, tabs.length, ...next, ...tabs.filter((t) => !args.ids.includes(t.id)));
      window.__lastOrder = args.ids;
      return true;
    }
    case 'tab.select': active = args.id; setTimeout(() => emit('tabs', { tabs, active, theme }), 10); return true;
    case 'theme.set': theme = args.theme; return true;
    case 'app.restart': return window.confirm('Mock: restart MediaLauncher?') ? true : false;
    case 'modules.scan': return { added: 1, removed: 0, broken: 0, total: tabs.length };
    case 'traffic.stop': return window.confirm('Stop all traffic in every module now?') ? 2 : 0;
    case 'panel.get': return { notice: notices[location.hash.slice(1)] || notices.locked, theme };
    case 'mod.auto': case 'mod.check': case 'mod.update':
    case 'catalog.install': case 'update.open': case 'update.close': case 'update.check': case 'update.stage': case 'update.apply': case 'update.auto': case 'update.cancel': case 'tab.retry': case 'tab.approve': case 'tab.close': case 'catalog.download': case 'modules.open': return true;
    case 'tab.switchTo': case 'tab.reload': return false;
    default: throw new Error(`mock: unknown command ${cmd}`);
  }
}
