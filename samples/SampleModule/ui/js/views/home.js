// Home: favourites first, then everything else, as a card grid.
import * as S from '../store.js';
import { h } from '../util.js';
import { itemCard, sectionHead, emptyState, skeletonCards, failNote } from '../components.js';

export function mount(ctx) { draw(ctx); S.loadLibrary(); }
export function update(topics, ctx) {
  if (['items', 'favorites', 'sync', 'settings', 'live'].some((t) => topics.has(t))) draw(ctx);
}

function draw({ el }) {
  const { favorites, others } = S.orderedItems();
  const out = [];
  if (!S.state.settings.autoRefresh && S.state.host) {
    out.push(h('div', { class: 'card pad', style: { marginBottom: '18px', display: 'flex', gap: '12px', alignItems: 'center', flexWrap: 'wrap' } },
      h('span', null, h('b', null, 'Automatic refresh is off. '), 'Data only updates when you ask: the ', h('b', null, '↻'), ' button (or F5), or '),
      h('button', { class: 'btn', type: 'button', onclick: () => S.runSync().catch(() => {}) }, 'Sync everything')));
  }
  if (S.state.items.length && !favorites.length) out.push(h('div', { class: 'card pad', style: { marginBottom: '18px' } },
    h('b', null, 'Pick your favourites. '), 'Click the ☆ on any item: favourites move to the front.'));
  if (favorites.length) {
    out.push(sectionHead('Favourites', `${favorites.length}`));
    out.push(h('div', { class: 'grid' }, favorites.map(itemCard)));
  }
  if (others.length) {
    out.push(sectionHead(favorites.length ? 'Everything else' : 'Library', `${others.length} items`));
    out.push(h('div', { class: 'grid' }, others.map(itemCard)));
  }
  const err = S.keyError('library');
  if (!S.state.items.length) out.push(err ? failNote(err) : S.state.ready ? emptyState('Nothing loaded yet', 'Press the refresh button or F5.') : skeletonCards(6));
  el.replaceChildren(...out);
}
