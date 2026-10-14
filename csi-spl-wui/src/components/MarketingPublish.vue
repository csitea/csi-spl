<!-- Publish to LinkedIn (SPL-1698; owner HUM-10, topic add4fbf4 msgs
     f78e3eab, 3a3f366b: only the workspace owner publishes to LinkedIn),
     inside Tenant settings -> General, under the marketing switch. Lists the
     live blog posts not shared yet (GET /v1/marketing/posts), each with a
     Publish button (POST /v1/marketing/posts/{id}/publish). Shown only to
     the workspace owner who connected the LinkedIn channel: the hub answers
     403 to anyone else, and the section says so in one line (SPL-1856); a
     404 (marketing off, outside the allow-list or no channel connected)
     hides it, the switch above says why. -->
<template>
  <div v-if="why" class="mp" data-test="tenant-marketing-publish-unavailable">
    <h4 class="mp-title">{{ t('tenant_settings.marketing_publish_title') }}</h4>
    <p class="muted mp-why">{{ t('tenant_settings.marketing_publish_forbidden') }}</p>
  </div>
  <div v-else-if="shown" class="mp" data-test="tenant-marketing-publish">
    <h4 class="mp-title">{{ t('tenant_settings.marketing_publish_title') }}</h4>
    <small class="muted">{{ t('tenant_settings.marketing_publish_hint') }}</small>
    <p v-if="!posts.length" class="muted" data-test="tenant-marketing-publish-empty">{{ t('tenant_settings.marketing_publish_empty') }}</p>
    <ul v-else class="mp-list">
      <li v-for="p in posts" :key="p.id" class="mp-row" data-test="tenant-marketing-publish-row" :data-post="p.id">
        <span class="mp-name">{{ p.title || p.id }}</span>
        <button
          type="button"
          class="btn"
          :disabled="busy !== ''"
          data-test="tenant-marketing-publish-button"
          @click="publish(p.id)"
        >{{ t('tenant_settings.marketing_publish_button') }}</button>
      </li>
    </ul>
    <p v-if="notice" class="mp-notice" role="status" data-test="tenant-marketing-publish-notice">{{ notice }}</p>
    <p v-if="error" class="mp-error" role="alert" data-test="tenant-marketing-publish-error">{{ error }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { marketingSaysWhy } from '~/utils/tenant-settings.mjs'

type Post = { id: string, title?: string }

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

const shown = ref(false)
// SPL-1856: the hub refused with 403, so one line says why there is no list
const why = ref(false)
const posts = ref<Post[]>([])
const busy = ref('')
const notice = ref('')
const error = ref('')

// The hub's answer to a refused publish, as one plain sentence.
function publishErrorKey(e: unknown): string {
  const status = (e as { status?: number } | null)?.status
  if (status === 403) return 'tenant_settings.marketing_publish_forbidden'
  if (status === 409) return 'tenant_settings.marketing_publish_conflict'
  return 'tenant_settings.marketing_publish_failed'
}

async function publish(id: string) {
  if (busy.value) return
  busy.value = id
  notice.value = ''
  error.value = ''
  try {
    const r = await api.publishMarketingPost(id)
    if ((r?.published ?? 0) > 0) notice.value = t('tenant_settings.marketing_publish_done')
    else if ((r?.retried ?? 0) > 0) notice.value = t('tenant_settings.marketing_publish_retry')
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
    const r = await api.listMarketingPosts()
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
.mp-name { overflow-wrap: anywhere; }
.mp-notice { margin: 0; overflow-wrap: anywhere; }
.mp-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
</style>
