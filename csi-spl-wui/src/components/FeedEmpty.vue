<!-- SPL-2141 (owner HUM-10, t1 1061f05f msg 4d63f24c, suggestion 2): a channel
     with no messages showed one small grey line, read as a blank pane. This
     says whose start it is, invites the first post and puts the caret in the
     Omnibox, wherever it is docked; a filter with no match says how to undo it.

     Lazy (LazyFeedEmpty) and on demand: its strings wait in the second
     catalogue (utils/i18n-first-screen.mjs); until they are merged it says the
     core "No messages yet." / "No messages match.", so first paint is
     unchanged. role=status: a screen reader reads it once when it appears.
     CSP: classes only, no :style.

     SPL-2793 (row 06 of ui-animations-panel-plan.md): a small robot mascot
     waves once when the empty feed mounts, then rests; no loop. Inline SVG
     (the package ships no image files), decorative, so aria-hidden. The wave
     is tap-anim--greeting from playTapAnim: transform only, 800 ms, nothing
     under reduced motion. Its box has a fixed size, so nothing moves. -->
<template>
  <div class="feed-empty" role="status" data-testid="feed-empty" :data-search="search ? 'true' : undefined">
    <span ref="mascot" class="feed-empty__mascot" data-testid="feed-empty-mascot" aria-hidden="true">
      <svg viewBox="0 0 48 48" width="48" height="48" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" focusable="false">
        <path d="M24 6v6" />
        <circle cx="24" cy="5" r="2" fill="currentColor" />
        <rect x="10" y="12" width="28" height="22" rx="7" />
        <circle cx="19" cy="23" r="2.5" fill="currentColor" stroke="none" />
        <circle cx="29" cy="23" r="2.5" fill="currentColor" stroke="none" />
        <path d="M20 29c2.4 1.6 5.6 1.6 8 0" />
        <path d="M6 21v6M42 21v6" />
        <path d="M17 34v6h14v-6" />
      </svg>
    </span>
    <template v-if="ready">
      <p class="feed-empty__title">{{ search ? t('feed.no_matches') : t('feed.first_post.title', { channel: '#' + channel }) }}</p>
      <p class="feed-empty__hint">{{ search ? t('feed.first_post.filter_hint') : t('feed.first_post.hint') }}</p>
      <button v-if="!search" type="button" class="btn feed-empty__start" data-testid="feed-empty-start" @click="focusComposer">
        <UiIcon name="messages" :size="16" /><span>{{ t('feed.first_post.start') }}</span>
      </button>
    </template>
    <p v-else class="muted">{{ search ? t('feed.no_matches') : t('feed.empty') }}</p>
  </div>
</template>

<script setup lang="ts">
import { playTapAnim } from '~/composables/useTapAnim'

defineProps<{ channel: string, search?: string }>()
const { t, te } = useI18n({ useScope: 'global' })
/* the second catalogue holds the friendly copy; until it is merged the core line shows */
const ready = computed(() => te('feed.first_post.title'))

/* the Omnibox is this channel's composer (top bar or docked at the bottom) */
function focusComposer() {
  document.querySelector<HTMLTextAreaElement>('form.omnibox--global textarea')?.focus()
}

/* one greeting per mount; animationend takes the classes off, so it rests */
const mascot = ref<HTMLElement | null>(null)
onMounted(() => { if (mascot.value) playTapAnim(mascot.value, 'greeting') })
</script>

<style scoped>
.feed-empty {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 8px;
  margin: 48px auto;
  padding: 0 16px;
  max-width: 28rem;
  text-align: center;
}
.feed-empty__mascot { display: block; width: 48px; height: 48px; color: var(--color-accent); }
/* the wave pivots on the robot's feet, not its middle */
.feed-empty__mascot svg { display: block; transform-origin: 50% 90%; }
.feed-empty__title { margin: 0; color: var(--color-fg); font-size: 1rem; font-weight: 600; overflow-wrap: anywhere; }
.feed-empty__hint { margin: 0; color: var(--color-muted); font-size: 0.875rem; }
.feed-empty__start { display: inline-flex; align-items: center; gap: 6px; margin-top: 8px; }
</style>
