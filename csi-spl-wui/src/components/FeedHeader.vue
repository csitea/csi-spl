<!-- SPL-941: the middle pane's header, one component for the
     channel, DM and lobby pages. The title is what you are reading; a DM or
     the lobby puts its presence / connection dot in front and the words in
     the dot's tooltip; the card height control sits at the right edge. The
     pane label ("Msgs") names the header for screen readers only.
     CLE-77862 (HUM-24): a DM also prints the words beside the name
     (status-shown) - "isn't this green dot MY status?" - so the peer's
     presence reads as the peer's without hovering. Owner
     2026-09-26: no "last 30 · tenant-scoped" note and no channel description
     here (the description lives in channel Properties).
     t1 404cd808 (owner: "it must be a clear indication in this view if
     somethign is archived"): a DM opened on an ARCHIVED topic (?topic=)
     names that topic here, muted, beside the same ArchivedBadge the topic
     pane and the Topics rows carry; a live topic adds nothing.
     Spec 150 B6: the topic list's filter and sort; lazy, in a slot that
     holds its box from the first frame, so the shell's initial chunk does
     not grow and nothing jumps.
     SPL-5349 (owner HUM-10, t1 2fafde5c, option A): two rows - the full
     channel name on row 1 (it wraps, never cut); row 2 holds the filter and
     sort at the left and the card height control at the right.
     Spec 186 4.1 step 1 items 4-5 (row M3): on a channel's or the lobby's
     topic list, while topics are ticked the selection bar
     (TopicSelectBar.vue, lazy) takes this header's place; while none is,
     row 2 offers Select by title, so a selection can start from a pattern.
     A DM page has neither (Q8 CHN). -->
<template>
  <LazyTopicSelectBar v-if="selectOn && topicSelect.active" :phone="phone" />
  <header v-else class="feed-header feed-header--pane" data-test="feed-header" :aria-label="t('pane.msgs')">
    <MobileBack />
    <span
      v-if="status"
      class="dot"
      :class="[{ on: status === 'on' }, ring ? 'dot--' + ring : '']"
      :title="statusText"
      :data-status="ring || undefined"
      data-test="feed-header-status"
    />
    <div class="feed-header__who" :class="{ 'feed-header__who--status': statusText && statusShown }">
      <h2 class="feed-header__title" :title="titleTip || title">{{ title }}</h2>
      <span v-if="statusText && statusShown" class="feed-header__status" data-test="feed-header-status-text">{{ statusText }}</span>
      <span v-else-if="statusText" class="sr-only">{{ statusText }}</span>
    </div>
    <span
      v-if="archivedAt"
      class="feed-header__topic is-archived"
      data-test="feed-header-archived"
      :title="topicTitle || undefined"
    >
      <span v-if="topicTitle" class="feed-header__topic-title">{{ topicTitle }}</span>
      <ArchivedBadge :at="archivedAt" :task-id="topicId" @unarchived="emit('unarchived')" />
    </span>
    <div class="feed-header__row2" data-test="feed-header-row2">
      <span class="topic-list-slot"><LazyTopicListControl /></span>
      <button
        v-if="selectOn"
        type="button"
        class="icon-btn feed-header__select"
        data-test="topic-select-by-title"
        :aria-expanded="patternsOpen ? 'true' : 'false'"
        :aria-label="t('topic_select.by_title')"
        :title="t('topic_select.by_title')"
        @click="patternsOpen = !patternsOpen"
      >
        <UiIcon name="check" :size="16" />
      </button>
      <CardClipControl />
    </div>
    <div v-if="selectOn && patternsOpen" class="feed-header__patterns">
      <LazyTopicSelectPatterns @close="patternsOpen = false" @added="patternsOpen = false" />
    </div>
  </header>
</template>

<script setup lang="ts">
import { useTopicSelectStore } from '~/stores/topicSelect'
import { useMobileStack } from '~/composables/useMobileStack'

defineProps<{
  title: string
  /** hover text for the title (a DM shows id@box behind the display name) */
  titleTip?: string
  /** presence / connection dot; omitted = no dot (a string, not a
      boolean: Vue casts an absent boolean prop to false) */
  status?: 'on' | 'off'
  statusText?: string
  /** spec 096: a DM peer's manual status - the ring around the dot */
  ring?: '' | 'busy' | 'unavailable'
  /** print statusText beside the title (DM: the peer's presence); omitted =
      the words stay in the dot's tooltip and for screen readers (lobby) */
  statusShown?: boolean
  /** the open topic's archive stamp ('' or omitted = live: nothing shown) */
  archivedAt?: string
  /** the open topic's title, shown muted beside the badge when archived */
  topicTitle?: string
  /** SPL-1763: the open topic's task, so the badge may unarchive it */
  topicId?: string
}>()
/* SPL-1763: the badge unarchived the topic; the page drops its mark */
const emit = defineEmits<{ unarchived: [] }>()
const { t } = useI18n({ useScope: 'global' })
/* spec 186 (row M3): a channel's or the lobby's topic list carries the select phase */
const route = useRoute()
const selectOn = computed(() => /\/(?:channel\/[^/]+|lobby)\/?$/.test(route.path))
const topicSelect = useTopicSelectStore()
const phone = useMobileStack().isMobile
const patternsOpen = ref(false)
</script>

<style scoped>
/* SPL-5349: row 2 under the full name (main.css: .feed-header--pane) */
.feed-header__row2 {
  display: flex;
  flex: 0 0 100%;
  align-items: center;
  gap: 8px;
  min-width: 0;
}
/* spec 150 B6: the slot holds the two buttons' box (TopicListControl.vue:
   26 x 18 px each, 35 x 32 on a phone, 2 px apart); the card height
   control takes the right edge */
.topic-list-slot {
  display: inline-flex;
  flex-shrink: 0;
  min-width: calc(2 * 26px + 2px);
  min-height: 18px;
}
@media (max-width: 820px) {
  .feed-header__row2 { min-height: var(--tap); }
  .topic-list-slot {
    min-width: calc(2 * 35px + 2px);
    min-height: 32px;
  }
}
/* spec 186: Select by title sits after the filter and sort; its field opens under row 2 */
.feed-header__select { flex-shrink: 0; }
.feed-header__patterns { flex: 0 0 100%; min-width: 0; }
/* gives way (ellipsis) before the name does; the badge never shrinks */
.feed-header__topic {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  flex: 0 2 auto;
  min-width: 0;
  font-size: 0.8125rem;
}
.feed-header__topic-title {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
</style>
