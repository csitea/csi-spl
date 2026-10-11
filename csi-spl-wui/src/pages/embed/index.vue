<!-- /embed (spec 121 T204): the workspace owner's embed admin page, the WUI
     side of the hub's /v1/tenant/embeds (T203). Lists the workspace's
     embeds; per embed the allowed origins (they become its frame-ancestors,
     T201), its switch and a new per-embed JWT key; a form creates one
     (disabled and keyless). The private key is in the key answer only: it
     is shown once here and Close drops it from memory. Owner only (any
     other member: the hub's 403); while cnf env.hub.embed.enabled is off
     the hub answers 404 and the page says so. -->
<template>
  <div class="feed-col">
    <header class="feed-header">
      <MobileBack />
      <SectionClose side="start" />
      <h2 id="embed-admin-h">{{ t('embed.title') }}</h2>
      <SectionClose side="end" />
    </header>
    <div class="feed-body ea" data-test="embed-admin">
      <p class="muted">{{ t('embed.description') }}</p>
      <p v-if="loading" class="muted" data-test="embed-admin-loading">{{ t('common.loading') }}</p>
      <p v-else-if="blocked" class="muted" role="alert" data-test="embed-admin-blocked" :data-reason="blocked">{{ t(blocked) }}</p>
      <template v-else>
        <div v-if="minted" class="ea__minted" role="dialog" :aria-label="t('embed.key_success')" data-test="embed-key-minted">
          <p class="ea__strong">{{ t('embed.key_success') }} <code>{{ minted.keyId }}</code></p>
          <p class="muted">{{ t('embed.private_key_warning') }}</p>
          <pre class="ea__key" data-test="embed-key-private">{{ minted.privateKey }}</pre>
          <div class="ea__actions">
            <button type="button" class="btn" data-test="embed-key-copy" @click="copyKey">{{ t('embed.copy_key') }}</button>
            <span v-if="copied" class="ea__ok" role="status" data-test="embed-key-copied">{{ copied === 'ok' ? t('common.copied') : t('common.copy_failed') }}</span>
            <button type="button" class="btn ghost" data-test="embed-key-close" @click="closeMinted">{{ t('common.close') }}</button>
          </div>
        </div>

        <p v-if="status" class="ea__ok" role="status" data-test="embed-admin-status">{{ status }}</p>
        <p v-if="error" class="ea__error" role="alert" data-test="embed-admin-error">{{ error }}</p>

        <ul class="ea__list" data-test="embed-list">
          <li v-for="e in rows" :key="e.embedId" class="ea__card" data-test="embed-row" :data-id="e.embedId" :data-enabled="String(e.enabled)">
            <h3 class="ea__title"><code>{{ e.embedId }}</code></h3>
            <p class="muted ea__meta" data-test="embed-key-id">{{ e.keyId ? t('embed.key_id', { id: e.keyId, alg: e.keyAlg }) : t('embed.no_key') }}</p>
            <label class="ea__field">
              <span>{{ t('embed.allowed_origins') }}</span>
              <textarea v-model="forms[e.embedId].origins" rows="3" :placeholder="t('embed.allowed_origins_placeholder')" data-test="embed-origins" />
            </label>
            <p class="muted ea__meta">{{ t('embed.allowed_origins_hint') }}</p>
            <label class="ea__check">
              <input v-model="forms[e.embedId].enabled" type="checkbox" data-test="embed-enabled">
              <span>{{ t('embed.enabled') }}</span>
            </label>
            <div class="ea__actions">
              <button type="button" class="btn" :disabled="busy" data-test="embed-save" @click="save(e.embedId)">{{ t('embed.save') }}</button>
              <template v-if="confirming === e.embedId">
                <span class="ea__warn" data-test="embed-key-confirm-text">{{ t('embed.replace_key_confirm') }}</span>
                <button type="button" class="btn" :disabled="busy" data-test="embed-key-confirm" @click="newKey(e.embedId)">{{ t('embed.generate_key') }}</button>
                <button type="button" class="btn ghost" :disabled="busy" @click="confirming = ''">{{ t('common.cancel') }}</button>
              </template>
              <button v-else type="button" class="btn ghost" :disabled="busy" data-test="embed-key-new" @click="askKey(e)">{{ t('embed.generate_key') }}</button>
            </div>
          </li>
        </ul>

        <form class="ea__card ea__create" data-test="embed-create-form" @submit.prevent="create">
          <h3 class="ea__title">{{ t('embed.create_title') }}</h3>
          <label class="ea__field">
            <span>{{ t('embed.embed_id') }}</span>
            <input v-model="newId" type="text" maxlength="64" autocomplete="off" :placeholder="t('embed.embed_id_placeholder')" data-test="embed-new-id">
          </label>
          <label class="ea__field">
            <span>{{ t('embed.allowed_origins') }}</span>
            <textarea v-model="newOrigins" rows="3" :placeholder="t('embed.allowed_origins_placeholder')" data-test="embed-new-origins" />
          </label>
          <div class="ea__actions">
            <button type="submit" class="btn" :disabled="busy" data-test="embed-create">{{ t('embed.create') }}</button>
          </div>
        </form>
      </template>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useAccessStore } from '~/stores/access'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { writeClipboard } from '~/utils/clipboard.mjs'
import { embedErrorKey, embedIdValid, embedRow, embedRows, originsFromText, originsText } from '~/utils/embed-admin.mjs'

type Row = ReturnType<typeof embedRow>
type Err = { status?: number, token?: string, detail?: string }

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const access = useAccessStore()
const api = useSpoolApi()
const signedIn = computed(() => (session.state === 'in' && !!session.claims) || api.mock)

const loading = ref(true)
/* an i18n key when the page cannot show at all: not the owner, off, failed */
const blocked = ref('')
const rows = ref<Row[]>([])
const forms = ref<Record<string, { origins: string, enabled: boolean }>>({})
const newId = ref('')
const newOrigins = ref('')
const busy = ref(false)
const error = ref('')
const status = ref('')
const confirming = ref('')
const copied = ref<'' | 'ok' | 'fail'>('')
/* the one key answer: held only while its panel is open */
const minted = ref<{ keyId: string, privateKey: string } | null>(null)

function show(list: Row[]) {
  rows.value = list
  forms.value = Object.fromEntries(list.map((r) => [r.embedId, { origins: originsText(r.origins), enabled: r.enabled }]))
}

function fail(e: unknown) {
  const err = e as Err
  const key = embedErrorKey(err)
  error.value = key === 'embed.bad_origin' && err?.detail ? `${t(key)} ${err.detail}` : t(key)
}

async function load() {
  try {
    show(embedRows(await api.listEmbeds()))
    blocked.value = ''
  } catch (e) {
    blocked.value = embedErrorKey(e, { listing: true })
  } finally {
    loading.value = false
  }
}

async function run(fn: () => Promise<void>) {
  if (busy.value) return
  busy.value = true
  error.value = ''
  status.value = ''
  try {
    await fn()
  } catch (e) {
    fail(e)
  } finally {
    busy.value = false
  }
}

const save = (id: string) => run(async () => {
  const f = forms.value[id]
  if (!f) return
  await api.patchEmbed(id, { allowed_origins: originsFromText(f.origins), enabled: f.enabled })
  await load()
  status.value = t('embed.save_success')
})

/* a first key needs no confirm; a new one revokes the old */
function askKey(e: Row) {
  if (e.keyId) confirming.value = e.embedId
  else void newKey(e.embedId)
}

const newKey = (id: string) => run(async () => {
  confirming.value = ''
  const r = await api.newEmbedKey(id)
  minted.value = { keyId: String(r.key_id || ''), privateKey: String(r.private_key || '') }
  copied.value = ''
  await load()
})

const create = () => run(async () => {
  const id = newId.value.trim()
  if (!embedIdValid(id)) {
    error.value = t('embed.bad_id')
    return
  }
  await api.createEmbed({ embed_id: id, allowed_origins: originsFromText(newOrigins.value) })
  newId.value = ''
  newOrigins.value = ''
  await load()
  status.value = t('embed.create_success')
})

async function copyKey() {
  if (!minted.value) return
  copied.value = (await writeClipboard(minted.value.privateKey)) ? 'ok' : 'fail'
}

function closeMinted() {
  minted.value = null
  copied.value = ''
}

watch(signedIn, (v) => {
  if (!v) return
  void access.load().then(() => {
    /* me() null = unknown: the hub's 403 decides */
    if (access.me && !access.me.tenantOwner) {
      blocked.value = 'embed.not_owner'
      loading.value = false
      return
    }
    return load()
  })
}, { immediate: true })

onBeforeUnmount(() => { minted.value = null })
</script>

<style scoped>
.ea { display: flex; flex-direction: column; gap: 12px; }
.ea__list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 12px; }
.ea__card { display: flex; flex-direction: column; gap: 6px; padding: 12px; border: 1px solid var(--color-border); max-width: 640px; }
.ea__title { margin: 0; font-size: 1rem; }
.ea__meta { margin: 0; font-size: 0.8125rem; }
.ea__strong { margin: 0; font-weight: 600; }
.ea__field { display: flex; flex-direction: column; gap: 2px; font-size: 0.8125rem; }
.ea__field input, .ea__field textarea {
  padding: 6px 8px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
  font-size: 0.875rem;
}
.ea__field textarea { resize: vertical; min-height: 64px; }
.ea__check { display: flex; align-items: center; gap: 6px; font-size: 0.875rem; }
.ea__actions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.ea__minted { padding: 10px; border: 1px solid var(--color-border-strong); background: var(--color-surface); max-width: 640px; }
.ea__key { margin: 8px 0; padding: 8px; white-space: pre-wrap; overflow-wrap: anywhere; font-size: 0.8125rem; background: var(--color-bg); border: 1px solid var(--color-border); }
.ea__ok { margin: 0; font-size: 0.8125rem; color: var(--color-ok); }
.ea__error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
.ea__warn { font-size: 0.8125rem; color: var(--color-danger); overflow-wrap: anywhere; }
@media (max-width: 820px) {
  .ea .btn, .ea__field input { min-height: var(--tap, 44px); }
}
</style>
