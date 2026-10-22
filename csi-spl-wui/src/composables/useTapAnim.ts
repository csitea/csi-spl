import type { Directive } from 'vue'

/**
 * SPL-2062 (owner HUM-10, t1 508e17a0 msg afe08df1 and t1 8adfb7f2 msg
 * 6c4ca93d): a pressed icon plays a short movement that fits what it shows.
 * ONE set for the section rail (phone strip and desktop rail) and the phone
 * composer dock, so a later iteration changes them here and in
 * assets/css/tap-anim.css only.
 *
 * `v-tap-anim="'<kind>'"` on a button: each click puts `tap-anim
 * tap-anim--<kind>` on its icon (the first svg; the button's own class is
 * Vue's, and a NuxtLink rewrites it on the navigation the tap starts). The
 * keyframes (transform / opacity only, so nothing moves in the layout) run at
 * most 400 ms, and the classes come off on the animation's own end event: no
 * timers. Reduced motion: no class at all. An undefined kind plays nothing.
 */
export const TAP_KINDS = [
  'bounce', 'bubble', 'pop', 'flip', 'pulse', 'lift', 'nudge', 'wiggle', 'hop', 'tilt',
  /* SPL-2479 panel plan row 01: started by playTapAnim on an event */
  'draw', 'swell', 'ripple', 'greeting', 'settle',
] as const
export type TapKind = typeof TAP_KINDS[number]

/* what each section shows: a speech bubble, a tick, a page, a heartbeat ... */
const SECTION_KIND: Record<string, TapKind> = {
  channels: 'bubble',
  dm: 'bubble',
  issues: 'pop',
  calendar: 'flip',
  monitoring: 'pulse',
  docs: 'lift',
  archive: 'lift',
}

/** the tap animation of a rail section; any other section bounces */
export function railTapKind(id: string): TapKind {
  return SECTION_KIND[id] || 'bounce'
}

const CLASSES = ['tap-anim', ...TAP_KINDS.map((k) => 'tap-anim--' + k)]
const KIND = Symbol('tapKind')
const PLAY = Symbol('tapPlay')
type TapEl = HTMLElement & { [KIND]?: TapKind | undefined, [PLAY]?: () => void }

function reduced() {
  return typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches
}

function iconOf(el: HTMLElement): Element {
  return el.querySelector('svg') || el
}

/* one function, so adding it again to the same element is a no-op */
function done(e: AnimationEvent) {
  if (e.animationName.startsWith('tap-')) (e.target as Element).classList.remove(...CLASSES)
}

function listen(el: HTMLElement) {
  el.addEventListener('animationend', done)
  el.addEventListener('animationcancel', done)
}

function play(el: HTMLElement, kind: TapKind | undefined) {
  if (!kind || reduced()) return
  const icon = iconOf(el)
  if (icon.classList.contains('tap-anim')) {
    /* a second tap while it runs starts it again */
    icon.classList.remove(...CLASSES)
    void el.offsetWidth
  }
  icon.classList.add('tap-anim', 'tap-anim--' + kind)
}

/**
 * Play `kind` once on el's icon (its first svg, else el) from code, for an
 * event that is not a tap: a copy done, a badge arriving, a reconnect. The
 * same rules as the directive: nothing under reduced motion, the classes come
 * off on the animation's end, a call while it runs starts it again. SPL-2815:
 * nothing on an element that is not rendered (a hidden panel): no animation
 * runs there, so no end event would ever take the classes off.
 */
export function playTapAnim(el: HTMLElement, kind: TapKind) {
  if (reduced() || el.checkVisibility?.() === false) return
  listen(el)
  play(el, kind)
}

export const vTapAnim: Directive<HTMLElement, TapKind | undefined> = {
  mounted(el: TapEl, binding) {
    el[KIND] = binding.value
    el[PLAY] = () => play(el, el[KIND])
    el.addEventListener('click', el[PLAY])
    listen(el)
  },
  updated(el: TapEl, binding) {
    el[KIND] = binding.value
  },
  beforeUnmount(el: TapEl) {
    if (el[PLAY]) el.removeEventListener('click', el[PLAY])
    el.removeEventListener('animationend', done)
    el.removeEventListener('animationcancel', done)
  },
  getSSRProps() {
    return {}
  },
}
