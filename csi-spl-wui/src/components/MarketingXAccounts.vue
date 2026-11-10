<!-- X accounts (spec 090 X row, SPL-5194), inside Tenant settings -> General
     under the marketing switch, after Facebook and Instagram. Lists the
     workspace's connected X accounts (GET /v1/marketing/x/accounts) with an
     initials avatar and the status. Connect opens X's consent page (POST
     /v1/marketing/x/connect -> authorize_url, OAuth 2.0 PKCE); the hub's
     callback page links back here. Publish opens MarketingPublish.vue for
     that account: each post's text as X counts it against 280, and the
     summary shortened to fit. Disconnect asks first and says how to revoke
     the app on X too (DELETE /v1/marketing/channels/{id}). While the hub has
     no X app (cnf marketing.x.inject "false") every X route answers 503
     not_configured: the section says so in one line, with no button and no
     retry. A 404 (marketing off) hides it: the switch above says why. -->
<template>
  <div v-if="view !== 'hidden' && view !== 'loading'" class="mx" data-test="marketing-x-accounts" :data-view="view">
    <h4 class="mx-title">{{ t('tenant_settings.marketing_x_title') }}</h4>
    <p v-if="view === 'not_configured'" class="muted mx-line" data-test="marketing-x-not-configured">{{ t('tenant_settings.marketing_x_not_configured') }}</p>
    <p v-else-if="view === 'failed'" class="mx-error mx-line" role="alert" data-test="marketing-x-failed">{{ t('tenant_settings.marketing_meta_load_failed') }}</p>
    <template v-else>
      <small class="muted">{{ t('tenant_settings.marketing_x_hint') }}</small>
      <p v-if="!rows.length" class="muted mx-line" data-test="marketing-x-empty">{{ t('tenant_settings.marketing_x_empty') }}</p>
      <ul v-else class="mx-list">
        <li v-for="r in rows" :key="r.id" class="mx-item" data-test="marketing-x-account" :data-channel="r.id">
          <div class="mx-row">
            <span class="mx-avatar" aria-hidden="true">{{ metaInitials(r.name) }}</span>
            <span class="mx-who">
              <span class="mx-name">{{ r.name }}</span>
              <small class="muted">{{ t('tenant_settings.marketing_x_platform') }} · <span data-test="marketing-x-status" :data-status="r.status">{{ t(statusKey(r.status)) }}</span></small>
            </span>
            <span class="mx-actions">
              <button v-if="r.status === 'active'" type="button" class="btn ghost" :aria-expanded="open === r.id" data-test="marketing-x-publish-open" @click="open = open === r.id ? '' : r.id">{{ t('tenant_settings.marketing_meta_publish_open') }}</button>
              <button type="button" class="btn ghost danger" :disabled="busy" data-test="marketing-x-disconnect" @click="ask(r)">{{ t('tenant_settings.marketing_meta_disconnect') }}</button>
            </span>
          </div>
          <MarketingPublish v-if="open === r.id" :channel="{ id: r.id, platform: r.platform, name: r.name }" />
        </li>
      </ul>
      <div class="mx-connect">
        <button type="button" class="btn" :disabled="busy" data-test="marketing-x-connect" @click="connect()">{{ t('tenant_settings.marketing_x_connect') }}</button>
      </div>
    </template>
    <p v-if="notice" class="mx-line" role="status" data-test="marketing-x-notice">{{ notice }}</p>
    <p v-if="error" class="mx-error mx-line" role="alert" data-test="marketing-x-error">{{ error }}</p>
    <UiConfirm
      v-model:open="confirmOpen"
      :title="t('tenant_settings.marketing_meta_disconnect_title', { name: target?.name || '' })"
      testid="marketing-x-disconnect-dialog"
      :confirm-label="t('tenant_settings.marketing_meta_disconnect')"
      :busy-label="t('tenant_settings.marketing_meta_disconnecting')"
      :busy="busy"
      :error="dialogError"
      @confirm="disconnect()"
    >
      <p class="mx-dialog-line">{{ t('tenant_settings.marketing_meta_disconnect_body') }}</p>
      <p class="muted mx-dialog-line" data-test="marketing-x-revoke-hint">{{ t('tenant_settings.marketing_x_revoke_hint') }}</p>
    </UiConfirm>
  </div>
</template>

<script setup lang="ts">
import MarketingPublish from '~/components/MarketingPublish.vue'
import UiConfirm from '~/components/UiConfirm.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { metaInitials } from '~/utils/marketing-meta.mjs'
import { xAccountRows, xLoadView } from '~/utils/marketing-x.mjs'

type Row = { id: string, platform: string, name: string, status: string }

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

const view = ref('loading')
const rows = ref<Row[]>([])
const busy = ref(false)
const open = ref('')
const notice = ref('')
const error = ref('')
const confirmOpen = ref(false)
const target = ref<Row | null>(null)
const dialogError = ref('')

function statusKey(s: string): string {
  if (s === 'active') return 'tenant_settings.marketing_meta_status_active'
  if (s === 'expired') return 'tenant_settings.marketing_meta_status_expired'
  return 'tenant_settings.marketing_meta_status_other'
}

async function load() {
  try {
    const r = await api.listXAccounts()
    rows.value = xAccountRows(r?.accounts) as Row[]
    view.value = 'list'
  } catch (e) {
    rows.value = []
    view.value = xLoadView(e)
  }
}

async function connect() {
  if (busy.value) return
  busy.value = true
  notice.value = ''
  error.value = ''
  try {
    const r = await api.connectX()
    if (r?.authorize_url) {
      window.location.assign(r.authorize_url)
      return
    }
    await load()
  } catch (e) {
    const status = (e as { status?: number } | null)?.status
    if (status === 503) view.value = 'not_configured'
    else error.value = t('tenant_settings.marketing_x_connect_failed')
  } finally {
    busy.value = false
  }
}

function ask(r: Row) {
  target.value = r
  dialogError.value = ''
  confirmOpen.value = true
}

async function disconnect() {
  const r = target.value
  if (!r || busy.value) return
  busy.value = true
  dialogError.value = ''
  try {
    await api.disconnectMarketingChannel(r.id)
    rows.value = rows.value.filter((x) => x.id !== r.id)
    if (open.value === r.id) open.value = ''
    confirmOpen.value = false
    notice.value = t('tenant_settings.marketing_meta_disconnected')
  } catch {
    dialogError.value = t('tenant_settings.marketing_meta_disconnect_failed')
  } finally {
    busy.value = false
  }
}

onMounted(load)
</script>

<style scoped>
.mx { display: flex; flex-direction: column; gap: 4px; margin-top: 18px; padding-top: 14px; border-top: 1px solid var(--color-border); }
.mx-title { margin: 0 0 4px; font-size: 0.875rem; }
.mx-line { margin: 0; overflow-wrap: anywhere; }
.mx-error { color: var(--color-danger); }
.mx-list { list-style: none; margin: 6px 0 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
.mx-item { display: flex; flex-direction: column; gap: 4px; }
.mx-row { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; min-height: var(--tap, 44px); }
.mx-avatar {
  flex: none;
  width: 36px;
  height: 36px;
  border-radius: 50%;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 0.8125rem;
  font-weight: 600;
  color: var(--color-bg);
  background: var(--color-text, var(--color-muted));
}
/* a narrow screen wraps the buttons under the name rather than squeezing it */
.mx-who { display: flex; flex-direction: column; flex: 1 1 12rem; min-width: 0; }
.mx-name { overflow-wrap: anywhere; font-weight: 600; }
.mx-actions { display: flex; gap: 8px; flex-wrap: wrap; }
.mx-connect { margin-top: 8px; display: flex; gap: 8px; flex-wrap: wrap; }
.mx-dialog-line { margin: 0 0 8px; overflow-wrap: anywhere; }
</style>
