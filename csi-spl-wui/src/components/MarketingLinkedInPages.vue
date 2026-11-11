<!-- LinkedIn company pages (spec 090 phase 4, T041, SPL-5258;
     linkedin-company-page.md 6.4), inside Tenant settings -> General under
     the marketing switch, after X. Lists the workspace's connected Company
     Pages (GET /v1/marketing/linkedin-org/pages): name, link to the page,
     status and when the connection ends. Connect opens LinkedIn's consent
     page of the second LinkedIn app (POST /v1/marketing/linkedin-org/connect
     -> authorize_url); a Super admin or Content admin of the page connects it
     once, and from then on any admin or business owner of the workspace
     publishes as the company. Publish opens MarketingPublish.vue for that
     page, its button naming the page. Disconnect asks first and says how to
     revoke the app on LinkedIn too (DELETE /v1/marketing/channels/{id}).
     While the hub has no Company Page app (cnf marketing.linkedin_org.inject
     "false") every route answers 503 not_configured: the section says so in
     one line, with no button. A 404 (marketing off) hides it. -->
<template>
  <div v-if="view !== 'hidden' && view !== 'loading'" class="lp" data-test="marketing-li-pages" :data-view="view">
    <h4 class="lp-title">{{ t('tenant_settings.marketing_li_page_title') }}</h4>
    <p v-if="view === 'not_configured'" class="muted lp-line" data-test="marketing-li-page-not-configured">{{ t('tenant_settings.marketing_li_page_not_configured') }}</p>
    <p v-else-if="view === 'failed'" class="lp-error lp-line" role="alert" data-test="marketing-li-page-failed">{{ t('tenant_settings.marketing_meta_load_failed') }}</p>
    <template v-else>
      <small class="muted">{{ t('tenant_settings.marketing_li_page_hint') }}</small>
      <p v-if="!rows.length" class="muted lp-line" data-test="marketing-li-page-empty">{{ t('tenant_settings.marketing_li_page_empty') }}</p>
      <ul v-else class="lp-list">
        <li v-for="r in rows" :key="r.id" class="lp-item" data-test="marketing-li-page" :data-channel="r.id">
          <div class="lp-row">
            <span class="lp-avatar" aria-hidden="true">{{ metaInitials(r.name) }}</span>
            <span class="lp-who">
              <a v-if="r.url" class="lp-name" :href="r.url" target="_blank" rel="noopener noreferrer" data-test="marketing-li-page-link">{{ r.name }}</a>
              <span v-else class="lp-name">{{ r.name }}</span>
              <small class="muted">{{ t('tenant_settings.marketing_li_page_platform') }} · <span data-test="marketing-li-page-status" :data-status="r.status">{{ t(statusKey(r.status)) }}</span></small>
              <small v-if="r.expiresAt && r.status === 'active'" class="muted" data-test="marketing-li-page-expires">{{ t('tenant_settings.marketing_li_page_expires', { date: r.expiresAt }) }}</small>
            </span>
            <span class="lp-actions">
              <button v-if="r.status === 'active'" type="button" class="btn ghost" :aria-expanded="open === r.id" data-test="marketing-li-page-publish-open" @click="open = open === r.id ? '' : r.id">{{ t('tenant_settings.marketing_meta_publish_open') }}</button>
              <button type="button" class="btn ghost danger" :disabled="busy" data-test="marketing-li-page-disconnect" @click="ask(r)">{{ t('tenant_settings.marketing_meta_disconnect') }}</button>
            </span>
          </div>
          <MarketingPublish v-if="open === r.id" :channel="{ id: r.id, platform: r.platform, name: r.name }" />
        </li>
      </ul>
      <div class="lp-connect">
        <button type="button" class="btn" :disabled="busy" data-test="marketing-li-page-connect" @click="connect()">{{ t('tenant_settings.marketing_li_page_connect') }}</button>
      </div>
    </template>
    <p v-if="notice" class="lp-line" role="status" data-test="marketing-li-page-notice">{{ notice }}</p>
    <p v-if="error" class="lp-error lp-line" role="alert" data-test="marketing-li-page-error">{{ error }}</p>
    <UiConfirm
      v-model:open="confirmOpen"
      :title="t('tenant_settings.marketing_meta_disconnect_title', { name: target?.name || '' })"
      testid="marketing-li-page-disconnect-dialog"
      :confirm-label="t('tenant_settings.marketing_meta_disconnect')"
      :busy-label="t('tenant_settings.marketing_meta_disconnecting')"
      :busy="busy"
      :error="dialogError"
      @confirm="disconnect()"
    >
      <p class="lp-dialog-line">{{ t('tenant_settings.marketing_meta_disconnect_body') }}</p>
      <p class="muted lp-dialog-line" data-test="marketing-li-page-revoke-hint">{{ t('tenant_settings.marketing_li_page_revoke_hint') }}</p>
    </UiConfirm>
  </div>
</template>

<script setup lang="ts">
import MarketingPublish from '~/components/MarketingPublish.vue'
import UiConfirm from '~/components/UiConfirm.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { metaInitials } from '~/utils/marketing-meta.mjs'
import { liPageLoadView, liPageRows } from '~/utils/marketing-linkedin-page.mjs'

type Row = { id: string, platform: string, name: string, url: string, status: string, expiresAt: string }

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
    const r = await api.listLinkedInPages()
    rows.value = liPageRows(r?.pages) as Row[]
    view.value = 'list'
  } catch (e) {
    rows.value = []
    view.value = liPageLoadView(e)
  }
}

async function connect() {
  if (busy.value) return
  busy.value = true
  notice.value = ''
  error.value = ''
  try {
    const r = await api.connectLinkedInPage()
    if (r?.authorize_url) {
      window.location.assign(r.authorize_url)
      return
    }
    await load()
  } catch (e) {
    const status = (e as { status?: number } | null)?.status
    if (status === 503) view.value = 'not_configured'
    else error.value = t('tenant_settings.marketing_li_page_connect_failed')
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
.lp { display: flex; flex-direction: column; gap: 4px; margin-top: 18px; padding-top: 14px; border-top: 1px solid var(--color-border); }
.lp-title { margin: 0 0 4px; font-size: 0.875rem; }
.lp-line { margin: 0; overflow-wrap: anywhere; }
.lp-error { color: var(--color-danger); }
.lp-list { list-style: none; margin: 6px 0 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
.lp-item { display: flex; flex-direction: column; gap: 4px; }
.lp-row { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; min-height: var(--tap, 44px); }
.lp-avatar {
  flex: none;
  width: 36px;
  height: 36px;
  border-radius: var(--radius-sm, 8px);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 0.8125rem;
  font-weight: 600;
  color: var(--color-bg);
  background: var(--color-text, var(--color-muted));
}
/* a narrow screen wraps the buttons under the name rather than squeezing it */
.lp-who { display: flex; flex-direction: column; flex: 1 1 12rem; min-width: 0; }
.lp-name { overflow-wrap: anywhere; font-weight: 600; }
.lp-actions { display: flex; gap: 8px; flex-wrap: wrap; }
.lp-connect { margin-top: 8px; display: flex; gap: 8px; flex-wrap: wrap; }
.lp-dialog-line { margin: 0 0 8px; overflow-wrap: anywhere; }
</style>
