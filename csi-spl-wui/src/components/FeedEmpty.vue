<!-- SPL-2141 (owner HUM-10, t1 1061f05f msg 4d63f24c, suggestion 2): a channel
     with no messages showed one small grey line, read as a blank pane. This
     says whose start it is, invites the first post and puts the caret in the
     Omnibox, wherever it is docked; a filter with no match says how to undo it.

     Lazy (LazyFeedEmpty) and on demand: its strings wait in the second
     catalogue (utils/i18n-first-screen.mjs); until they are merged it says the
     core "No messages yet." / "No messages match.", so first paint is
     unchanged. role=status: a screen reader reads it once when it appears.
     CSP: classes only, no :style. -->
<template>
  <div class="feed-empty" role="status" data-testid="feed-empty" :data-search="search ? 'true' : undefined">
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
defineProps<{ channel: string, search?: string }>()
const { t, te } = useI18n({ useScope: 'global' })
/* the second catalogue holds the friendly copy; until it is merged the core line shows */
const ready = computed(() => te('feed.first_post.title'))

/* the Omnibox is this channel's composer (top bar or docked at the bottom) */
function focusComposer() {
  document.querySelector<HTMLTextAreaElement>('form.omnibox--global textarea')?.focus()
}
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
.feed-empty__title { margin: 0; color: var(--color-fg); font-size: 1rem; font-weight: 600; overflow-wrap: anywhere; }
.feed-empty__hint { margin: 0; color: var(--color-muted); font-size: 0.875rem; }
.feed-empty__start { display: inline-flex; align-items: center; gap: 6px; margin-top: 8px; }
</style>
