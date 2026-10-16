<!-- SPL-1994 (owner HUM-10, t1 72898ea2 msg def4a52d): the hub has a
     person's post and no agent has answered it yet. `spin` = the animation
     runs; `wait` (no agent in the topic, or none within the cnf minutes) = a
     calm, still glyph. The state comes from utils/await-reply.mjs.

     The animation is ONE swappable piece (owner msgs ad9882d2, 0f442e7c):
     `anim` names an entry of AWAIT_ANIMATIONS.

     SPL-2027 (owner HUM-10, t1 72898ea2 msgs c4aae6fc, 1689b768, f7779032):
     a running robot and a brain that swells and pops join the hourglass. With
     no `anim` prop the mark draws the person's own pick (useAwaitAnim,
     Settings -> Appearance; `preview` = that setting's sample, no status).
     Each drawing is 20% bigger than the first hourglass (14 -> 16.8 px) and
     overflows its unchanged 16 px box, so the post's text and row height stay
     put. Reduced motion: every drawing stands still.

     SPL-2043 (owner HUM-10, t1 72898ea2 msgs c48092cf, 19feedf8): the pick
     `rotate`, now the default, takes the drawings in turn, ~3 s each, all the
     time while it spins; every rotating mark shares one clock
     (useAwaitRotate). Reduced motion or `wait`: the hourglass, still. Every
     drawing another 20% bigger (16.8 -> 20.16 px), still in the 16 px box.

     SPL-2113 (owner HUM-10, t1 3aa9fac2 msgs d45ec26e, c33a028e): 17
     drawings; the person ticks any of them (Settings -> Appearance) and the
     ticked ones take turns (one ticked = that one, fixed). The hourglass is
     drawn here (the still mark shows at once); each other drawing is its own
     component under await-anim/, loaded only when it shows (one plays at a
     time, so the list has no cap). Reduced motion or `wait`: the still
     hourglass; a setting sample (`preview`) keeps its own drawing, still.

     Lazy (LazyAwaitReply) and on demand: its strings wait in the second
     catalogue (utils/i18n-first-screen.mjs) and it renders nothing until
     they are merged. CSP: classes only, no :style. -->
<template>
  <span
    v-if="ready"
    class="await-reply"
    :class="[`await-reply--${state}`, `await-anim--${look}`]"
    :role="preview ? undefined : 'status'"
    :data-test="preview ? 'await-reply-preview' : 'await-reply'"
    :data-state="state"
    :data-anim="look"
    :data-pick="anim || set.join(' ')"
    :aria-label="preview ? undefined : label"
    :aria-hidden="preview ? 'true' : undefined"
    :title="preview ? undefined : label"
  >
    <svg v-if="look === 'hourglass'" class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
      <path d="M4 1.5h8M4 14.5h8M5 1.5c0 3 3 4.5 3 6.5S5 11.5 5 14.5M11 1.5c0 3-3 4.5-3 6.5s3 3.5 3 6.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
      <path d="M6.3 13.6 8 11.4l1.7 2.2z" fill="currentColor" />
    </svg>
    <!-- a wrapper that is always there: an async component never sits bare under v-if -->
    <span v-else class="await-reply__drawing"><component :is="drawing" /></span>
  </span>
</template>

<script setup lang="ts">
import type { Component } from 'vue'
import { awaitAnimation } from '~/utils/await-reply.mjs'
import { useAwaitAnim, useAwaitRotate } from '~/composables/useAwaitAnim'

/* SPL-2113: each drawing but the hourglass, its own chunk, fetched when it first shows */
const LOADERS: Record<string, () => Promise<{ default: Component }>> = {
  'robot': () => import('~/components/await-anim/Robot.vue'),
  'brain': () => import('~/components/await-anim/Brain.vue'),
  'dancing-robot': () => import('~/components/await-anim/DancingRobot.vue'),
  'dots': () => import('~/components/await-anim/Dots.vue'),
  'spinner': () => import('~/components/await-anim/Spinner.vue'),
  'radar': () => import('~/components/await-anim/Radar.vue'),
  'gears': () => import('~/components/await-anim/Gears.vue'),
  'bulb': () => import('~/components/await-anim/Bulb.vue'),
  'coffee': () => import('~/components/await-anim/Coffee.vue'),
  'orbit': () => import('~/components/await-anim/Orbit.vue'),
  'pendulum': () => import('~/components/await-anim/Pendulum.vue'),
  'bars': () => import('~/components/await-anim/Bars.vue'),
  'pencil': () => import('~/components/await-anim/Pencil.vue'),
  'rocket': () => import('~/components/await-anim/Rocket.vue'),
  'clock': () => import('~/components/await-anim/Clock.vue'),
  'wave': () => import('~/components/await-anim/Wave.vue'),
}
const DRAWINGS: Record<string, Component> = Object.fromEntries(Object.entries(LOADERS).map(([id, load]) => [id, defineAsyncComponent(load)]))

/* `anim` unset = the person's own ticked set; `preview` = the setting's sample */
const props = withDefaults(defineProps<{ state: 'spin' | 'wait', anim?: string, preview?: boolean }>(), { anim: '', preview: false })
const { set } = useAwaitAnim()
const { t, te } = useI18n({ useScope: 'global' })
/* the second catalogue holds the label; until it is merged nothing shows */
const ready = computed(() => te('await_reply.spin'))
const label = computed(() => t(props.state === 'spin' ? 'await_reply.spin' : 'await_reply.wait'))

const reduced = ref(false)
let motionQuery: MediaQueryList | null = null
const readMotion = () => { reduced.value = Boolean(motionQuery?.matches) }
onMounted(() => {
  motionQuery = window.matchMedia?.('(prefers-reduced-motion: reduce)') ?? null
  readMotion()
  motionQuery?.addEventListener?.('change', readMotion)
})
onBeforeUnmount(() => motionQuery?.removeEventListener?.('change', readMotion))

/* a mark that moves: spinning, motion welcome; a sample always draws its own */
const moving = computed(() => props.state === 'spin' && !reduced.value)
/* SPL-2043/2113: the ticked set takes turns only while moving, two or more ticked */
const rotating = computed(() => !props.anim && moving.value && set.value.length > 1)
const turn = useAwaitRotate(rotating, set)
const look = computed(() => {
  if (props.anim) return awaitAnimation(props.anim).id
  if (!moving.value) return 'hourglass'
  return awaitAnimation(rotating.value ? turn.value : set.value[0]).id
})
const drawing = computed(() => DRAWINGS[look.value] ?? null)
/* fetch the whole ticked set as the turns start, so no turn opens blank */
watch(rotating, (on) => {
  /* a warm-up only: a failed fetch is retried when that drawing shows (defineAsyncComponent) */
  if (on) for (const id of set.value) LOADERS[id]?.().catch(() => {})
}, { immediate: true })
</script>

<style scoped>
.await-reply {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  inline-size: 16px;
  block-size: 16px;
  margin-inline-start: 4px;
  color: var(--color-accent, currentColor);
  vertical-align: middle;
  flex: none;
}
.await-reply--wait { color: var(--color-muted, currentColor); }
.await-reply__drawing { display: contents; }
/* SPL-2027 (owner msg f7779032): 20% bigger than the first 14 px hourglass;
   SPL-2043 (msg 19feedf8): another 20% (16.8 -> 20.16 px). It spills over
   the 16 px box instead of growing it, so the row keeps its height. Every
   drawing component's svg carries the same class. */
.await-reply__glyph,
.await-reply__drawing :deep(.await-reply__glyph) { inline-size: 20.16px; block-size: 20.16px; flex: none; overflow: visible; }

/* the hourglass turns over, rests, turns again; only where motion is
   welcome, so reduced motion keeps it still */
@media (prefers-reduced-motion: no-preference) {
  .await-anim--hourglass.await-reply--spin .await-reply__glyph {
    animation: await-hourglass 1.8s ease-in-out infinite;
    transform-origin: 50% 50%;
  }
}
@keyframes await-hourglass {
  0%, 35% { transform: rotate(0deg); }
  65%, 100% { transform: rotate(180deg); }
}
</style>
