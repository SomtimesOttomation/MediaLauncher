// Browser preview host: serve the ui folder with any local web server (for example `python -m http.server`) and open
// index.html. The page runs without PowerShell or WebView2, answering the same commands as the backend with a made-up
// library. Dev only: the real host never loads this file.
let emit = () => {};
export function attach(fn) { emit = fn; }

const IDS = ['A01', 'A02', 'A03', 'A04', 'A05', 'A06', 'B01', 'B02', 'B03', 'B04', 'B05', 'B06'];
const WORDS = ['Amber', 'Quiet', 'Northern', 'Paper', 'Silver', 'Hollow', 'Last', 'Bright', 'Distant', 'Velvet', 'Iron', 'Glass'];
const NOUNS = ['Harbor', 'Signal', 'Garden', 'Orbit', 'Lantern', 'Valley', 'Archive', 'Tide', 'Engine', 'Meadow', 'Circuit', 'Summit'];
const COLORS = ['0f766e', '1d4ed8', '15803d', 'b45309', 'dc2626', 'ea580c', '0284c7', '1e3a8a', '4b5563', '65a30d', '7c3aed', 'ca8a04'];
const settings = { theme: new URLSearchParams(location.search).get('theme') || 'system', autoRefresh: false, autoAck: false, refreshSeconds: 60, favorites: [], updateCheck: false };
const pretend = { live: 0, update: false, problem: false, fail: false };
const traffic = { requests: 0, bytes: 0, errors: 0, byKind: {}, byHost: {}, last: [] };
const saved = new Set();
let halted = false;

const seed = (s) => { let x = 17; for (const c of s) x = (x * 31 + c.charCodeAt(0)) % 2147483647; return () => (x = (x * 48271) % 2147483647) / 2147483647; };
function item(id) {
  const r = seed(id), i = IDS.indexOf(id);
  const d = new Date(); d.setDate(d.getDate() - Math.floor(r() * 400));
  return { id, title: `${WORDS[i]} ${NOUNS[Math.floor(r() * NOUNS.length)]}`, group: id[0] === 'A' ? 'Group A' : 'Group B', year: 1990 + Math.floor(r() * 36),
    length: 60 + Math.floor(r() * 90), rating: Math.round((5 + r() * 4.5) * 10) / 10, color: COLORS[i], added: d.toISOString().slice(0, 10) };
}
function body(key) {
  if (key === 'library') return { items: IDS.map(item) };
  const id = key.slice(5), r = seed(`${id}x`);
  return { ...item(id), summary: 'A made-up entry from the Sample module. A real module fills this in from its own source.',
    fields: [{ label: 'Size', value: `${(1 + r() * 20).toFixed(1)} GB` }, { label: 'Format', value: 'ABC'[Math.floor(r() * 3)] }, { label: 'Parts', value: 1 + Math.floor(r() * 8) }] };
}
function fetchKey(key) {
  setTimeout(() => {
    const kind = key.split(':')[0];
    const host = kind === 'library' ? 'library.sample.invalid' : 'details.sample.invalid';
    traffic.requests++;
    traffic.byHost[host] ||= { requests: 0, bytes: 0, errors: 0 }; traffic.byHost[host].requests++;
    traffic.byKind[kind] ||= { requests: 0, bytes: 0 }; traffic.byKind[kind].requests++;
    if (pretend.fail) {
      traffic.errors++; traffic.byHost[host].errors++;
      traffic.last.unshift({ at: new Date().toISOString(), key, bytes: 0, ms: 0, ok: false });
      emit('data', { key, ok: false, error: 'Pretend download failure (Sample tools).' }); return;
    }
    const b = body(key); const n = JSON.stringify(b).length;
    traffic.bytes += n; traffic.byHost[host].bytes += n; traffic.byKind[kind].bytes += n;
    traffic.last.unshift({ at: new Date().toISOString(), key, bytes: n, ms: 180, ok: true }); traffic.last.length = Math.min(traffic.last.length, 40);
    saved.add(key);
    emit('data', { key, ok: true, cached: false, at: new Date().toISOString(), body: b });
  }, 150);
}
const snap = () => ({ mode: 'standalone', version: '0.1.0', theme: '', settings, pretend, halted, live: pretend.live, traffic: { requests: traffic.requests, bytes: traffic.bytes, errors: traffic.errors } });

export async function request(cmd, args = {}) {
  await new Promise((r) => setTimeout(r, 20));
  switch (cmd) {
    case 'init': return snap();
    case 'watch.set': return true;
    case 'data.get':
      if (halted) throw new Error('Data traffic is paused.');
      if (args.cacheOnly) { if (saved.has(args.key)) { emit('data', { key: args.key, ok: true, cached: true, at: new Date().toISOString(), body: body(args.key) }); return 'cached'; } return 'missing'; }
      fetchKey(args.key); return 'queued';
    case 'settings.set': settings[args.key] = args.value; return snap();
    case 'sample.set': pretend[args.key] = args.key === 'live' ? Math.max(0, args.value) : args.value; return snap();
    case 'traffic.get': return { uptimeSec: Math.round(performance.now() / 1000), ...traffic, last: traffic.last[0] ? traffic.last[0].key : '', lastList: traffic.last };
    case 'traffic.stop': halted = true; emit('traffic', { stopped: true }); return snap();
    case 'traffic.resume': halted = false; emit('traffic', { stopped: false }); return snap();
    case 'sync.run': {
      const keys = ['library', ...IDS.map((i) => `item:${i}`)].filter((k) => k === 'library' || !saved.has(k)); let i = 0;
      const step = () => { if (i >= keys.length) { emit('sync', { running: false, pct: 100, exitCode: 0, summary: `${keys.length} requests`, lastRun: new Date().toISOString() }); return; }
        fetchKey(keys[i]); i++; emit('sync', { running: true, pct: Math.round(100 * i / keys.length), text: `Downloading ${i} of ${keys.length}` }); setTimeout(step, 200); };
      setTimeout(step, 50); return { started: true, requests: keys.length };
    }
    case 'sync.cancel': return true;
    case 'cache.clear': saved.clear(); return true;
    case 'update.check': setTimeout(() => emit('update', { running: false, action: 'Check', result: { status: 'none' } }), 300); return true;
    default: throw new Error(`mock: unknown command ${cmd}`);
  }
}
