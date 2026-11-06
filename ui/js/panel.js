// The notice page: shown in place of a module that is locked, failed, broken, not added, or when none are found.
import * as bridge from './bridge.js';

const ICON = {
  lock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><rect x="5" y="10.5" width="14" height="10" rx="2"/><path d="M8.5 10.5V7.5a3.5 3.5 0 0 1 7 0v3"/></svg>',
  warn: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M12 3.5 21.5 20h-19z"/><path d="M12 10v4.5M12 17.2v.3" stroke-linecap="round"/></svg>',
  plus: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="3.5" y="3.5" width="17" height="17" rx="4"/><path d="M12 8v8M8 12h8"/></svg>',
  download: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v11M7.5 10.5 12 15l4.5-4.5"/><path d="M4.5 16.5v2a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2v-2"/></svg>',
  folder: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M3.5 6.5a2 2 0 0 1 2-2h4l2 2.5h7a2 2 0 0 1 2 2v8.5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"/></svg>',
};

const root = document.getElementById('card');
let current = null;
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function head(icon, tone, title) {
  return `<div class="card-head"><span class="card-icon ${tone}">${ICON[icon]}</span><h1>${esc(title)}</h1></div>`;
}

function notesHtml(md) {
  // release notes are short markdown: **Label** lines and "- " items
  const out = []; let list = false;
  for (const raw of String(md || '').split(/\r?\n/)) {
    const line = raw.trim();
    const item = /^[-*] (.*)$/.exec(line);
    if (item) { if (!list) { out.push('<ul>'); list = true; } out.push(`<li>${esc(item[1]).replace(/\*\*(.+?)\*\*/g, '<b>$1</b>')}</li>`); continue; }
    if (list) { out.push('</ul>'); list = false; }
    const head = /^(?:#+\s*|\*\*)(.+?)(?:\*\*)?$/.exec(line);
    if (head) out.push(`<h3>${esc(head[1])}</h3>`);
    else if (line) out.push(`<p>${esc(line)}</p>`);
  }
  if (list) out.push('</ul>');
  return out.join('');
}

const unticked = new Set();              // modules the person unticked on the update page (all updatable ones start ticked)

function modVersionText(it) {
  switch (it.state) {
    case 'update': return `v${esc(it.current)} &rarr; <strong>v${esc(it.latest)}</strong>`;
    case 'current': return `v${esc(it.current)}, up to date`;
    case 'ahead': return `v${esc(it.current)}, newer than the latest release (v${esc(it.latest)})`;
    case 'nopackage': return `v${esc(it.current)}, v${esc(it.latest)} has no update package yet`;
    case 'none': return `v${esc(it.current)}, no release on GitHub yet`;
    case 'error': return `v${esc(it.current)}, couldn't check`;
    case 'notlisted': return `v${esc(it.current)}`;
    default: return `v${esc(it.current)}, not checked yet`;
  }
}

function modulesHtml(n) {
  const m = n.modules || {};
  let h = `<label class="check"><input type="checkbox" data-act="mauto" ${m.enabled ? 'checked' : ''}> Also check my modules for updates</label>`;
  if (!m.enabled) return h;
  const items = m.items || [];
  const run = m.run || {};
  const busy = run.status === 'updating' || run.status === 'restarting';
  h += '<section class="mods"><h2>Modules</h2>';
  if (busy) {
    const cur = items.find((i) => i.id === run.current);
    const text = run.status === 'restarting' ? 'Restarting MediaLauncher with the new versions...'
      : `Updating ${esc(cur ? cur.name : '')} (${run.index} of ${run.total})${run.text ? `: ${esc(run.text)}` : ''}`;
    h += `<div class="progress"><div style="width:${run.status === 'restarting' ? 100 : Math.max(2, run.pct || 0)}%"></div></div><p class="note">${text}</p>`;
  } else if (m.checking) {
    h += '<div class="progress"><div style="width:30%"></div></div><p class="note">Asking GitHub for the latest module releases...</p>';
  }
  if (!items.length) h += '<p>No modules are installed.</p>';
  else {
    h += '<div class="mod-list">' + items.map((it) => {
      const can = it.state === 'update' && !busy;
      return `<label class="mod ${it.state === 'update' ? 'has-update' : ''}">
        <input type="checkbox" data-mod="${esc(it.id)}" ${it.state === 'update' && !unticked.has(it.id) ? 'checked' : ''} ${can ? '' : 'disabled'}>
        <span class="mod-name">${esc(it.name)}<small>${esc(it.title || '')}</small></span>
        <span class="mod-ver">${modVersionText(it)}</span></label>` +
        (it.note ? `<p class="mod-note">${esc(it.note)}</p>` : '');
    }).join('') + '</div>';
  }
  const count = items.filter((i) => i.state === 'update' && !unticked.has(i.id)).length;
  const any = items.some((i) => i.state === 'update');
  h += `<div class="actions">` +
    (any ? `<button class="btn primary" data-act="mupdate" ${count && !busy ? '' : 'disabled'}>Update selected (${count})</button>` : '') +
    `<button class="btn" data-act="mcheck" ${busy || m.checking ? 'disabled' : ''}>Check again</button></div>`;
  if (any) h += '<p class="note">MediaLauncher closes the chosen modules, updates them from GitHub (checksum checked, old files backed up and put back if anything fails), then restarts on the same tab. Their settings and data are kept.</p>';
  if (m.checkedAt) h += `<p class="note">Last checked ${esc(new Date(m.checkedAt).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }))}.</p>`;
  return h + '</section>';
}

function updateHtml(n) {
  const u = n.update || {};
  const when = u.published ? new Date(u.published).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) : '';
  let body = '';
  switch (u.status) {
    case 'available':
      body = head('download', 'info', `MediaLauncher v${u.latest} is available`) +
        `<p>You have v${esc(u.current)}.${when ? ` Released ${esc(when)}.` : ''}</p>` +
        (u.notes ? `<div class="notes">${notesHtml(u.notes)}</div>` : '') +
        (u.installable ? `<div class="actions"><button class="btn primary" data-act="ustage">Download and check v${esc(u.latest)}</button></div>`
                       : '<p class="note">This release has no update package attached yet. Try again in a few minutes.</p>');
      break;
    case 'downloading':
      body = head('download', 'info', `Downloading MediaLauncher v${esc(u.latest || '')}`) +
        `<div class="progress"><div style="width:${Math.max(2, u.pct || 0)}%"></div></div><p class="note">${esc(u.text || '')}</p>
         <div class="actions"><button class="btn" data-act="ucancel">Cancel</button></div>`;
      break;
    case 'staged':
      body = head('download', 'info', `MediaLauncher v${esc(u.latest)} is ready to install`) +
        `<p>It was downloaded and its checksum matched. MediaLauncher will close, replace its own files, and reopen.</p>
         <p>Your modules and settings are not changed. If the new version doesn't start, the old one comes back by itself.</p>
         <div class="actions"><button class="btn primary" data-act="uapply">Install and restart</button></div>`;
      break;
    case 'current':
      body = head('folder', 'info', 'MediaLauncher is up to date') + `<p>You have the latest version, v${esc(u.current)}.</p>
        <div class="actions"><button class="btn" data-act="ucheck">Check again</button></div>`;
      break;
    case 'ahead':
      body = head('folder', 'info', 'This copy is newer than the latest release') + `<p>You have v${esc(u.current)}; the latest published release is v${esc(u.latest)}.</p>`;
      break;
    case 'none':
      body = head('folder', 'info', 'No MediaLauncher release yet') + `<p>Nothing has been published on GitHub yet.</p>
        <div class="actions"><button class="btn" data-act="ucheck">Check again</button></div>`;
      break;
    case 'error':
      body = head('warn', 'warn', "Couldn't check for updates") + `<pre>${esc(u.error)}</pre>
        <div class="actions"><button class="btn primary" data-act="ucheck">Try again</button></div>`;
      break;
    default:
      body = head('download', 'info', 'Checking for updates') + `<div class="progress"><div style="width:30%"></div></div><p class="note">${esc(u.text || 'Asking GitHub for the latest release...')}</p>`;
  }
  return `<button class="back" data-act="uclose">&larr; Back</button>` + body +
    `<label class="check"><input type="checkbox" data-act="uauto" ${n.updateCheck ? 'checked' : ''}> Check for updates when MediaLauncher starts (at most once a day)</label>` +
    modulesHtml(n);
}

function render(n) {
  if (!n) { root.innerHTML = ''; return; }
  const name = n.title || n.name || 'This module';
  let h = '';
  current = n;
  switch (n.kind) {
    case 'update':
      h = updateHtml(n);
      break;
    case 'locked':
      h = head('lock', 'info', `${name} is open in its own window`) +
        `<p>A module can only run in one place at a time. Switch to its window, or close it and try again here.</p>
         <div class="actions"><button class="btn primary" data-act="switch">Switch to it</button><button class="btn" data-act="retry">Try again</button></div>
         <p class="note" id="note" hidden></p>`;
      break;
    case 'missing':
      h = head('warn', 'warn', `${n.name}'s folder was removed`) +
        `<p>${esc(name)} is still loaded, but its files are gone from:<span class="path">${esc(n.folder)}</span></p>
         <p>It is paused, because syncing, updating or reloading it would fail. If you moved the folder back, reload it. Otherwise close it.</p>
         <div class="actions"><button class="btn primary" data-act="reload">Reload ${esc(n.name)}</button><button class="btn" data-act="close">Close ${esc(n.name)}</button></div>
         <p class="note" id="note" hidden></p>`;
      break;
    case 'error':
      h = head('warn', 'warn', `${name} couldn't start`) +
        (n.message ? `<pre>${esc(n.message)}</pre>` : '') +
        `<p>It still works on its own from its folder. If this keeps happening, check that it is up to date.</p>
         <div class="actions"><button class="btn primary" data-act="retry">Try again</button></div>`;
      break;
    case 'broken':
      h = head('warn', 'warn', `${n.name || 'This folder'} has a problem with its module.json`) +
        `<pre>${esc(n.message)}</pre>
         <p>Folder:<span class="path">${esc(n.folder)}</span></p>
         <p class="note">Nothing from this folder was loaded. Fix module.json and restart MediaLauncher.</p>`;
      break;
    case 'available': {
      const when = n.publishedAt ? new Date(n.publishedAt).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) : '';
      const rel = n.version ? `Latest release <strong>v${esc(n.version)}</strong>${when ? `, published ${esc(when)}` : ''}.` : 'Its latest release is on GitHub.';
      const ins = n.install || { status: 'idle' };
      const canInstall = n.hasAsset && n.hasSha;
      let top = '';
      if (ins.status === 'installing') {
        top = `<div class="progress"><div style="width:${Math.max(2, ins.pct || 0)}%"></div></div><p class="note">${esc(ins.text || 'Starting...')}</p>`;
      } else if (canInstall) {
        top = (ins.status === 'error' ? `<pre>${esc(ins.error)}</pre>` : '') +
          `<div class="actions"><button class="btn primary" data-act="install">${ins.status === 'error' ? 'Try again' : `Install ${esc(n.name)}`}</button></div>
           <p class="note">Downloads v${esc(n.version)} from GitHub, checks it against its published checksum, and puts it in the modules folder.</p>`;
      }
      const manual = `
         <ol class="steps">
           <li><button class="btn ${canInstall ? '' : 'primary'}" data-act="download">${n.hasAsset ? `Download ${esc(n.assetName || 'the zip')}` : 'Open the release on GitHub'}</button></li>
           <li>Right-click the zip, choose <strong>Extract All</strong>, and extract it to:<span class="path">${esc(n.target)}</span>
             <button class="btn" data-act="folder">Open the modules folder</button></li>
           <li>Come back here and press <strong>Refresh</strong>. The ${esc(n.name)} tab turns from grey to colour, ready to use.
             <button class="btn" data-act="refresh">Refresh</button></li>
         </ol>
         <p class="note" id="note" hidden></p>`;
      h = head('download', 'info', `Get ${name}`) +
        `<p>${esc(name)} isn't installed yet. ${rel}</p>` + top +
        (canInstall ? `<details class="manual" ${ins.status === 'error' ? 'open' : ''}><summary>Install it yourself instead</summary>${manual}</details>`
                    : manual) +
        `${n.hasAsset ? '<p class="note"><a href="#" data-act="page">See the release notes on GitHub</a></p>' : ''}
         ${n.source === 'manual' ? '<p class="note">Shown because it is enabled in catalog.json.</p>' : ''}`;
      break;
    }
    case 'declined':
      h = head('plus', '', `${name} isn't added`) +
        `<p>You chose not to add this module. Its code runs inside MediaLauncher once added, so only add modules from a source you trust.</p>
         <p>Version <strong>${esc(n.version)}</strong>, from:<span class="path">${esc(n.folder)}</span></p>
         <div class="actions"><button class="btn primary" data-act="approve">Add it</button></div>`;
      break;
    default: {
      h = head('folder', 'info', 'No modules yet') +
        `<p>Copy a module, like the SampleModule folder, into MediaLauncher's modules folder:<span class="path">${esc(n.modulesDir)}</span></p>
         <pre>MediaLauncher\\
  modules\\
    SampleModule\\      (has a module.json)
    OtherModule\\</pre>
         <div class="actions"><button class="btn" data-act="folder">Open the modules folder</button><button class="btn primary" data-act="refresh">Refresh</button></div>
         ${n.sampleDir ? `<p class="note">To try MediaLauncher without a real module, copy the Sample module into the modules folder:<span class="path">${esc(n.sampleDir)}</span></p>` : ''}
         <p class="note">MediaLauncher also looks for modules every time it starts.</p>`;
    }
  }
  root.innerHTML = h;
  root.dataset.id = n.id || '';
  root.dataset.kind = n.kind || '';
}

root.addEventListener('click', async (e) => {
  const box = e.target.closest('input[data-mod]');
  if (box) {
    if (box.checked) unticked.delete(box.dataset.mod); else unticked.add(box.dataset.mod);
    render(current);
    return;
  }
  const b = e.target.closest('[data-act]');
  if (!b) return;
  if (b.dataset.act === 'uauto') { bridge.request('update.auto', { on: b.checked }).catch(() => {}); return; }   // let the box tick
  if (b.dataset.act === 'mauto') {
    if (current && current.kind === 'update') current = { ...current, modules: { ...(current.modules || {}), enabled: b.checked } };
    bridge.request('mod.auto', { on: b.checked }).catch(() => {});
    render(current);
    return;
  }
  if (b.dataset.act === 'mupdate' || b.dataset.act === 'mcheck') {
    e.preventDefault();
    b.disabled = true;
    const items = (current && current.modules && current.modules.items) || [];
    const ids = items.filter((i) => i.state === 'update' && !unticked.has(i.id)).map((i) => i.id);
    try { await bridge.request(b.dataset.act === 'mupdate' ? 'mod.update' : 'mod.check', { ids }, 600000); } catch (err) { console.warn(err.message); }
    return;                               // the host pushes the new state
  }
  const id = root.dataset.id;
  e.preventDefault();
  const cmd = { install: 'catalog.install', uclose: 'update.close', ucheck: 'update.check', ustage: 'update.stage', ucancel: 'update.cancel', uapply: 'update.apply', reload: 'tab.reload', close: 'tab.close', retry: 'tab.retry', approve: 'tab.approve', switch: 'tab.switchTo', download: 'catalog.download', page: 'catalog.download', folder: 'modules.open', refresh: 'modules.scan' }[b.dataset.act];
  b.disabled = true;
  try {
    const args = b.dataset.act === 'page' ? { id, page: true } : { id };
    const ok = await bridge.request(cmd, args, cmd === 'modules.scan' ? 600000 : 30000);
    if (b.dataset.act === 'refresh' && ok && !ok.added && root.dataset.kind === 'available') {
      const note = document.getElementById('note');
      if (note) { note.hidden = false; note.textContent = 'Nothing new in the modules folder yet. Check that module.json sits directly inside the extracted folder, then refresh again.'; }
    }
    if (b.dataset.act === 'reload' && ok === false) {
      const note = document.getElementById('note');
      if (note) { note.hidden = false; note.textContent = "Its module.json still isn't there. Put the folder back where it was, then reload."; }
    }
    if (b.dataset.act === 'switch' && !ok) {
      const note = document.getElementById('note');
      if (note) { note.hidden = false; note.textContent = "Couldn't find its window. It may have just closed: try again."; }
    }
  } catch (err) { console.warn(err.message); }
  b.disabled = false;
});

bridge.on('notice', render);
bridge.on('install', (st) => { if (current && current.kind === 'available' && current.id === st.id && st.status !== 'installed') render({ ...current, install: st }); });
bridge.on('update', (u) => { if (current && current.kind === 'update') render({ ...current, update: u }); });
bridge.on('modules', (m) => { if (current && current.kind === 'update') render({ ...current, modules: m }); });
bridge.on('theme', (d) => bridge.setTheme(d && d.theme));

(async () => {
  try {
    const r = await bridge.request('panel.get');
    bridge.setTheme(r.theme);
    render(r.notice);
  } catch (err) { console.warn(err.message); }
})();
