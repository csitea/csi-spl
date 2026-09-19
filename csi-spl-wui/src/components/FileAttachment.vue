<template>
  <div class="file-card">
    <div>
      <div>{{ file.name }}</div>
      <small>{{ t('feed.file_meta', { size, hash: shortHash }) }}</small>
    </div>
    <a v-if="linkable" class="btn ghost" :href="href" :download="file.name" @click.prevent="onDownload">{{ label }}</a>
    <small v-else :title="file.path">{{ t('feed.on_box_path', { path: file.path }) }}</small>
  </div>
</template>

<script setup lang="ts">
import { formatBytes } from '~/utils/channel-feed.mjs'
import { isDownloadable } from '~/utils/view-api.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { sha256Hex } from '~/utils/spool-client.mjs'
import type { FileRef } from '~/types/spool'

const props = defineProps<{ file: FileRef }>()

const api = useSpoolApi()
const { t, locale } = useI18n({ useScope: 'global' })
const size = computed(() => formatBytes(props.file.bytes, locale.value))
const shortHash = computed(() => String(props.file.sha256 || props.file.file_id || '').slice(0, 12))
/* spec 005 US3: only mode "blob" has bytes on the hub; mode "path" never left the box */
const linkable = computed(() => isDownloadable(props.file))
const href = computed(() => api.fileUrl(props.file.file_id || props.file.sha256 || ''))
/** Download button state; the label is its translation (feed.download.*). */
const status = ref<'idle' | 'busy' | 'mismatch' | 'done' | 'failed'>('idle')
const label = computed(() => t('feed.download.' + status.value))

/**
 * Cross-origin <a download> is ignored by browsers, so fetch the bytes, check
 * sha256 against the message (the box CLI refuses a mismatch too), then save.
 */
async function onDownload() {
  status.value = 'busy'
  try {
    const buf = await api.downloadFile(props.file.file_id || props.file.sha256 || '')
    const got = await sha256Hex(buf)
    const want = String(props.file.sha256 || props.file.file_id || '')
    if (want && got !== want) {
      status.value = 'mismatch'
      return
    }
    const url = URL.createObjectURL(new Blob([buf]))
    const a = document.createElement('a')
    a.href = url
    a.download = props.file.name || want
    document.body.appendChild(a)
    a.click()
    a.remove()
    setTimeout(() => URL.revokeObjectURL(url), 10000)
    status.value = 'done'
  } catch {
    status.value = 'failed'
  }
}
</script>
