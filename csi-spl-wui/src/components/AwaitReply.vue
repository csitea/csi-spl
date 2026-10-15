<!-- SPL-1994 (owner HUM-10, t1 72898ea2 msg def4a52d): the hub has a
     person's post and no agent has answered it yet. `spin` = the animation
     runs; `wait` (no agent in the topic, or none within the cnf minutes) = a
     calm, still glyph. The state comes from utils/await-reply.mjs.

     The animation is ONE swappable piece (owner msgs ad9882d2, 0f442e7c):
     `anim` names an entry of AWAIT_ANIMATIONS - a CSS animation (its class,
     keyframes below) or a looping clip (animated WebP as a lazy <img>, or a
     muted <video>, no autoplay under prefers-reduced-motion).

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

     Lazy (LazyAwaitReply) and on demand: its strings wait in the second
     catalogue (utils/i18n-first-screen.mjs) and it renders nothing until
     they are merged. CSP: classes only, no :style. -->
<template>
  <span
    v-if="ready"
    class="await-reply"
    :class="[`await-reply--${state}`, `await-anim--${look.id}`, look.kind === 'css' ? look.className : 'await-anim--clip']"
    :role="preview ? undefined : 'status'"
    :data-test="preview ? 'await-reply-preview' : 'await-reply'"
    :data-state="state"
    :data-anim="look.id"
    :data-pick="chosen"
    :aria-label="preview ? undefined : label"
    :aria-hidden="preview ? 'true' : undefined"
    :title="preview ? undefined : label"
  >
    <img
      v-if="clip && clip.image"
      class="await-reply__clip"
      :src="clip.src"
      alt=""
      loading="lazy"
      decoding="async"
      width="16"
      height="16"
    >
    <video
      v-else-if="clip"
      class="await-reply__clip"
      :src="clip.src"
      :poster="look.poster || undefined"
      :autoplay="!reduced"
      muted
      loop
      playsinline
      preload="none"
      width="16"
      height="16"
      aria-hidden="true"
    />
    <!-- a small robot running to the right: legs and arms swing, it bobs -->
    <svg v-else-if="look.id === 'robot'" class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
      <g fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
        <path class="await-robot__speed" d="M.8 6.5h2M.4 9.5h2.4" stroke-width="1" />
        <path d="M8 2.6V1.2" />
        <rect x="4.6" y="2.6" width="6.8" height="4.4" rx="1.3" />
        <rect x="5.6" y="7.6" width="4.8" height="3.8" rx=".8" />
        <path class="await-robot__limb await-robot__arm-a" d="M8 8.6l2.6 1.6" />
        <path class="await-robot__limb await-robot__arm-b" d="M8 8.6 5.4 10.2" />
        <path class="await-robot__limb await-robot__leg-a" d="M7 11.4v3.4" />
        <path class="await-robot__limb await-robot__leg-b" d="M9 11.4v3.4" />
      </g>
      <circle cx="8" cy="1" r=".9" fill="currentColor" />
      <circle cx="9.7" cy="4.6" r=".9" fill="currentColor" />
    </svg>
    <!-- a brain thinking too hard: it swells, pops in a burst, comes back -->
    <svg v-else-if="look.id === 'brain'" class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
      <g class="await-brain__head" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round">
        <path d="M8 3.4c-.9-1-2.8-.9-3.4.4-1.4.1-2.3 1.3-1.9 2.6-1 .8-1 2.4.1 3.1-.1 1.4 1 2.5 2.4 2.3.6 1 2.1 1.2 2.8.3.7.9 2.2.7 2.8-.3 1.4.2 2.5-.9 2.4-2.3 1.1-.7 1.1-2.3.1-3.1.4-1.3-.5-2.5-1.9-2.6-.6-1.3-2.5-1.4-3.4-.4z" />
        <path d="M8 3.4v8.9M5.4 6.3c.9.1 1.5.7 1.6 1.5M10.6 6.3c-.9.1-1.5.7-1.6 1.5M5.6 9.8c.7-.5 1.6-.4 2.1.2M10.4 9.8c-.7-.5-1.6-.4-2.1.2" stroke-width="1" />
      </g>
      <path class="await-brain__burst" d="M8 .3v1.6M8 14.1v1.6M.3 8h1.6M14.1 8h1.6M2.6 2.6l1.1 1.1M12.3 12.3l1.1 1.1M13.4 2.6l-1.1 1.1M3.7 12.3l-1.1 1.1" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" />
    </svg>
    <svg v-else class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
      <path d="M4 1.5h8M4 14.5h8M5 1.5c0 3 3 4.5 3 6.5S5 11.5 5 14.5M11 1.5c0 3-3 4.5-3 6.5s3 3.5 3 6.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
      <path d="M6.3 13.6 8 11.4l1.7 2.2z" fill="currentColor" />
    </svg>
  </span>
</template>

<script setup lang="ts">
import { ROTATE_AWAIT_ANIM, awaitAnimation } from '~/utils/await-reply.mjs'
import { useAwaitAnim, useAwaitRotate } from '~/composables/useAwaitAnim'

/* `anim` unset = the person's own pick; `preview` = the setting's sample */
const props = withDefaults(defineProps<{ state: 'spin' | 'wait', anim?: string, preview?: boolean }>(), { anim: '', preview: false })
const { pick } = useAwaitAnim()
/* the pick this mark draws: its own `anim`, else the person's */
const chosen = computed(() => props.anim || pick.value)
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

/* SPL-2043: `rotate` cycles only while spinning and motion is welcome */
const rotating = computed(() => chosen.value === ROTATE_AWAIT_ANIM && props.state === 'spin' && !reduced.value)
const drawing = useAwaitRotate(rotating)
const look = computed(() => awaitAnimation(chosen.value === ROTATE_AWAIT_ANIM ? drawing.value : chosen.value) as { id: string, kind: string, className?: string, src?: string, type?: string, poster?: string })
/* a clip plays only while spinning and motion is welcome; else the still glyph
   (or the clip's poster, a <video> that never starts) */
const clip = computed(() => {
  const l = look.value
  if (l.kind !== 'clip' || !l.src || props.state !== 'spin') return null
  const image = String(l.type || '').startsWith('image/')
  if (reduced.value && image) return l.poster ? { src: l.poster, image: true } : null
  return { src: l.src, image }
})
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
.await-reply__clip { inline-size: 16px; block-size: 16px; object-fit: contain; }
/* SPL-2027 (owner msg f7779032): 20% bigger than the first 14 px hourglass;
   SPL-2043 (msg 19feedf8): another 20% (16.8 -> 20.16 px). It spills over
   the 16 px box instead of growing it, so the row keeps its height */
.await-reply__glyph { inline-size: 20.16px; block-size: 20.16px; flex: none; overflow: visible; }
.await-brain__burst { opacity: 0; }

/* the default animation: the hourglass turns over, rests, turns again;
   only where motion is welcome, so reduced motion keeps it still */
@media (prefers-reduced-motion: no-preference) {
  .await-anim--hourglass.await-reply--spin .await-reply__glyph {
    animation: await-hourglass 1.8s ease-in-out infinite;
    transform-origin: 50% 50%;
  }
}
@media (prefers-reduced-motion: no-preference) {
  .await-anim--robot.await-reply--spin .await-reply__glyph { animation: await-robot 0.5s ease-in-out infinite; }
  .await-anim--robot.await-reply--spin .await-robot__limb {
    animation: await-robot-limb 0.5s ease-in-out infinite alternate;
    transform-box: view-box;
  }
  .await-anim--robot.await-reply--spin .await-robot__leg-a { transform-origin: 7px 11.4px; }
  .await-anim--robot.await-reply--spin .await-robot__leg-b { transform-origin: 9px 11.4px; animation-direction: alternate-reverse; }
  .await-anim--robot.await-reply--spin .await-robot__arm-a { transform-origin: 8px 8.6px; animation-direction: alternate-reverse; }
  .await-anim--robot.await-reply--spin .await-robot__arm-b { transform-origin: 8px 8.6px; }
  .await-anim--robot.await-reply--spin .await-robot__speed { animation: await-robot-speed 0.5s linear infinite; }
  .await-anim--brain.await-reply--spin .await-brain__head {
    animation: await-brain 2.4s ease-in infinite;
    transform-box: view-box;
    transform-origin: 8px 8px;
  }
  .await-anim--brain.await-reply--spin .await-brain__burst {
    animation: await-brain-burst 2.4s ease-out infinite;
    transform-box: view-box;
    transform-origin: 8px 8px;
  }
}
@keyframes await-robot {
  0%, 100% { transform: translateY(0); }
  50% { transform: translateY(-1px); }
}
@keyframes await-robot-limb {
  from { transform: rotate(-28deg); }
  to { transform: rotate(28deg); }
}
@keyframes await-robot-speed {
  0% { opacity: 0.9; transform: translateX(0); }
  100% { opacity: 0; transform: translateX(-2px); }
}
/* swell, swell harder, pop (gone), regrow */
@keyframes await-brain {
  0% { transform: scale(0.85); opacity: 1; }
  55% { transform: scale(1.1); opacity: 1; }
  68% { transform: scale(1.25); opacity: 1; }
  72% { transform: scale(1.4); opacity: 0; }
  84% { transform: scale(0.3); opacity: 0; }
  100% { transform: scale(0.85); opacity: 1; }
}
@keyframes await-brain-burst {
  0%, 68% { transform: scale(0.6); opacity: 0; }
  74% { transform: scale(1); opacity: 1; }
  86%, 100% { transform: scale(1.2); opacity: 0; }
}
@keyframes await-hourglass {
  0%, 35% { transform: rotate(0deg); }
  65%, 100% { transform: rotate(180deg); }
}
</style>
