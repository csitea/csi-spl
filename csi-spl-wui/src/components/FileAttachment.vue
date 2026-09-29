<template>
  <button
    v-if="iconOnly"
    type="button"
    class="file-icon"
    data-testid="card-title-file"
    :title="file.name"
    :aria-label="file.name"
    @click.stop="onIcon"
  >
    <UiIcon :name="kind.icon" size="1em" />
  </button>
  <div v-else class="file-card">
    <button
      v-if="previewUrl"
      type="button"
      class="file-preview"
      data-test="file-preview"
      :aria-label="file.name"
      @click="viewerOpen = true"
    ><img :src="previewUrl" :alt="file.name"></button>
    <span v-else class="file-kind" :data-kind="kind.kind" data-test="file-kind">
      <UiIcon :name="kind.icon" :size="28" />
      <span v-if="kind.ext" class="file-kind__ext">{{ kind.ext }}</span>
    </span>
    <div class="file-card__meta">
      <div>{{ file.name }}</div>
      <small>{{ t('feed.file_meta', { size, hash: shortHash }) }}</small>
    </div>
    <a v-if="linkable" class="btn ghost" :href="href" :download="file.name" @click.prevent="onDownload">{{ label }}</a>
    <small v-else :title="file.path">{{ t('feed.on_box_path', { path: file.path }) }}</small>
  </div>
  <UiDialog v-if="previewUrl" v-model:open="viewerOpen" :title="file.name" size="xl">
    <div class="file-viewer" data-test="file-viewer">
      <img :src="previewUrl" :alt="file.name">
    </div>
  </UiDialog>
</template>

<script setup lang="ts">
import { formatBytes } from '~/utils/channel-feed.mjs'
import { isDownloadable } from '~/utils/view-api.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { sha256Hex } from '~/utils/spool-client.mjs'
import { fileKind, isPreviewableImage, previewImageMime, sharedPreview } from '~/utils/file-preview.mjs'
import { bytesToDataUri } from '~/utils/avatar.mjs'
import type { FileRef } from '~/types/spool'

const props = withDefaults(defineProps<{ file: FileRef, iconOnly?: boolean }>(), { iconOnly: false })

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
 * A picture shows inline, and a click opens it at 90% of the screen. The
 * bytes come through the same credentialed door as Download and must match
 * the sha256 the message names. It is a data: URL, not a blob: one: every
 * deployed CSP is img-src 'self' data:. The magic bytes pick the
 * type, so a file NAMED .png that is not a picture shows nothing. A failed
 * fetch leaves the card as it was: name and Download.
 */
const previewUrl = ref('')
const kind = computed(() => fileKind(props.file.name))
const viewerOpen = ref(false)
/* Watched, not onMounted: an optimistic row can hold the picked File itself
   until the upload answers, and then the SAME card is handed the ref. */
let loadSerial = 0
async function loadPreview() {
  const serial = ++loadSerial
  const f = props.file as unknown
  let url = ''
  try {
    if (typeof Blob !== 'undefined' && f instanceof Blob) {
      if (isPreviewableImage((f as File).name, f.size)) {
        const buf = await f.arrayBuffer()
        const type = previewImageMime(buf)
        if (type) url = bytesToDataUri(buf, type)
      }
    } else if (linkable.value && isPreviewableImage(props.file.name, props.file.bytes)) {
      const id = String(props.file.file_id || props.file.sha256 || '')
      const want = String(props.file.sha256 || props.file.file_id || '')
      /* one verified download per file for the page, shared by every card */
      url = await sharedPreview(want ? id + '\n' + want : '', async () => {
        const buf = await api.downloadFile(id)
        if (want && (await sha256Hex(buf)) !== want) return ''
        const type = previewImageMime(buf)
        return type ? bytesToDataUri(buf, type) : ''
      })
    }
  } catch { /* no preview; Download still offers the file */ }
  if (serial !== loadSerial) return
  if (url || !previewUrl.value) previewUrl.value = url
}
onMounted(() => {
  /* SPL-1223: the icon-only glyph (a title-row / clipped card) never shows the
     inline preview - it renders a UiIcon and fetches the image only when the
     reader clicks (onIcon). Prefetching it on mount downloaded, sha256-verified
     and base64-encoded every image attachment just to draw a glyph, so a feed
     of image messages in "titles" clip mode fetched them all. Leave that to the
     click. A picked-Blob optimistic row is never icon-only, so nothing regresses. */
  if (props.iconOnly) return
  watch(() => [props.file, props.file.file_id, props.file.sha256], loadPreview, { immediate: true })
})

/**
 * Cross-origin <a download> is ignored by browsers, so fetch the bytes, check
 * sha256 against the message (the box CLI refuses a mismatch too), then save.
 */
async function onIcon() {
  if (isPreviewableImage(props.file.name, props.file.bytes)) {
    if (!previewUrl.value) await loadPreview()
    if (previewUrl.value) {
      viewerOpen.value = true
      return
    }
  }
  if (linkable.value) await onDownload()
}

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

<style scoped>
.file-icon {
  display: inline-flex;
  flex: none;
  align-items: center;
  padding: 0;
  border: 0;
  background: none;
  color: var(--color-muted);
  cursor: pointer;
  line-height: 1;
}
.file-icon:focus-visible {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: var(--focus-offset);
}
.file-kind {
  display: inline-flex;
  flex-direction: column;
  align-items: center;
  gap: 2px;
  flex: none;
  color: var(--color-muted);
}
.file-kind[data-kind="pdf"] { color: #d93025; }
.file-kind[data-kind="doc"] { color: #2b6cd4; }
.file-kind[data-kind="sheet"] { color: #1e8e3e; }
.file-kind[data-kind="slides"] { color: #e8710a; }
.file-kind__ext {
  font-family: var(--font-mono);
  font-size: 0.625rem;
  line-height: 1;
  text-transform: uppercase;
}
.file-card__meta {
  flex: 1 1 auto;
  min-width: 0;
}
.file-preview {
  flex-basis: 100%;
  display: block;
  padding: 0;
  border: 0;
  background: none;
  cursor: zoom-in;
  text-align: left;
}
/* A frame at least 64px square on a checkerboard, so a tiny or transparent
   picture still reads as a picture (a 1x1 png drew nothing at all). */
.file-preview img {
  display: block;
  min-width: 64px;
  min-height: 64px;
  max-width: min(100%, 360px);
  max-height: 240px;
  object-fit: contain;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: repeating-conic-gradient(var(--color-bg-2) 0 25%, var(--color-surface) 0 50%) 0 0 / 16px 16px;
}
/* the picture at its own size, or shrunk to fit the 90% box; never grown */
.file-viewer {
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 8px;
}
.file-viewer img {
  max-width: 100%;
  max-height: 100%;
  object-fit: contain;
}
/* SPL-991 phone: the download button and the title-row file glyph are
   44 px targets; a picture preview never overflows the full-width card */
@media (max-width: 820px) {
  .file-card .btn { min-height: var(--tap); }
  .file-icon { min-width: var(--tap); min-height: var(--tap); justify-content: center; margin-block: -12px; }
  .file-preview img { max-width: 100%; }
}
</style>
