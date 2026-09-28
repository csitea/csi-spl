<!-- SPL-941: the middle pane's header, one component for the
     channel, DM and lobby pages. The title is what you are reading; a DM or
     the lobby puts its presence / connection dot in front and the words in
     the dot's tooltip; the card height control sits at the right edge. The
     pane label ("Msgs") names the header for screen readers only. Owner
     2026-09-26: no "last 30 · tenant-scoped" note and no channel description
     here (the description lives in channel Properties). -->
<template>
  <header class="feed-header feed-header--pane" data-test="feed-header" :aria-label="t('pane.msgs')">
    <MobileBack />
    <span
      v-if="status"
      class="dot"
      :class="{ on: status === 'on' }"
      :title="statusText"
      data-test="feed-header-status"
    />
    <h2 class="feed-header__title" :title="titleTip || title">{{ title }}</h2>
    <span v-if="statusText" class="sr-only">{{ statusText }}</span>
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
}>()
const { t } = useI18n({ useScope: 'global' })
</script>
