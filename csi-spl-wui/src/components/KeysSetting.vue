<!-- Settings → Keys (specs/023 §3.1-3.3, contracts/keys-v1.md). The default
     Ed25519 pair is generated in this browser on the first visit with no
     active key; only its PUBLIC half is sent to the hub. The private half
     stays in this component's memory, downloadable until the page is left.
     The public key downloads any time (pin form + OpenSSH form); a pasted or
     chosen public key replaces the active one; history is kept by the hub. -->
<template>
  <div class="keys" data-test="keys">
    <p class="muted keys__hint">{{ t('settings.keys.intro') }}</p>
    <p class="muted keys__hint">{{ t('settings.keys.use') }}</p>

    <p v-if="loading" class="muted" data-test="keys-loading">{{ t('common.loading') }}</p>
    <p v-else-if="generating" class="muted" role="status" data-test="keys-generating">{{ t('settings.keys.generating') }}</p>

    <p v-if="error" class="login-error" role="alert" data-test="keys-error">{{ error }}</p>
    <p v-if="notice" class="muted" role="status" data-test="keys-notice">{{ notice }}</p>
    <p v-if="!supported && !loading" class="muted" data-test="keys-unsupported">{{ t('settings.keys.unsupported') }}</p>

    <template v-if="!loading">
      <h4>{{ t('settings.keys.active') }}</h4>
      <div v-if="active" class="keys__active" data-test="keys-active">
        <dl class="keys__facts">
          <dt>{{ t('settings.keys.fingerprint') }}</dt>
          <dd><code data-test="keys-fingerprint">{{ active.fingerprint }}</code></dd>
          <dt>{{ t('settings.keys.upload_label') }}</dt>
          <dd><code class="keys__pub" data-test="keys-public">{{ active.public_key }}</code></dd>
        </dl>
        <p class="muted keys__meta">
          {{ t(active.source === 'generated' ? 'settings.keys.source_generated' : 'settings.keys.source_uploaded') }}
          · {{ t('settings.keys.added', { date: when(active.created_at) }) }}
        </p>
        <div class="keys__actions">
          <button class="btn" type="button" data-test="keys-download-public" @click="downloadPublic">{{ t('settings.keys.download_public') }}</button>
          <button class="btn ghost" type="button" data-test="keys-download-openssh" @click="downloadOpenSSH">{{ t('settings.keys.download_openssh') }}</button>
          <button class="btn ghost" type="button" data-test="keys-copy-public" @click="copyPublic">{{ copied ? t('common.copied') : t('settings.keys.copy_public') }}</button>
          <button class="btn ghost" type="button" data-test="keys-revoke" :disabled="busy" @click="revokeActive">{{ t('settings.keys.revoke') }}</button>
        </div>

        <div v-if="fresh && fresh.id === active.id" class="keys__private" data-test="keys-private">
          <strong>{{ t('settings.keys.private_title') }}</strong>
          <p class="login-error" role="alert">{{ t('settings.keys.private_warning') }}</p>
          <button class="btn" type="button" data-test="keys-download-private" @click="downloadPrivate">{{ t('settings.keys.download_private') }}</button>
        </div>
      </div>
      <p v-else class="muted" data-test="keys-none">{{ t('settings.keys.none') }}</p>

      <div v-if="supported" class="keys__regen">
        <button class="btn ghost" type="button" data-test="keys-regenerate" :disabled="busy" @click="generate">{{ t('settings.keys.regenerate') }}</button>
        <span class="muted keys__hint">{{ t('settings.keys.regenerate_hint') }}</span>
      </div>

      <form class="keys__upload" data-test="keys-upload" @submit.prevent="upload">
        <h4>{{ t('settings.keys.upload_title') }}</h4>
        <p class="muted keys__hint">{{ t('settings.keys.upload_hint') }}</p>
        <label class="keys__label" for="keys-upload-text">{{ t('settings.keys.upload_label') }}</label>
        <textarea id="keys-upload-text" v-model="pasted" class="keys__text" rows="3" spellcheck="false" autocomplete="off" data-test="keys-upload-text" />
        <div class="keys__actions">
          <label class="btn ghost keys__file">
            {{ t('settings.keys.upload_file') }}
            <input type="file" accept=".pub,text/plain" data-test="keys-upload-file" @change="readFile">
          </label>
          <button class="btn" type="submit" :disabled="busy || !pasted.trim()" data-test="keys-upload-submit">{{ t('settings.keys.upload_submit') }}</button>
        </div>
      </form>

      <template v-if="keys.length > 1 || (keys.length === 1 && !active)">
        <h4>{{ t('settings.keys.history') }}</h4>
        <ul class="keys__history" data-test="keys-history">
          <li v-for="k in keys" :key="k.id" :data-test="'keys-history-' + k.id">
            <code>{{ k.fingerprint }}</code>
            <span class="keys__state" :class="'keys__state--' + state(k)">{{ t('settings.keys.state_' + state(k)) }}</span>
            <span class="muted">{{ when(k.created_at) }}</span>
          </li>
        </ul>
      </template>
    </template>
  </div>
</template>

<script setup lang="ts">
import { isoDateTime } from '~/utils/date-iso.mjs'
import { useSessionStore } from '~/stores/session'
import { userIdentity } from '~/utils/user-menu.mjs'
import {
  classifyPublicKeyInput,
  createKeysClient,
  ed25519Supported,
  generateHumanKeyPair,
  humanKeyFileNames,
  keysErrorKey,
  pinFormBytes,
  sshPublicLine,
} from '~/utils/human-keys.mjs'

type Key = {
  id: number
  fingerprint: string
  public_key: string
  openssh: string
  source: string
  created_at: string
  revoked_at: string | null
  revoked_reason: string
  active: boolean
}

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const hum = computed(() => userIdentity(session.claims).hum)
const client = createKeysClient({ base: useAuthBase() })

const loading = ref(true)
const generating = ref(false)
const busy = ref(false)
const supported = ref(true)
const keys = ref<Key[]>([])
const active = ref<Key | null>(null)
/* the pair made in this page: the ONLY copy of its private key */
const fresh = ref<{ id: number, privateKey: string } | null>(null)
const pasted = ref('')
const error = ref('')
const notice = ref('')
const copied = ref(false)
let autoTried = false

const state = (k: Key) => (k.revoked_at ? (k.revoked_reason === 'replaced' ? 'replaced' : 'revoked') : 'active')
const when = (iso: string) => isoDateTime(iso)

const fail = (out: { error: string }) => { error.value = t(keysErrorKey(out.error)) }

async function load() {
  const out = await client.list()
  if (!out.ok) {
    fail(out)
    return false
  }
  keys.value = (out.data?.keys || []) as Key[]
  active.value = (out.data?.active || null) as Key | null
  return true
}

async function generate() {
  error.value = ''
  notice.value = ''
  busy.value = true
  generating.value = true
  try {
    const kp = await generateHumanKeyPair()
    const out = await client.add({ publicKey: kp.publicKey, source: 'generated' })
    if (!out.ok) {
      fail(out)
      return
    }
    fresh.value = { id: out.data.id, privateKey: kp.privateKey }
    await load()
  } catch {
    supported.value = false
  } finally {
    busy.value = false
    generating.value = false
  }
}

async function upload() {
  error.value = ''
  notice.value = ''
  const kind = classifyPublicKeyInput(pasted.value)
  if (kind !== 'ok') {
    error.value = t(keysErrorKey(kind === 'private' ? 'private_key_refused' : 'bad_public_key'))
    return
  }
  busy.value = true
  const out = await client.add({ publicKey: pasted.value.trim(), source: 'uploaded' })
  busy.value = false
  if (!out.ok) {
    fail(out)
    return
  }
  pasted.value = ''
  fresh.value = null
  notice.value = t('settings.keys.uploaded')
  await load()
}

async function revokeActive() {
  if (!active.value) return
  error.value = ''
  notice.value = ''
  busy.value = true
  const out = await client.revoke(active.value.id)
  busy.value = false
  if (!out.ok) {
    fail(out)
    return
  }
  fresh.value = null
  notice.value = t('settings.keys.revoked')
  await load()
}

async function readFile(e: Event) {
  const f = (e.target as HTMLInputElement).files?.[0]
  if (!f || f.size > 8192) return
  pasted.value = (await f.text()).trim()
}

function save(name: string, text: string) {
  const url = URL.createObjectURL(new Blob([text], { type: 'application/octet-stream' }))
  const a = document.createElement('a')
  a.href = url
  a.download = name
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}

const names = computed(() => humanKeyFileNames(hum.value))
const downloadPublic = () => active.value && save(names.value.public, active.value.public_key + '\n')
const downloadOpenSSH = () => active.value &&
  save(names.value.openssh, (active.value.openssh || sshPublicLine(pinFormBytes(active.value.public_key), 'spool:' + hum.value)) + '\n')
const downloadPrivate = () => fresh.value && save(names.value.private, fresh.value.privateKey + '\n')

async function copyPublic() {
  if (!active.value) return
  try {
    await navigator.clipboard.writeText(active.value.public_key)
    copied.value = true
    setTimeout(() => { copied.value = false }, 1500)
  } catch { /* clipboard refused: the key is on screen */ }
}

onMounted(async () => {
  supported.value = await ed25519Supported()
  const ok = await load()
  loading.value = false
  // FR-002: the default pair, once per page load, only when there is none.
  if (ok && !active.value && supported.value && !autoTried) {
    autoTried = true
    await generate()
  }
})
</script>

<style scoped>
.keys { display: flex; flex-direction: column; gap: 10px; min-width: 0; }
.keys h4 { margin: 8px 0 0; font-size: 0.875rem; }
.keys__hint { font-size: 0.8125rem; margin: 0; }
.keys__active, .keys__upload, .keys__private { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.keys__facts { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 4px 12px; margin: 0; min-width: 0; }
.keys__facts dt { color: var(--color-muted); font-size: 0.8125rem; }
.keys__facts dd { margin: 0; min-width: 0; overflow-wrap: anywhere; }
.keys__pub, .keys__facts code { overflow-wrap: anywhere; word-break: break-all; }
.keys__meta { font-size: 0.8125rem; margin: 0; }
.keys__actions { display: flex; flex-wrap: wrap; gap: 8px; }
.keys__private {
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-sm, 8px);
  padding: 10px 12px;
  background: var(--color-surface);
}
.keys__private p { margin: 0; }
.keys__regen { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.keys__label { font-size: 0.8125rem; color: var(--color-muted); }
.keys__text {
  width: 100%;
  box-sizing: border-box;
  font-family: var(--font-mono, monospace);
  font-size: 0.8125rem;
  resize: vertical;
  min-width: 0;
}
.keys__file { position: relative; overflow: hidden; }
.keys__file input { position: absolute; inset: 0; opacity: 0; cursor: pointer; }
.keys__history { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
.keys__history li { display: flex; flex-wrap: wrap; gap: 8px; align-items: baseline; min-width: 0; }
.keys__history code { overflow-wrap: anywhere; word-break: break-all; min-width: 0; }
.keys__state { font-size: 0.75rem; padding: 1px 6px; border-radius: var(--radius-pill); border: 1px solid var(--color-border); }
.keys__state--active { color: var(--color-accent); border-color: var(--color-accent); }
</style>
