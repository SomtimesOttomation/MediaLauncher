// Shared building blocks: item art, favourite star, item cards, the banner of pinned items. Replace the look freely;
// keep the patterns (stars stop click-through, the banner orders favourites first, failNote points at Refresh).
import { h } from './util.js';
import * as S from './store.js';

export const itemColor = (t) => (t && t.color ? `#${t.color}` : '#6b7280');

// ---- art ---------------------------------------------------------------------------------------------------
// The Sample draws a coloured tile with initials, so it downloads nothing. A real module would show cached artwork
// from https://<id>.cache/... (saved by its sync), falling back to this tile when an image fails.
// Wide or tall artwork: scale it inside a fixed box with object-fit, keep `pointer-events: none` on the img and a higher
// z-index on the favourite star (.tile-star), or enlarged art covers the star and it can no longer be clicked.
export function itemArt(id, size = 40) {
  const t = S.item(id);
  const initials = t ? t.title.split(' ').map((w) => w[0]).join('').slice(0, 2) : String(id).slice(0, 2);
  return h('span', { class: 'logo logo-fallback', style: { '--s': `${size}px`, '--tc': itemColor(t), borderRadius: '10px', fontSize: `${Math.round(size / 2.6)}px` }, 'data-id': id }, initials);
}

// ---- star ----------------------------------------------------------------------------------------------------
export function starButton(id, cls = '') {
  const on = S.isFav(id);
  return h('button', {
    class: `star ${on ? 'on' : ''} ${cls}`, type: 'button',
    title: on ? 'Remove from favorites' : 'Add to favorites', 'aria-pressed': on ? 'true' : 'false',
    onclick: (e) => { e.preventDefault(); e.stopPropagation(); S.toggleFavorite(id); },
  }, on ? '★' : '☆');
}

// ---- item card -----------------------------------------------------------------------------------------------
export function itemCard(t) {
  const fav = S.isFav(t.id);
  const go = () => { location.hash = `#/item/${t.id}`; };
  return h('article', {
    class: `card game ${fav ? 'fav' : ''}`, tabindex: '0', role: 'link', 'aria-label': t.title,
    onclick: go, onkeydown: (e) => { if (e.key === 'Enter') go(); },
  },
    h('header', { class: 'game-head' }, h('span', { class: 'pill' }, h('span', null, t.group)), h('span', { class: 'game-head-right' }, starButton(t.id))),
    h('div', { class: 'sides' }, h('div', { class: 'side', style: { '--tc': itemColor(t) } },
      h('span', { class: 'side-team' }, itemArt(t.id, 68), h('span', { class: 'side-names' }, h('b', null, t.title), h('small', null, `${t.year} · ${t.length} min`))),
      h('span', { class: 'score' }, t.rating))),
    h('footer', { class: 'game-foot' }, h('span', { class: 'venue' }, `Added ${t.added}`)));
}

// ---- banner of favourites and everything else ------------------------------------------------------------------
export function renderBanner(el, activeId) {
  const { favorites, others } = S.orderedItems();
  el.replaceChildren();
  el.hidden = !favorites.length && !others.length;
  const strip = h('div', { class: 'banner-strip', role: 'list' });
  const tile = (t, isFav) => h('a', {
    class: `tile ${isFav ? 'fav' : ''} ${t.id === activeId ? 'active' : ''}`, href: `#/item/${t.id}`, role: 'listitem',
    title: t.title, style: { '--tc': itemColor(t) },
  }, starButton(t.id, 'tile-star'), itemArt(t.id, 72), h('span', { class: 'tile-code' }, t.id));
  favorites.forEach((t) => strip.append(tile(t, true)));
  if (favorites.length) strip.append(h('span', { class: 'banner-divider', 'aria-hidden': 'true' }));
  others.forEach((t) => strip.append(tile(t, false)));

  const scroll = (dir) => strip.scrollBy({ left: dir * Math.max(300, strip.clientWidth * 0.8), behavior: 'smooth' });
  const left = h('button', { class: 'banner-btn left', type: 'button', 'aria-label': 'Scroll left', onclick: () => scroll(-1) }, '‹');
  const right = h('button', { class: 'banner-btn right', type: 'button', 'aria-label': 'Scroll right', onclick: () => scroll(1) }, '›');
  strip.addEventListener('wheel', (e) => {
    if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) { strip.scrollLeft += e.deltaY; e.preventDefault(); }
  }, { passive: false });
  const update = () => {
    left.classList.toggle('hide', strip.scrollLeft < 8);
    right.classList.toggle('hide', strip.scrollLeft + strip.clientWidth >= strip.scrollWidth - 8);
  };
  strip.addEventListener('scroll', update, { passive: true });
  el.append(left, strip, right);
  requestAnimationFrame(() => {
    const active = strip.querySelector('.tile.active');
    if (active) active.scrollIntoView({ inline: 'center', block: 'nearest' });
    update();
  });
}

// ---- small pieces ------------------------------------------------------------------------------------------------
export const emptyState = (title, body, action) =>
  h('div', { class: 'empty' }, h('h3', null, title), body ? h('p', null, body) : null, action || null);

export function skeletonCards(n = 3) {
  return h('div', { class: 'grid' }, Array.from({ length: n }, () => h('div', { class: 'card skeleton' })));
}

export function sectionHead(title, sub, right) {
  return h('div', { class: 'section-head' }, h('h2', null, title, sub ? h('small', null, sub) : null), right || null);
}

// A failed request, as a note with the Refresh hint (the page never retries on its own).
export function failNote(err) {
  return emptyState('Could not load', `${err} Press Refresh (F5) to try again.`);
}
