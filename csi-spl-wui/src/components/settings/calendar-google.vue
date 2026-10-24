<!-- Settings -> Google Calendar (spec 149 section 2.7, build row B8,
     SPL-3227): the member connects their OWN Google account in this
     workspace. Shown in every workspace (P10): outside cnf gcal.workspaces
     the hub answers 404 and the section says it is not available here, with
     no Connect button (2.9). Not connected: one Connect button, which opens
     Google's consent page; the hub's callback comes back to
     /?settings=calendar-google&gcal=connected (or gcal_error=<code>).
     Connected: the Google email, the target calendar, the last sync and its
     status, Sync now, Disconnect (with "remove imported events"). A revoked or
     error status shows its reason and Reconnect. Its own chunk, with
     utils/gcal-client.mjs: it never enters the initial download (C27). -->
<template>
  <SettingsSection id="settings-calendar-google" :title="t('settings.calendar_google')" data-test="settings-calendar-google">
    <div data-test="gcal" :data-view="view">
      <p v-if="notice" class="gcal__notice" :class="{ 'gcal__notice--warn': notice === 'gcal.notice_error' }" role="status" data-test="gcal-notice">{{ t(notice) }}</p>
      <p v-if="view === 'loading'" class="muted">{{ t('common.loading') }}</p>
      <p v-else-if="view === 'off'" class="muted" data-test="gcal-off">{{ t('gcal.unavailable') }}</p>
      <p v-else-if="view === 'not_configured'" class="muted" data-test="gcal-not-configured">{{ t('gcal.not_configured') }}</p>
      <template v-else-if="view === 'failed'">
        <p class="gcal__warn" role="alert" data-test="gcal-failed">{{ t('gcal.load_failed') }}</p>
        <div class="gcal__actions">
          <button type="button" class="btn" data-test="gcal-retry" @click="load()">{{ t('gcal.retry') }}</button>
        </div>
      </template>
      <template v-else-if="view === 'disconnected'">
        <p class="muted gcal__hint">{{ t('gcal.intro') }}</p>
        <div class="gcal__actions">
          <button type="button" class="btn" data-test="gcal-connect" :disabled="busy" @click="connect()">
            {{ busy ? t('gcal.connecting') : t('gcal.connect') }}
          </button>
        </div>
      </template>
      <template v-else>
        <dl class="gcal__facts" data-test="gcal-connected">
          <div class="gcal__row">
            <dt>{{ t('gcal.account') }}</dt>
            <dd data-test="gcal-email">{{ status?.google_email }}</dd>
          </div>
          <div class="gcal__row">
            <dt>{{ t('gcal.calendar') }}</dt>
            <dd data-test="gcal-calendar">{{ status?.calendar_title }}</dd>
          </div>
          <div class="gcal__row">
            <dt>{{ t('gcal.status') }}</dt>
            <dd data-test="gcal-status" :data-status="status?.status">{{ t(statusKey) }}</dd>
          </div>
          <div class="gcal__row">
            <dt>{{ t('gcal.last_sync') }}</dt>
            <dd data-test="gcal-last-sync">{{ lastSync }}</dd>
          </div>
        </dl>
        <p v-if="view === 'broken' && status?.status_detail" class="gcal__warn" role="alert" data-test="gcal-broken">{{ status.status_detail }}</p>
        <div class="gcal__actions">
          <button v-if="view === 'broken'" type="button" class="btn" data-test="gcal-reconnect" :disabled="busy" @click="connect()">
            {{ t('gcal.reconnect') }}
          </button>
          <button v-else type="button" class="btn" data-test="gcal-sync" :disabled="busy" @click="sync()">{{ t('gcal.sync_now') }}</button>
        </div>
        <div class="gcal__disconnect">
          <label class="gcal__tick">
            <input v-model="removeImported" type="checkbox" data-test="gcal-remove-imported" :disabled="busy">
            <span>{{ t('gcal.remove_imported') }}</span>
          </label>
          <button type="button" class="btn ghost danger" data-test="gcal-disconnect" :disabled="busy" @click="disconnect()">{{ t('gcal.disconnect') }}</button>
        </div>
      </template>
      <p v-if="actionMsg" class="gcal__result" :class="{ 'gcal__warn': actionWarn }" role="status" data-test="gcal-result">{{ t(actionMsg) }}</p>
    </div>
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { gcalConnect, gcalDisconnect, gcalReturnNotice, gcalStatus, gcalSync, gcalView } from '~/utils/gcal-client.mjs'

type GcalStatus = { connected?: boolean, google_email?: string, calendar_title?: string, status?: string, status_detail?: string, last_synced_at?: string }

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const api = useSpoolApi()
const status = ref<GcalStatus | null>(null)
const view = ref<string>('loading')
const busy = ref(false)
const removeImported = ref(false)
const actionMsg = ref('')
const actionWarn = ref(false)
const notice = computed(() => gcalReturnNotice(route.query as Record<string, unknown>))

const statusKey = computed(() => {
  const s = String(status.value?.status || 'connected')
  return s === 'revoked' ? 'gcal.status_revoked' : s === 'error' ? 'gcal.status_error' : 'gcal.status_connected'
})
const lastSync = computed(() => {
  const at = status.value?.last_synced_at
  if (!at) return t('gcal.never')
  return isoDateTime(at) || t('gcal.never')
})

async function load() {
  view.value = 'loading'
  try {
    status.value = await gcalStatus(api) as GcalStatus
    view.value = gcalView(status.value, null)
  } catch (e) {
    status.value = null
    view.value = gcalView(null, e as { status?: number })
  }
}

function said(key: string, warn = false) {
  actionMsg.value = key
  actionWarn.value = warn
}

async function connect() {
  busy.value = true
  said('')
  try {
    const url = await gcalConnect(api)
    if (url) {
      window.location.assign(url)
      return
    }
    await load()
  } catch (e) {
    const err = e as { status?: number }
    said(err.status === 503 ? 'gcal.not_configured' : 'gcal.connect_failed', true)
  } finally {
    busy.value = false
  }
}

async function sync() {
  busy.value = true
  try {
    await gcalSync(api)
    said('gcal.sync_started')
    await load()
  } catch (e) {
    const err = e as { status?: number, error?: string }
    said(err.error === 'sync_in_progress' ? 'gcal.sync_busy' : 'gcal.sync_failed', true)
  } finally {
    busy.value = false
  }
}

async function disconnect() {
  busy.value = true
  try {
    await gcalDisconnect(api, removeImported.value)
    removeImported.value = false
    said('gcal.disconnected')
    await load()
  } catch {
    said('gcal.disconnect_failed', true)
  } finally {
    busy.value = false
  }
}

onMounted(load)
</script>

<style scoped>
.gcal__hint { margin: 0 0 12px; }
.gcal__notice {
  margin: 0 0 12px;
  padding: 8px 12px;
  border-radius: var(--radius-sm, 8px);
  background: var(--color-bg);
}
.gcal__notice--warn,
.gcal__warn { color: var(--color-danger); }
.gcal__facts { margin: 0; display: flex; flex-direction: column; gap: 4px; }
.gcal__row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
  min-height: var(--tap, 44px);
}
.gcal__row dt { color: var(--color-muted); }
.gcal__row dd { margin: 0; min-width: 0; overflow-wrap: anywhere; font-weight: 600; }
.gcal__actions { margin-top: 12px; display: flex; gap: 8px; flex-wrap: wrap; }
.gcal__disconnect {
  margin-top: 16px;
  padding-top: 12px;
  border-top: 1px solid var(--color-border);
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
}
.gcal__tick { display: inline-flex; align-items: center; gap: 8px; min-height: var(--tap, 44px); }
.gcal__result { margin: 10px 0 0; font-size: 0.875rem; }
</style>
