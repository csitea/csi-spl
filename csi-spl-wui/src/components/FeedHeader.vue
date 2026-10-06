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
     pane and the Topics rows carry; a live topic adds nothing. -->
<template>
  <header class="feed-header feed-header--pane" data-test="feed-header" :aria-label="t('pane.msgs')">
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
      <ArchivedBadge :at="archivedAt" />
    </span>
    <CardClipControl />
  </header>
</template>

<script setup lang="ts">
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
}>()
const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
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
