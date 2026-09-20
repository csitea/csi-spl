<template>
  <article
    class="msg"
    tabindex="0"
    :data-msg-id="msg.msg_id || undefined"
    :aria-posinset="posinset || undefined"
    :aria-setsize="setsize || undefined"
    :aria-label="t('feed.card_aria', { who: (msg.from || t('feed.unknown_author')) + (msg.from_box ? '@' + msg.from_box : ''), kind: kindLabel(String(msg.kind || 'note')) })"
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
        @click="$emit('open-thread', String(msg.task_id))"
      >
        <UiIcon name="open" :size="16" />
      </button>
      <button
        v-if="count > 0 || alwaysThread"
        class="replies"
        type="button"
        @click="$emit('open-thread', String(msg.task_id))"
      >
        {{ t('feed.replies', { n: count }, count) }}
      </button>
    </div>
  </article>
</template>

<script setup lang="ts">
import { formatTs } from '~/utils/channel-feed.mjs'

import type { FileRef, SpoolMessage } from '~/types/spool'

const props = defineProps<{
  msg: SpoolMessage
  count?: number
  alwaysThread?: boolean
  posinset?: number
  setsize?: number
  threadLink?: boolean
}>()
defineEmits<{ 'open-thread': [taskId: string] }>()

const { t, te, locale } = useI18n({ useScope: 'global' })
/** v:1 kind in words (feed.kind.*); an unknown kind shows as sent. */
const kindLabel = (k: string) => (te('feed.kind.' + k) ? t('feed.kind.' + k) : k)
const time = computed(() => formatTs(String(props.msg.ts || ''), locale.value))
const files = computed(() => (Array.isArray(props.msg.files) ? props.msg.files : []) as FileRef[])
const count = computed(() => props.count || 0)
</script>
