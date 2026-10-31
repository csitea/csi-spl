<!-- Publish to LinkedIn (SPL-1698; owner HUM-10, topic add4fbf4 msgs
     f78e3eab, 3a3f366b: only the workspace owner publishes to LinkedIn),
     inside Tenant settings -> General, under the marketing switch. Lists the
     live blog posts not shared yet (GET /v1/marketing/posts), each with a
     Publish button (POST /v1/marketing/posts/{id}/publish). Shown only to
     the workspace owner who connected the LinkedIn channel: the hub answers
     403 to anyone else, and the section says so in one line (SPL-1856); a
     404 (marketing off, outside the allow-list or no channel connected)
     hides it, the switch above says why.
     spec 090 T035 (SPL-4494): with a `channel` (a Facebook Page or an
     Instagram account, from MarketingAccounts.vue) the same list publishes
     there (?channel=<id>, T034), each post with its picture, the length of
     the text the hub sends against the platform's cap (63,206 Facebook,
     2,200 Instagram) and, on Instagram, the JPEG rule. -->
<template>
  <div v-if="why" class="mp" data-test="tenant-marketing-publish-unavailable">
    <h4 class="mp-title">{{ title }}</h4>
    <p v-if="channel" class="muted mp-why">{{ t('tenant_settings.marketing_meta_forbidden') }}</p>
    <p v-else class="muted mp-why">{{ t('tenant_settings.marketing_publish_forbidden') }}</p>
  </div>
  <div v-else-if="shown" class="mp" data-test="tenant-marketing-publish" :data-channel="channel?.id || ''">
    <h4 class="mp-title">{{ title }}</h4>
    <small class="muted">{{ t(channel ? 'tenant_settings.marketing_meta_publish_hint' : 'tenant_settings.marketing_publish_hint') }}</small>
    <p v-if="!posts.length" class="muted" data-test="tenant-marketing-publish-empty">{{ t('tenant_settings.marketing_publish_empty') }}</p>
    <ul v-else class="mp-list">
      <li v-for="p in posts" :key="p.id" class="mp-row" :class="{ 'mp-row--meta': channel }" data-test="tenant-marketing-publish-row" :data-post="p.id">
        <template v-if="channel">
          <img v-if="p.image && !broken[p.id]" class="mp-pic" :src="p.image" :alt="t('tenant_settings.marketing_meta_preview_alt', { title: p.title || p.id })" data-test="marketing-meta-preview" @error="broken[p.id] = true">
          <span v-else class="mp-pic mp-pic--none" aria-hidden="true" />
        </template>
        <span class="mp-main">
          <span class="mp-name">{{ p.title || p.id }}</span>
          <template v-if="channel">
            <small class="mp-count" :class="{ 'mp-over': caption(p).over }" data-test="marketing-meta-chars" :data-count="caption(p).count" :data-limit="caption(p).limit">
              {{ t('tenant_settings.marketing_meta_chars', { count: metaNumber(caption(p).count), limit: metaNumber(caption(p).limit) }) }}
            </small>
            <small v-if="caption(p).over" class="mp-over" data-test="marketing-meta-shortened">{{ t('tenant_settings.marketing_meta_shortened') }}</small>
            <small v-if="metaNeedsJpeg(channel.platform, p.image)" class="mp-over" data-test="marketing-meta-needs-jpeg">{{ t('tenant_settings.marketing_meta_needs_jpeg') }}</small>
          </template>
        </span>
        <button
          type="button"
          class="btn"
          :disabled="busy !== '' || (channel !== undefined && metaNeedsJpeg(channel.platform, p.image))"
          data-test="tenant-marketing-publish-button"
          @click="publish(p.id)"
        >{{ t(channel ? 'tenant_settings.marketing_meta_publish_button' : 'tenant_settings.marketing_publish_button') }}</button>
      </li>
    </ul>
    <p v-if="notice" class="mp-notice" role="status" data-test="tenant-marketing-publish-notice">{{ notice }}</p>
    <p v-if="error" class="mp-error" role="alert" data-test="tenant-marketing-publish-error">{{ error }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { marketingSaysWhy } from '~/utils/tenant-settings.mjs'
import { metaCaption, metaNeedsJpeg, metaNumber, metaPublishErrorKey } from '~/utils/marketing-meta.mjs'

type Post = { id: string, title?: string, summary?: string, image?: string }
type MetaChannel = { id: string, platform: string, name: string }
type PublishResult = { published?: number, retried?: number, deferred?: number }

const props = defineProps<{ channel?: MetaChannel }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

const shown = ref(false)
// SPL-1856: the hub refused with 403, so one line says why there is no list
const why = ref(false)
const posts = ref<Post[]>([])
const busy = ref('')
const notice = ref('')
const error = ref('')
// a preview whose picture failed to load shows the empty frame instead
const broken = reactive<Record<string, boolean>>({})

const channel = computed(() => props.channel)
const title = computed(() => (props.channel
  ? t('tenant_settings.marketing_meta_publish_title', { name: props.channel.name })
  : t('tenant_settings.marketing_publish_title')))
const appUrl = import.meta.client ? window.location.origin : ''
const caption = (p: Post) => metaCaption(props.channel?.platform || '', p, appUrl)

// The hub's answer to a refused publish, as one plain sentence.
function publishErrorKey(e: unknown): string {
  if (props.channel) return 'tenant_settings.' + metaPublishErrorKey(e)
  const status = (e as { status?: number } | null)?.status
  if (status === 403) return 'tenant_settings.marketing_publish_forbidden'
  if (status === 409) return 'tenant_settings.marketing_publish_conflict'
  return 'tenant_settings.marketing_publish_failed'
}

// The notice for a publish the hub took, or '' when it reports a failure.
function doneKey(r: PublishResult | null): string {
  const meta = Boolean(props.channel)
  if ((r?.published ?? 0) > 0) return meta ? 'tenant_settings.marketing_meta_done' : 'tenant_settings.marketing_publish_done'
  if (meta && (r?.deferred ?? 0) > 0) return 'tenant_settings.marketing_meta_deferred'
  if ((r?.retried ?? 0) > 0) return 'tenant_settings.marketing_publish_retry'
  return ''
}

async function publish(id: string) {
  if (busy.value) return
  busy.value = id
  notice.value = ''
  error.value = ''
  try {
    const key = doneKey(await api.publishMarketingPost(id, props.channel?.id))
    if (key) notice.value = t(key)
    else error.value = t('tenant_settings.marketing_publish_failed')
    posts.value = posts.value.filter((p) => p.id !== id)
  } catch (e) {
    error.value = t(publishErrorKey(e))
    if ((e as { status?: number } | null)?.status === 409) posts.value = posts.value.filter((p) => p.id !== id)
  } finally {
    busy.value = ''
  }
}

onMounted(async () => {
  try {
    const r = await api.listMarketingPosts(props.channel?.id)
    posts.value = Array.isArray(r?.posts) ? r.posts.filter((p) => p && typeof p.id === 'string') : []
    shown.value = true
  } catch (e) {
    shown.value = false
    why.value = marketingSaysWhy('publish', e)
  }
})
</script>

<style scoped>
.mp { display: flex; flex-direction: column; gap: 4px; margin-top: 18px; padding-top: 14px; border-top: 1px solid var(--color-border); }
.mp-title { margin: 0 0 4px; font-size: 0.875rem; }
.mp-why { margin: 0; }
.mp-list { list-style: none; margin: 4px 0 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
.mp-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; min-height: var(--tap, 44px); }
.mp-main { display: flex; flex-direction: column; gap: 2px; flex: 1; min-width: 0; }
.mp-name { overflow-wrap: anywhere; }
.mp-row .btn:disabled { opacity: 0.55; cursor: not-allowed; }
.mp-pic { flex: none; width: 48px; height: 48px; border-radius: var(--radius-sm, 8px); object-fit: cover; background: var(--color-bg); border: 1px solid var(--color-border); }
.mp-count { color: var(--color-muted); }
.mp-over { color: var(--color-danger); overflow-wrap: anywhere; }
.mp-notice { margin: 0; overflow-wrap: anywhere; }
.mp-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
</style>
