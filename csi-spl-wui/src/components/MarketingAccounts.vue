<!-- Facebook Pages and Instagram accounts (spec 090 T035, SPL-4494), inside
     Tenant settings -> General under the marketing switch. Lists the
     workspace's connected Pages, each followed by its linked Instagram
     account (GET /v1/marketing/facebook/pages, T033), with an initials
     avatar and the status. Connect opens Meta's consent page (POST
     /v1/marketing/facebook/connect -> authorize_url); the hub's callback
     page links back here. A Page whose connecting member holds no posting
     task (metadata.tasks of GET /v1/marketing/channels) shows a permission
     banner instead of Publish. Publish opens MarketingPublish.vue for that
     account. Disconnect asks first and says how to revoke the app on
     Meta too; it calls the hub's DELETE /v1/marketing/channels/{id}
     (SPL-4496) on the live client and the mock alike (metaCanDisconnect).
     While the hub has no Meta app (cnf marketing.facebook.inject "false")
     every Meta route answers 503 not_configured: the section says so in one
     line, with no button and no retry. A 404 (marketing off) hides it: the
     switch above says why. -->
<template>
  <div v-if="view !== 'hidden' && view !== 'loading'" class="ma" data-test="marketing-meta-accounts" :data-view="view">
    <h4 class="ma-title">{{ t('tenant_settings.marketing_meta_title') }}</h4>
    <p v-if="view === 'not_configured'" class="muted ma-line" data-test="marketing-meta-not-configured">{{ t('tenant_settings.marketing_meta_not_configured') }}</p>
    <p v-else-if="view === 'failed'" class="ma-error ma-line" role="alert" data-test="marketing-meta-failed">{{ t('tenant_settings.marketing_meta_load_failed') }}</p>
    <template v-else>
      <small class="muted">{{ t('tenant_settings.marketing_meta_hint') }}</small>
      <p v-if="!rows.length" class="muted ma-line" data-test="marketing-meta-empty">{{ t('tenant_settings.marketing_meta_empty') }}</p>
      <ul v-else class="ma-list">
        <li v-for="r in rows" :key="r.id" class="ma-item" :class="{ 'ma-item--linked': r.linked }" data-test="marketing-meta-account" :data-channel="r.id" :data-platform="r.platform">
          <div class="ma-row">
            <span class="ma-avatar" :class="`ma-avatar--${r.platform}`" aria-hidden="true">{{ metaInitials(r.name) }}</span>
            <span class="ma-who">
              <span class="ma-name">{{ r.name }}</span>
              <small class="muted">{{ t(`tenant_settings.marketing_meta_platform_${r.platform}`) }} · <span data-test="marketing-meta-status" :data-status="r.status">{{ t(statusKey(r.status)) }}</span></small>
            </span>
            <span class="ma-actions">
              <button v-if="r.status === 'active' && r.canPost" type="button" class="btn ghost" :aria-expanded="open === r.id" data-test="marketing-meta-publish-open" @click="open = open === r.id ? '' : r.id">{{ t('tenant_settings.marketing_meta_publish_open') }}</button>
              <button v-if="canDisconnect" type="button" class="btn ghost danger" :disabled="busy" data-test="marketing-meta-disconnect" @click="ask(r)">{{ t('tenant_settings.marketing_meta_disconnect') }}</button>
            </span>
          </div>
          <p v-if="!r.canPost" class="ma-banner" role="alert" data-test="marketing-meta-no-admin">{{ t('tenant_settings.marketing_meta_no_admin') }}</p>
          <MarketingPublish v-if="open === r.id" :channel="{ id: r.id, platform: r.platform, name: r.name }" />
        </li>
      </ul>
      <div class="ma-connect">
        <button type="button" class="btn" :disabled="busy" data-test="marketing-meta-connect" @click="connect()">{{ t('tenant_settings.marketing_meta_connect') }}</button>
      </div>
    </template>
    <p v-if="notice" class="ma-line" role="status" data-test="marketing-meta-notice">{{ notice }}</p>
    <p v-if="error" class="ma-error ma-line" role="alert" data-test="marketing-meta-error">{{ error }}</p>
    <UiConfirm
      v-model:open="confirmOpen"
      :title="t('tenant_settings.marketing_meta_disconnect_title', { name: target?.name || '' })"
      testid="marketing-meta-disconnect-dialog"
      :confirm-label="t('tenant_settings.marketing_meta_disconnect')"
      :busy-label="t('tenant_settings.marketing_meta_disconnecting')"
      :busy="busy"
      :error="dialogError"
      @confirm="disconnect()"
    >
      <p class="ma-dialog-line">{{ t('tenant_settings.marketing_meta_disconnect_body') }}</p>
      <p v-if="target?.platform === 'facebook_page' && rows.some((x) => x.linked === target?.id)" class="ma-dialog-line" data-test="marketing-meta-disconnect-linked">{{ t('tenant_settings.marketing_meta_disconnect_page_ig') }}</p>
      <p class="muted ma-dialog-line" data-test="marketing-meta-revoke-hint">{{ t('tenant_settings.marketing_meta_revoke_hint') }}</p>
    </UiConfirm>
  </div>
</template>

<script setup lang="ts">
import MarketingPublish from '~/components/MarketingPublish.vue'
import UiConfirm from '~/components/UiConfirm.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { metaAccountRows, metaCanDisconnect, metaInitials, metaLoadView, metaRowsWithout } from '~/utils/marketing-meta.mjs'

type Row = { id: string, platform: string, name: string, status: string, canPost: boolean, linked: string }

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
const canDisconnect = metaCanDisconnect(api.mock)

function statusKey(s: string): string {
  if (s === 'active') return 'tenant_settings.marketing_meta_status_active'
  if (s === 'expired') return 'tenant_settings.marketing_meta_status_expired'
  return 'tenant_settings.marketing_meta_status_other'
}

async function load() {
  try {
    const [pages, chs] = await Promise.all([api.listMetaPages(), api.listMarketingChannels().catch(() => null)])
    rows.value = metaAccountRows(pages?.pages, chs?.channels) as Row[]
    view.value = 'list'
  } catch (e) {
    rows.value = []
    view.value = metaLoadView(e)
  }
}

async function connect() {
  if (busy.value) return
  busy.value = true
  notice.value = ''
  error.value = ''
  try {
    const r = await api.connectFacebook()
    if (r?.authorize_url) {
      window.location.assign(r.authorize_url)
      return
    }
    await load()
  } catch (e) {
    const status = (e as { status?: number } | null)?.status
    if (status === 503) view.value = 'not_configured'
    else error.value = t('tenant_settings.marketing_meta_connect_failed')
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
    rows.value = metaRowsWithout(rows.value, r.id) as Row[]
    if (open.value === r.id || !rows.value.some((x) => x.id === open.value)) open.value = ''
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
.ma { display: flex; flex-direction: column; gap: 4px; margin-top: 18px; padding-top: 14px; border-top: 1px solid var(--color-border); }
.ma-title { margin: 0 0 4px; font-size: 0.875rem; }
.ma-line { margin: 0; overflow-wrap: anywhere; }
.ma-error { color: var(--color-danger); }
.ma-list { list-style: none; margin: 6px 0 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
.ma-item { display: flex; flex-direction: column; gap: 4px; }
.ma-item--linked { padding-inline-start: 24px; }
.ma-row { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; min-height: var(--tap, 44px); }
.ma-avatar {
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
  background: var(--color-muted);
}
.ma-avatar--facebook_page { background: var(--color-accent, var(--color-muted)); }
/* a narrow screen wraps the buttons under the name rather than squeezing it */
.ma-who { display: flex; flex-direction: column; flex: 1 1 12rem; min-width: 0; }
.ma-name { overflow-wrap: anywhere; font-weight: 600; }
.ma-actions { display: flex; gap: 8px; flex-wrap: wrap; }
.ma-banner {
  margin: 0;
  padding: 8px 12px;
  border-radius: var(--radius-sm, 8px);
  border: 1px solid var(--color-danger);
  color: var(--color-danger);
  overflow-wrap: anywhere;
}
.ma-connect { margin-top: 8px; display: flex; gap: 8px; flex-wrap: wrap; }
.ma-dialog-line { margin: 0 0 8px; overflow-wrap: anywhere; }
</style>
