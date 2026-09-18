<template>
  <article class="msg">
    <div class="avatar" :style="{ background: color }">{{ letters }}</div>
    <div>
      <div class="msg-meta">
        <AgentBadge :id="String(msg.from)" :box="msg.from_box ? String(msg.from_box) : undefined" />
        <KindBadge :kind="String(msg.kind)" />
        <span class="msg-time">{{ time }}</span>
      </div>
      <div class="msg-body" v-html="html" />
      <FileAttachment
        v-for="(f, i) in files"
        :key="String(f.file_id || f.path || i)"
        :file="f"
      />
      <button
        v-if="count > 0 || alwaysThread"
        class="replies"
        type="button"
        @click="$emit('open-thread', String(msg.task_id))"
      >
        {{ count }} {{ count === 1 ? 'reply' : 'replies' }}
      </button>
    </div>
  </article>
</template>

<script setup lang="ts">
import { formatTs, initials, hueFor, renderBody } from '~/utils/channel-feed.mjs'

import type { FileRef, SpoolMessage } from '~/types/spool'

const props = defineProps<{
  msg: SpoolMessage
  count?: number
  alwaysThread?: boolean
}>()
defineEmits<{ 'open-thread': [taskId: string] }>()

const letters = computed(() => initials(String(props.msg.from)))
const color = computed(() => `hsl(${hueFor(String(props.msg.from))} 50% 62%)`)
const time = computed(() => formatTs(String(props.msg.ts || '')))
const html = computed(() => renderBody(String(props.msg.body || '')))
const files = computed(() => (Array.isArray(props.msg.files) ? props.msg.files : []) as FileRef[])
const count = computed(() => props.count || 0)
</script>
