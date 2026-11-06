// Item page: hero (art, title, star, key facts with hover cards) above a detail table.
import * as S from '../store.js';
import { h } from '../util.js';
import { itemArt, itemColor, starButton, emptyState, failNote } from '../components.js';
import { calc } from '../formulas.js';

export function mount(ctx) { S.loadLibrary(); S.loadItem(ctx.arg); draw(ctx); }
export function update(topics, ctx) { if (['item', 'items', 'favorites', 'sync'].some((t) => topics.has(t))) draw(ctx); }

function draw({ el, arg }) {
  const t = S.item(arg);
  const d = S.state.details.get(arg);
  const err = S.keyError(`item:${arg}`);
  if (!t && !d) { el.replaceChildren(err ? failNote(err) : emptyState('Loading...', '')); return; }
  const x = d || t;
  const hero = h('section', { class: 'card hero', style: { '--tc': itemColor(x) } },
    itemArt(arg, 96),
    h('div', null,
      h('h1', null, x.title, ' ', starButton(arg)),
      h('div', { class: 'meta' }, `${x.group} · ${x.year}`),
      h('dl', { class: 'kv', style: { marginTop: '8px' } },
        h('dt', null, h('span', calc('rating'), 'Rating')), h('dd', null, x.rating),
        h('dt', null, h('span', calc('length'), 'Length')), h('dd', null, `${x.length} min`))));
  const body = d
    ? h('div', { class: 'card pad' }, h('p', null, d.summary),
        h('table', { class: 'tbl' }, h('tbody', null, (d.fields || []).map((f) => h('tr', null, h('th', null, f.label), h('td', null, f.value))))))
    : err ? failNote(err) : emptyState('Loading details...', '');
  el.replaceChildren(hero, body);
}
