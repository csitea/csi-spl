<!-- The customer's draft hand-over (spec 090 T036, SPL-4804; spec.md
     section 17, HUM-23: "I will post it myself, I have to pick the photos").
     Opened per post from MarketingPublish.vue ("Post by hand"), loaded lazily
     (its own chunk, budget ci_marketing_handover_*_kb in perf-budgets.json).
     It reads the hub's GET /v1/marketing/posts/{id}/share-links (T037) and
     shows: the platform badges; the post's photos with checkboxes (1 to 10)
     and one Download (one photo directly, more as one ZIP built in the
     browser, utils/marketing-handover.mjs); the caption plus the author's
     hashtags with a 1-click copy and a toast; Viber's short version (headline
     and link, <= 200 characters); the launch buttons for Instagram, Facebook,
     WhatsApp and Viber; and, for a connected account, "Mark as posted by
     hand" (POST /v1/marketing/posts/{id}/manual-publish?channel=<id>), which
     records it published with platform_post_id 'manual'. Nothing is posted
     for the member. -->
<template>
  <section class="mdh" data-test="marketing-draft-handover" :data-post="post.id" :data-pack="lastPack.join(',')">
    <h5 class="mdh-title">{{ t('tenant_settings.marketing_handover_title') }}</h5>
    <small class="muted">{{ t('tenant_settings.marketing_handover_hint') }}</small>
    <ul class="mdh-badges" :aria-label="t('tenant_settings.marketing_handover_badges_label')">
      <li v-for="b in BADGES" :key="b.id" class="mdh-badge" :class="`mdh-badge--${b.id}`" data-test="handover-badge" :data-platform="b.id">{{ b.name }}</li>
    </ul>
    <p v-if="loadError" class="mdh-error" role="alert" data-test="handover-load-failed">{{ t('tenant_settings.marketing_handover_load_failed') }}</p>
    <template v-else-if="links">
      <h6 class="mdh-sub" data-test="handover-photo-count" :data-count="picked.length">{{ t('tenant_settings.marketing_handover_photos', { count: picked.length, max: HANDOVER_MAX_PHOTOS }) }}</h6>
      <p v-if="!images.length" class="muted mdh-line">{{ t('tenant_settings.marketing_handover_photos_empty') }}</p>
      <ul v-else class="mdh-photos">
        <li v-for="(u, i) in images" :key="u" class="mdh-photo" data-test="handover-photo" :data-url="u">
          <label class="mdh-photo-label">
            <input v-model="checked[u]" type="checkbox" data-test="handover-photo-check" :disabled="!checked[u] && picked.length >= HANDOVER_MAX_PHOTOS">
            <img class="mdh-pic" :src="u" :alt="t('tenant_settings.marketing_handover_photo_alt', { n: i + 1, title: post.title || post.id })" loading="lazy">
          </label>
        </li>
      </ul>
      <div class="mdh-actions">
        <button type="button" class="btn" :disabled="!picked.length || packing" data-test="handover-download" @click="download()">{{ t('tenant_settings.marketing_handover_download') }}</button>
      </div>
      <label class="mdh-field">
        <span>{{ t('tenant_settings.marketing_handover_hashtags_label') }}</span>
        <input v-model="hashtags" type="text" class="mdh-input" :placeholder="t('tenant_settings.marketing_handover_hashtags_placeholder')" data-test="handover-hashtags">
      </label>
      <pre class="mdh-caption" data-test="handover-caption">{{ copyText }}</pre>
      <div class="mdh-actions">
        <button type="button" class="btn" data-test="handover-copy" @click="copy()">{{ t('tenant_settings.marketing_handover_copy') }}</button>
      </div>
      <h6 class="mdh-sub" data-test="handover-viber-count" :data-count="viberCount">{{ t('tenant_settings.marketing_handover_viber_title', { count: viberCount, max: VIBER_MAX_TEXT }) }}</h6>
      <p class="mdh-viber" data-test="handover-viber-text">{{ viberShort }}</p>
      <small class="muted">{{ t('tenant_settings.marketing_handover_instagram_note') }}</small>
      <div class="mdh-actions mdh-open">
        <a v-for="o in opens" :key="o.app" class="btn ghost" :href="o.href" target="_blank" rel="noopener noreferrer" data-test="handover-open" :data-app="o.app">{{ t(o.label) }}</a>
      </div>
      <div v-if="markChannel" class="mdh-actions">
        <button type="button" class="btn" :disabled="marking || marked" data-test="handover-mark-posted" @click="mark()">{{ t('tenant_settings.marketing_handover_mark') }}</button>
      </div>
    </template>
    <p v-if="toast" class="mdh-toast" role="status" data-test="handover-toast">{{ toast }}</p>
    <p v-if="error" class="mdh-error" role="alert" data-test="handover-error">{{ error }}</p>
  </section>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { writeClipboard } from '~/utils/clipboard.mjs'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'
import { VIBER_MAX_TEXT, viberText } from '~/utils/marketing-share-links.mjs'
import { HANDOVER_MAX_PHOTOS, handoverCopyText, handoverDownloadPlan, handoverFileName, handoverPicked, handoverSameOrigin, handoverZip } from '~/utils/marketing-handover.mjs'

type Post = { id: string, title?: string, summary?: string, image?: string }
type Links = { url?: string, facebook?: string, viber?: string, whatsapp?: string, instagram?: { caption?: string, images?: string[], open?: string } }

const props = defineProps<{ post: Post, channel?: string }>()
const emit = defineEmits<{ (e: 'handed-over', id: string): void }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

// brand names: not translated (i18n-keep-english.json lists them)
const BADGES = [
  { id: 'facebook', name: 'Facebook' }, { id: 'instagram', name: 'Instagram' }, { id: 'linkedin', name: 'LinkedIn' },
  { id: 'viber', name: 'Viber' }, { id: 'whatsapp', name: 'WhatsApp' },
]

const links = ref<Links | null>(null)
const loadError = ref(false)
const checked = reactive<Record<string, boolean>>({})
const hashtags = ref('')
const toast = ref('')
const error = ref('')
const packing = ref(false)
const marking = ref(false)
const marked = ref(false)
const lastPack = ref<string[]>([])
const markChannel = ref(props.channel || '')
let toastTimer: ReturnType<typeof setTimeout> | undefined

// the hub's photos are apex URLs: this host's own /blog/img/ path (its CSP is img-src 'self')
const images = computed(() => (links.value?.instagram?.images || []).slice(0, 20).map((u) => handoverSameOrigin(u)))
const picked = computed(() => handoverPicked(images.value, checked))
const copyText = computed(() => handoverCopyText(links.value?.instagram?.caption || '', hashtags.value))
const viberShort = computed(() => viberText(props.post.title || '', links.value?.url || ''))
const viberCount = computed(() => Array.from(viberShort.value).length)
const opens = computed(() => [
  { app: 'instagram', href: links.value?.instagram?.open || '', label: 'tenant_settings.marketing_handover_open_instagram' },
  { app: 'facebook', href: links.value?.facebook || '', label: 'tenant_settings.marketing_handover_open_facebook' },
  { app: 'whatsapp', href: links.value?.whatsapp || '', label: 'tenant_settings.marketing_handover_open_whatsapp' },
  { app: 'viber', href: links.value?.viber || '', label: 'tenant_settings.marketing_handover_open_viber' },
].filter((o) => o.href))

function say(msg: string) {
  toast.value = msg
  if (toastTimer) clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { toast.value = '' }, 4000)
}

function save(href: string, name: string) {
  const a = document.createElement('a')
  a.href = href
  a.download = name
  a.rel = 'noopener'
  document.body.appendChild(a)
  a.click()
  a.remove()
}

async function packZip(urls: string[]) {
  const used = new Set<string>()
  const files = await Promise.all(urls.map(async (u, i) => {
    const r = await fetch(u, { credentials: 'omit', signal: AbortSignal.timeout(DOC_READ_TIMEOUT_MS) })
    if (!r.ok) throw new Error(`photo ${r.status}`)
    return { name: handoverFileName(u, i, used), bytes: new Uint8Array(await r.arrayBuffer()) }
  }))
  const blob = new Blob([handoverZip(files) as BlobPart], { type: 'application/zip' })
  const href = URL.createObjectURL(blob)
  save(href, `${props.post.id}-photos.zip`)
  setTimeout(() => URL.revokeObjectURL(href), 60000)
  return files.map((f) => f.name)
}

async function download() {
  const plan = handoverDownloadPlan(picked.value)
  if (plan.kind === 'none' || packing.value) return
  error.value = ''
  packing.value = true
  try {
    if (plan.kind === 'single') {
      lastPack.value = [handoverFileName(plan.urls[0], 0, new Set())]
      save(plan.urls[0], lastPack.value[0])
    } else {
      lastPack.value = await packZip(plan.urls)
    }
  } catch {
    // a photo another host serves without CORS: each one on its own instead
    error.value = t('tenant_settings.marketing_handover_download_failed')
    const used = new Set<string>()
    lastPack.value = plan.urls.map((u, i) => handoverFileName(u, i, used))
    plan.urls.forEach((u, i) => save(u, lastPack.value[i]))
  } finally {
    packing.value = false
  }
}

async function copy() {
  error.value = ''
  if (await writeClipboard(copyText.value)) say(t('tenant_settings.marketing_handover_copied'))
  else error.value = t('tenant_settings.marketing_handover_copy_failed')
}

async function mark() {
  if (!markChannel.value || marking.value) return
  marking.value = true
  error.value = ''
  try {
    await api.manualPublishMarketingPost(props.post.id, markChannel.value)
    marked.value = true
    say(t('tenant_settings.marketing_handover_marked'))
    emit('handed-over', props.post.id)
  } catch (e) {
    const status = (e as { status?: number } | null)?.status
    error.value = t(status === 409 ? 'tenant_settings.marketing_handover_mark_conflict' : 'tenant_settings.marketing_handover_mark_failed')
  } finally {
    marking.value = false
  }
}

// The LinkedIn list names no channel: the workspace's active LinkedIn one, if any.
async function findLinkedIn() {
  try {
    const r = await api.listMarketingChannels()
    const ch = (r?.channels || []).find((c) => c.platform === 'linkedin' && (c as { status?: string }).status === 'active')
    markChannel.value = ch?.channel_id || ''
  } catch {
    markChannel.value = ''
  }
}

onMounted(async () => {
  try {
    links.value = await api.getMarketingShareLinks(props.post.id)
    // the post's own picture is picked first; the author changes it
    const first = images.value[0]
    if (first) checked[first] = true
  } catch {
    loadError.value = true
  }
  if (!props.channel) await findLinkedIn()
})
onBeforeUnmount(() => { if (toastTimer) clearTimeout(toastTimer) })
</script>

<style scoped>
.mdh { display: flex; flex-direction: column; gap: 6px; margin: 6px 0 4px; padding: 10px 12px; border: 1px solid var(--color-border); border-radius: var(--radius-sm, 8px); background: var(--color-bg); }
.mdh-title { margin: 0; font-size: 0.875rem; }
.mdh-sub { margin: 6px 0 0; font-size: 0.8125rem; }
.mdh-line { margin: 0; }
.mdh-badges { display: flex; flex-wrap: wrap; gap: 6px; list-style: none; margin: 0; padding: 0; }
.mdh-badge { padding: 2px 8px; border-radius: var(--radius-pill); border: 1px solid var(--color-border); font-size: 0.75rem; }
.mdh-photos { display: flex; flex-wrap: wrap; gap: 8px; list-style: none; margin: 0; padding: 0; }
.mdh-photo-label { display: flex; align-items: center; gap: 4px; min-height: var(--tap, 44px); cursor: pointer; }
.mdh-pic { width: 72px; height: 72px; object-fit: cover; border-radius: var(--radius-sm, 8px); border: 1px solid var(--color-border); }
.mdh-actions { display: flex; flex-wrap: wrap; gap: 8px; }
.mdh-field { display: flex; flex-direction: column; gap: 2px; font-size: 0.875rem; }
.mdh-input { min-height: var(--tap, 44px); }
.mdh-caption { margin: 0; padding: 8px; white-space: pre-wrap; overflow-wrap: anywhere; font-family: inherit; font-size: 0.8125rem; border: 1px dashed var(--color-border); border-radius: var(--radius-sm, 8px); }
.mdh-viber { margin: 0; overflow-wrap: anywhere; font-size: 0.875rem; }
.mdh-toast { margin: 0; overflow-wrap: anywhere; }
.mdh-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
.btn:disabled { opacity: 0.55; cursor: not-allowed; }
</style>
