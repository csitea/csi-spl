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
export const TAP_KINDS = ['bounce', 'bubble', 'pop', 'flip', 'pulse', 'lift', 'nudge', 'wiggle', 'hop', 'tilt'] as const
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
const DONE = Symbol('tapDone')
type TapEl = HTMLElement & { [KIND]?: TapKind | undefined, [PLAY]?: () => void, [DONE]?: (e: AnimationEvent) => void }

function reduced() {
  return typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches
}

function iconOf(el: HTMLElement): Element {
  return el.querySelector('svg') || el
}

function play(el: TapEl) {
  const kind = el[KIND]
  if (!kind || reduced()) return
  const icon = iconOf(el)
  if (icon.classList.contains('tap-anim')) {
    /* a second tap while it runs starts it again */
    icon.classList.remove(...CLASSES)
    void el.offsetWidth
  }
  icon.classList.add('tap-anim', 'tap-anim--' + kind)
}

export const vTapAnim: Directive<HTMLElement, TapKind | undefined> = {
  mounted(el: TapEl, binding) {
    el[KIND] = binding.value
    el[PLAY] = () => play(el)
    el[DONE] = (e: AnimationEvent) => {
      if (e.animationName.startsWith('tap-')) (e.target as Element).classList.remove(...CLASSES)
    }
    el.addEventListener('click', el[PLAY])
    el.addEventListener('animationend', el[DONE])
    el.addEventListener('animationcancel', el[DONE])
  },
  updated(el: TapEl, binding) {
    el[KIND] = binding.value
  },
  beforeUnmount(el: TapEl) {
    if (el[PLAY]) el.removeEventListener('click', el[PLAY])
    if (el[DONE]) {
      el.removeEventListener('animationend', el[DONE])
      el.removeEventListener('animationcancel', el[DONE])
    }
  },
  getSSRProps() {
    return {}
  },
}
