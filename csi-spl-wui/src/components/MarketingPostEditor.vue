<!-- Workspace settings -> Posts (spec 090 section 22, SPL-5240; owner HUM-10,
     t1 19ef7d51; poll c1d8be01 Q1 A, Q2 A): an admin or business owner
     writes a post for the workspace, edits or deletes it while it is a
     draft, and publishes it on the workspace's connected accounts with no
     approval step. Every admin and business owner sees every draft; only
     its author edits, deletes and publishes it, and a published one is kept
     as it went out (the hub answers 403 and 409; the buttons follow it).
     GET/POST /v1/marketing/drafts, PATCH/DELETE .../{id}, POST .../{id}/publish.
     404 = marketing off (one line points to General), 403 = not an admin. -->
<template>
  <div class="mpe" data-test="marketing-posts">
    <p v-if="state === 'loading'" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="state === 'off'" class="muted" role="status" data-test="marketing-posts-off">{{ t('tenant_settings.posts_off') }}</p>
    <p v-else-if="state === 'forbidden'" class="muted" role="alert" data-test="marketing-posts-forbidden">{{ t('tenant_settings.forbidden') }}</p>
    <p v-else-if="state === 'error'" class="mpe-error" role="alert" data-test="marketing-posts-error">{{ t('tenant_settings.posts_failed') }}</p>
    <template v-else>
      <p class="muted mpe-intro">{{ t('tenant_settings.posts_intro') }}</p>
      <form class="mpe-form" data-test="marketing-posts-form" @submit.prevent="save">
        <label class="mpe-field">
          <span>{{ t('tenant_settings.posts_body_label') }}</span>
          <textarea v-model="body" rows="6" :maxlength="DRAFT_MAX_CHARS" data-test="marketing-posts-body" />
          <small class="muted" data-test="marketing-posts-count">{{ t('tenant_settings.posts_count', { count: draftChars(body), limit: DRAFT_MAX_CHARS }) }}</small>
        </label>
        <label class="mpe-field">
          <span>{{ t('tenant_settings.posts_image_label') }}</span>
          <input v-model="imageUrl" type="url" inputmode="url" autocomplete="off" spellcheck="false" data-test="marketing-posts-image">
          <small class="muted">{{ t('tenant_settings.posts_image_hint') }}</small>
        </label>
        <div class="mpe-actions">
          <button type="submit" class="btn" :disabled="busy || !body.trim()" data-test="marketing-posts-save">
            {{ editing ? t('tenant_settings.posts_update') : t('tenant_settings.posts_save') }}
          </button>
          <button v-if="editing" type="button" class="btn ghost" data-test="marketing-posts-cancel" @click="resetForm">{{ t('tenant_settings.posts_cancel') }}</button>
        </div>
      </form>
      <p v-if="notice" class="mpe-notice" role="status" data-test="marketing-posts-notice">{{ notice }}</p>
      <p v-if="error" class="mpe-error" role="alert" data-test="marketing-posts-error-line">{{ error }}</p>
      <p v-if="!channels.length" class="muted" data-test="marketing-posts-no-channels">{{ t('tenant_settings.posts_no_channels') }}</p>
      <p v-if="!drafts.length" class="muted" data-test="marketing-posts-empty">{{ t('tenant_settings.posts_empty') }}</p>
      <ul v-else class="mpe-list">
        <li v-for="d in drafts" :key="d.id" class="mpe-row" data-test="marketing-posts-row" :data-draft="d.id" :data-published="d.published_at ? '1' : '0'">
          <div class="mpe-head">
            <span class="mpe-badge" :class="{ 'mpe-badge--sent': d.published_at }">{{ d.published_at ? t('tenant_settings.posts_published') : t('tenant_settings.posts_draft') }}</span>
            <small v-if="!d.mine" class="muted" data-test="marketing-posts-other">{{ t('tenant_settings.posts_by_other') }}</small>
          </div>
          <p class="mpe-body">{{ d.body }}</p>
          <ul v-if="d.posts?.length" class="mpe-sent" :aria-label="t('tenant_settings.posts_sent_to')">
            <li v-for="p in d.posts" :key="p.channel_id" data-test="marketing-posts-sent">{{ t(draftStateKey(p.status), { name: labelOf(p.channel_id) }) }}</li>
          </ul>
          <div v-if="d.mine" class="mpe-actions">
            <button v-if="!d.published_at" type="button" class="btn ghost" :disabled="busy" data-test="marketing-posts-edit" @click="edit(d)">{{ t('tenant_settings.posts_edit') }}</button>
            <button v-if="!d.published_at" type="button" class="btn ghost" :disabled="busy" data-test="marketing-posts-delete" @click="remove(d)">{{ t('tenant_settings.posts_delete') }}</button>
          </div>
          <fieldset v-if="d.mine && draftOpenChannels(d, channels).length" class="mpe-publish" data-test="marketing-posts-publish">
            <legend>{{ t('tenant_settings.posts_publish_on') }}</legend>
            <label v-for="c in draftOpenChannels(d, channels)" :key="c.channel_id" class="mpe-check">
              <input v-model="picked[d.id]" type="checkbox" :value="c.channel_id" data-test="marketing-posts-channel" :data-channel="c.channel_id">
              <span>{{ draftChannelLabel(c) }}</span>
            </label>
            <button type="button" class="btn" :disabled="busy || !picked[d.id]?.length" data-test="marketing-posts-publish-button" @click="publish(d)">{{ t('tenant_settings.posts_publish') }}</button>
          </fieldset>
        </li>
      </ul>
    </template>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { DRAFT_MAX_CHARS, draftChannelLabel, draftChars, draftErrorKey, draftOpenChannels, draftResultKey, draftStateKey } from '~/utils/marketing-drafts.mjs'

type Channel = { channel_id: string, platform: string, name: string }
type Draft = { id: string, body: string, image_url?: string, published_at?: string | null, mine?: boolean, posts?: Array<{ channel_id: string, status: string }> }

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

const state = ref<'loading' | 'ready' | 'off' | 'forbidden' | 'error'>('loading')
const drafts = ref<Draft[]>([])
const channels = ref<Channel[]>([])
const body = ref('')
const imageUrl = ref('')
const editing = ref('')
const busy = ref(false)
const notice = ref('')
const error = ref('')
// the channels ticked under each draft, by draft id
const picked = reactive<Record<string, string[]>>({})

const labelOf = (id: string) => draftChannelLabel(channels.value.find((c) => c.channel_id === id) || { platform: '', name: id })

async function load() {
  try {
    const r = await api.listMarketingDrafts()
    drafts.value = Array.isArray(r?.drafts) ? r.drafts : []
    channels.value = Array.isArray(r?.channels) ? r.channels : []
    for (const d of drafts.value) picked[d.id] = picked[d.id] || []
    state.value = 'ready'
  } catch (e) {
    const status = (e as { status?: number } | null)?.status
    state.value = status === 404 ? 'off' : status === 403 ? 'forbidden' : 'error'
  }
}

function resetForm() {
  editing.value = ''
  body.value = ''
  imageUrl.value = ''
}

function edit(d: Draft) {
  editing.value = d.id
  body.value = d.body
  imageUrl.value = d.image_url || ''
  notice.value = ''
  error.value = ''
}

// run one hub call with the busy flag; doneKey '' keeps the notice fn set
async function act(fn: () => Promise<unknown>, doneKey: string) {
  if (busy.value) return
  busy.value = true
  notice.value = ''
  error.value = ''
  try {
    await fn()
    if (doneKey) notice.value = t(doneKey)
    await load()
  } catch (e) {
    error.value = t(draftErrorKey(e))
  } finally {
    busy.value = false
  }
}

function save() {
  const id = editing.value
  void act(async () => {
    if (id) await api.updateMarketingDraft(id, body.value, imageUrl.value)
    else await api.createMarketingDraft(body.value, imageUrl.value)
    resetForm()
  }, 'tenant_settings.posts_saved')
}

function remove(d: Draft) {
  if (!confirm(t('tenant_settings.posts_delete_confirm'))) return
  void act(async () => {
    await api.deleteMarketingDraft(d.id)
    if (editing.value === d.id) resetForm()
  }, 'tenant_settings.posts_deleted')
}

function publish(d: Draft) {
  const ids = [...(picked[d.id] || [])]
  void act(async () => {
    const r = await api.publishMarketingDraft(d.id, ids)
    picked[d.id] = []
    const lines = (r?.results || []).map((x) => t(draftResultKey(x), { name: labelOf(x.channel_id) }))
    notice.value = lines.join(' · ')
  }, '')
}

onMounted(load)
</script>

<style scoped>
.mpe { display: flex; flex-direction: column; gap: 10px; }
.mpe-intro { margin: 0; }
.mpe-form { display: flex; flex-direction: column; gap: 10px; }
.mpe-field { display: flex; flex-direction: column; gap: 4px; }
.mpe-field textarea, .mpe-field input { width: 100%; font: inherit; padding: 8px; border: 1px solid var(--color-border); border-radius: var(--radius-sm, 8px); background: var(--color-bg); color: inherit; }
.mpe-actions { display: flex; flex-wrap: wrap; gap: 8px; }
.mpe-notice { margin: 0; overflow-wrap: anywhere; }
.mpe-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
.mpe-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 12px; }
.mpe-row { display: flex; flex-direction: column; gap: 6px; padding: 10px; border: 1px solid var(--color-border); border-radius: var(--radius-sm, 8px); }
.mpe-head { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.mpe-badge { font-size: 0.75rem; padding: 2px 8px; border-radius: 999px; border: 1px solid var(--color-border); }
.mpe-badge--sent { border-color: var(--color-accent, var(--color-border)); }
.mpe-body { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; }
.mpe-sent { margin: 0; padding-left: 18px; color: var(--color-muted); }
.mpe-publish { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; border: 0; padding: 0; margin: 0; }
.mpe-publish legend { padding: 0; margin-bottom: 4px; }
.mpe-check { display: inline-flex; align-items: center; gap: 6px; min-height: var(--tap, 44px); }
.mpe-row .btn:disabled, .mpe-actions .btn:disabled { opacity: 0.55; cursor: not-allowed; }
</style>
