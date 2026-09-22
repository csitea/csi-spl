<template>
  <article
    class="msg"
    :class="{ selected, 'msg--clickable': clickable }"
    tabindex="0"
    :data-msg-id="msg.msg_id || undefined"
    :data-ts="at || undefined"
    :data-task-id="msg.task_id || undefined"
    :data-selected="selected ? 'true' : undefined"
    :aria-current="selected ? 'true' : undefined"
    :aria-posinset="posinset || undefined"
    :aria-setsize="setsize || undefined"
    :aria-label="t('feed.card_aria', { who: (msg.from || t('feed.unknown_author')) + (msg.from_box ? '@' + msg.from_box : ''), kind: kindLabel(String(msg.kind || 'note')) })"
    :aria-describedby="clickable ? 'feed-open-hint' : undefined"
    @click="onClick"
    @keydown="onKey"
  >
    <SpoolAvatar class="avatar" :id="String(msg.from || '')" :box="msg.from_box ? String(msg.from_box) : ''" />
    <div>
      <div class="msg-meta">
        <AgentBadge :id="String(msg.from)" :box="msg.from_box ? String(msg.from_box) : undefined" />
        <KindBadge :kind="String(msg.kind)" />
        <span class="msg-time">{{ time }}</span>
      </div>
      <MessageBody :body="String(msg.body || '')" />
      <FileAttachment
        v-for="(f, i) in files"
        :key="String(f.file_id || f.path || i)"
        :file="f"
      />
      <button
        v-if="threadLink"
        class="icon-btn icon-btn--accent"
        type="button"
        data-test="open-thread"
        :aria-label="t('feed.open_thread')"
        :title="t('feed.open_thread')"
        @click="$emit('open-thread', msg)"
      >
        <UiIcon name="open" :size="16" />
      </button>
      <button
        v-if="count > 0 || alwaysThread"
        class="replies"
        type="button"
        @click="$emit('open-thread', msg)"
      >
        {{ t('feed.replies', { n: count }, count) }}
      </button>
    </div>
  </article>
</template>

<script setup lang="ts">
import { formatThreadTs, formatTs } from '~/utils/channel-feed.mjs'
import { activityOf } from '~/utils/feed.mjs'

import type { FileRef, SpoolMessage } from '~/types/spool'

const props = defineProps<{
  msg: SpoolMessage
  count?: number
  alwaysThread?: boolean
  posinset?: number
  setsize?: number
  threadLink?: boolean
  /** CLE-3427: the whole row opens its thread (pointer and keyboard). */
  clickable?: boolean
  /** the row the open thread is rooted at */
  selected?: boolean
  /** Date.now() at thread open (ticks while open): `yyyy-mm-dd HH:MM:SS sent <age>` */
  sinceMs?: number
}>()
const emit = defineEmits<{ 'open-thread': [msg: SpoolMessage] }>()

const { t, te, locale } = useI18n({ useScope: 'global' })
/** v:1 kind in words (feed.kind.*); an unknown kind shows as sent. */
const kindLabel = (k: string) => (te('feed.kind.' + k) ? t('feed.kind.' + k) : k)
/* CLE-3425: a thread card is ordered by its LAST activity, so it shows that
   moment — a card that sits above another must not print an older time. */
const at = computed(() => activityOf(props.msg))
const time = computed(() => (
  props.sinceMs != null
    ? formatThreadTs(at.value, props.sinceMs)
    : formatTs(at.value, locale.value)
))
const files = computed(() => (Array.isArray(props.msg.files) ? props.msg.files : []) as FileRef[])
const count = computed(() => props.count || 0)

/*
 * CLE-3427 — clicking the row opens its thread. The row already carried
 * tabindex="0" for the feed pattern, so the keyboard half is Enter / Space on
 * the focused row; the explicit "open thread" icon button stays as the
 * discoverable, screen-reader-named affordance.
 *
 * Two things a whole-row click must not eat: a click on something that is
 * itself interactive (a link in the body, the copy-code button, a file
 * attachment, the reply-count button — those handle themselves), and the
 * click that ENDS a text selection inside the message, which is how a reader
 * copies a line and never means "open the thread".
 */
const INTERACTIVE = 'a, button, input, textarea, select, label, summary, [role="button"], [contenteditable="true"]'

function selecting() {
  const sel = typeof window !== 'undefined' ? window.getSelection() : null
  return Boolean(sel && !sel.isCollapsed && String(sel).trim())
}

function onClick(ev: MouseEvent) {
  if (!props.clickable) return
  const el = ev.target as HTMLElement | null
  if (el && el.closest && el.closest(INTERACTIVE)) return
  if (selecting()) return
  emit('open-thread', props.msg)
}

function onKey(ev: KeyboardEvent) {
  if (!props.clickable) return
  if (ev.key !== 'Enter' && ev.key !== ' ' && ev.key !== 'Spacebar') return
  /* only the row itself: Enter inside a child control is that control's */
  if (ev.target !== ev.currentTarget) return
  ev.preventDefault()
  emit('open-thread', props.msg)
}
</script>
