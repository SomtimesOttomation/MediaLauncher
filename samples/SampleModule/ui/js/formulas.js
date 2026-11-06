// Hover cards: every calculated number or abbreviation in the app can explain itself.
// Mark any element with data-calc="<key>" (and optionally data-calc-scope="item"|"detail"); hovering or focusing it shows
// the card. Add your own terms to DEFS: a title, the formula, and why it matters.
import { h } from './util.js';

// key -> (scope) => { title, formula, why, note? }
const DEFS = {
  rating: () => ({ title: 'Rating', formula: 'Rating = average score, 0 to 10', why: 'An example of a number that explains itself. Replace these with your own terms.' }),
  length: () => ({ title: 'Length', formula: 'Length = running time in minutes', why: 'Another example term. Every calculated or abbreviated number in a module should have a card like this.' }),
};

export const hasFormula = (key) => !!DEFS[key];

// Attributes to mark an element: h('span', calc('rating'), 'Rating')
export const calc = (key, scope = 'item') => (DEFS[key] ? { 'data-calc': key, 'data-calc-scope': scope, tabindex: 0, class: 'calc' } : {});

let tip = null;
function show(el) {
  const d = DEFS[el.dataset.calc]; if (!d) return;
  const c = d(el.dataset.calcScope || 'item');
  if (!tip) { tip = h('div', { class: 'calc-tip', role: 'tooltip' }); document.body.append(tip); }
  tip.replaceChildren(h('b', null, c.title), h('pre', null, c.formula), h('p', null, c.why), ...(c.note ? [h('small', null, c.note)] : []));
  tip.style.display = 'block';
  const r = el.getBoundingClientRect(), tw = tip.offsetWidth, th = tip.offsetHeight;
  let x = Math.min(window.innerWidth - tw - 10, Math.max(10, r.left + r.width / 2 - tw / 2));
  let y = r.bottom + 8; if (y + th > window.innerHeight - 10) y = Math.max(10, r.top - th - 8);
  tip.style.left = `${x}px`; tip.style.top = `${y}px`;
}
const hide = () => { if (tip) tip.style.display = 'none'; };

export function installCalcTips() {
  document.addEventListener('mouseover', (e) => { const el = e.target.closest && e.target.closest('[data-calc]'); if (el) show(el); else hide(); });
  document.addEventListener('focusin', (e) => { const el = e.target.closest && e.target.closest('[data-calc]'); if (el) show(el); });
  document.addEventListener('focusout', hide);
  window.addEventListener('scroll', hide, true);
  window.addEventListener('hashchange', hide);
}
