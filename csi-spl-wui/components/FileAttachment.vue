<template>
  <div class="file-card">
    <div>
      <div>{{ file.name }}</div>
      <small>{{ size }} · sha256 {{ shortHash }}</small>
    </div>
    <a v-if="linkable" class="btn ghost" :href="href" :download="file.name">Download</a>
    <small v-else :title="file.path">on-box path · {{ file.path }}</small>
  </div>
</template>

<script setup lang="ts">
import { formatBytes } from '~/utils/channel-feed.mjs'
import { isDownloadable } from '~/utils/view-api.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import type { FileRef } from '~/types/spool'

const props = defineProps<{ file: FileRef }>()

const api = useSpoolApi()
const size = computed(() => formatBytes(props.file.bytes))
const shortHash = computed(() => String(props.file.sha256 || props.file.file_id || '').slice(0, 12))
/* spec 005 US3: only mode "blob" has bytes on the hub; mode "path" never left the box */
const linkable = computed(() => isDownloadable(props.file))
const href = computed(() => api.fileUrl(props.file.file_id || props.file.sha256 || ''))
</script>
