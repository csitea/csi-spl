<!-- SPL-1994 (owner HUM-10, t1 72898ea2 msg def4a52d): the hub has a
     person's post and no agent has answered it yet. `spin` = the animation
     runs; `wait` (no agent in the topic, or none within the cnf minutes) = a
     calm, still glyph. The state comes from utils/await-reply.mjs.

     The animation is ONE swappable piece (owner msgs ad9882d2, 0f442e7c):
     `anim` names an entry of AWAIT_ANIMATIONS - a CSS animation (its class,
     keyframes below) or a looping clip (animated WebP as a lazy <img>, or a
     muted <video>, no autoplay under prefers-reduced-motion). A later lane
     adds entries there and passes the person's choice as `anim`.

     Lazy (LazyAwaitReply) and on demand: its strings wait in the second
     catalogue (utils/i18n-first-screen.mjs) and it renders nothing until
     they are merged. CSP: classes only, no :style. -->
<template>
  <span
    v-if="ready"
    class="await-reply"
    :class="[`await-reply--${state}`, `await-anim--${look.id}`, look.kind === 'css' ? look.className : 'await-anim--clip']"
    role="status"
    data-test="await-reply"
    :data-state="state"
    :data-anim="look.id"
    :aria-label="label"
    :title="label"
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
    <svg v-else class="await-reply__glyph" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false">
      <path d="M4 1.5h8M4 14.5h8M5 1.5c0 3 3 4.5 3 6.5S5 11.5 5 14.5M11 1.5c0 3-3 4.5-3 6.5s3 3.5 3 6.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
      <path d="M6.3 13.6 8 11.4l1.7 2.2z" fill="currentColor" />
    </svg>
  </span>
</template>

<script setup lang="ts">
import { awaitAnimation, DEFAULT_AWAIT_ANIM } from '~/utils/await-reply.mjs'

const props = withDefaults(defineProps<{ state: 'spin' | 'wait', anim?: string }>(), { anim: DEFAULT_AWAIT_ANIM })
const { t, te } = useI18n({ useScope: 'global' })
/* the second catalogue holds the label; until it is merged nothing shows */
const ready = computed(() => te('await_reply.spin'))
const label = computed(() => t(props.state === 'spin' ? 'await_reply.spin' : 'await_reply.wait'))
const look = computed(() => awaitAnimation(props.anim) as { id: string, kind: string, className?: string, src?: string, type?: string, poster?: string })

const reduced = ref(false)
onMounted(() => {
  reduced.value = Boolean(window.matchMedia?.('(prefers-reduced-motion: reduce)').matches)
})
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

/* the default animation: the hourglass turns over, rests, turns again;
   only where motion is welcome, so reduced motion keeps it still */
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
