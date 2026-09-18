<template>
  <div class="file-card">
    <div>
      <div>{{ file.name }}</div>
      <small>{{ size }} · sha256 {{ shortHash }}</small>
    </div>
    <a class="btn ghost" :href="href" :download="file.name">Download</a>
  </div>
</template>

<script setup lang="ts">
import { formatBytes } from '~/utils/channel-feed.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'

const props = defineProps<{
  file: { file_id: string, name: string, bytes: number, sha256: string }
}>()

const api = useSpoolApi()
const size = computed(() => formatBytes(props.file.bytes))
const shortHash = computed(() => String(props.file.sha256 || props.file.file_id).slice(0, 12))
const href = computed(() => api.fileUrl(props.file.file_id || props.file.sha256))
</script>
