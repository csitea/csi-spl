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
     utils/gcal-client.mjs: it never enters the initial download (C27).
     Spec 154 B18 (SPL-6278): while connected, and only in a workspace inside
     cnf contacts.workspaces (the access store's `contacts`, 2.9), the
     Contacts switch: on starts the sync of the person's Google contacts
     (its first cycle is the import, 11.2.2); a grant without the contacts
     scope sends the person to Google once to add it; last sync, status,
     Sync now; the binding in another workspace says so (409
     contacts_sync_elsewhere).
     SPL-6284 (owner: "Not visible in mobile"): Settings -> Contacts
     (contacts.vue) is this section with focus="contacts": the contacts part
     only. While Google is not connected the Contacts part is there too and
     says how to start: its button connects Google asking for calendar and
     contacts in one consent; the switch comes after the connection. -->
<template>
  <SettingsSection
    :id="only ? 'settings-contacts' : 'settings-calendar-google'"
    :title="only ? t('gcal.contacts_title') : t('settings.calendar_google')"
    :data-test="only ? 'settings-contacts' : 'settings-calendar-google'"
  >
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
        <template v-if="!only">
          <p class="muted gcal__hint">{{ t('gcal.intro') }}</p>
          <div class="gcal__actions">
            <button type="button" class="btn" data-test="gcal-connect" :disabled="busy" @click="connect()">
              {{ busy ? t('gcal.connecting') : t('gcal.connect') }}
            </button>
          </div>
        </template>
        <section v-if="cview === 'connect'" class="gcal__contacts" :class="{ 'gcal__contacts--only': only }" data-test="gcal-contacts" data-view="connect" :aria-label="t('gcal.contacts_title')">
          <span class="gcal__switch-title">{{ t('gcal.contacts_switch') }}</span>
          <p class="muted gcal__switch-hint">{{ t('gcal.contacts_intro') }}</p>
          <div class="gcal__actions">
            <button type="button" class="btn" data-test="gcal-contacts-connect" :disabled="busy" @click="connect(GCAL_WANT_CONTACTS)">
              {{ busy ? t('gcal.connecting') : t('gcal.contacts_grant') }}
            </button>
          </div>
        </section>
      </template>
      <template v-else>
        <dl v-if="!only" class="gcal__facts" data-test="gcal-connected">
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
        <div v-if="!only || view === 'broken'" class="gcal__actions">
          <button v-if="view === 'broken'" type="button" class="btn" data-test="gcal-reconnect" :disabled="busy" @click="connect()">
            {{ t('gcal.reconnect') }}
          </button>
          <button v-else type="button" class="btn" data-test="gcal-sync" :disabled="busy" @click="sync()">{{ t('gcal.sync_now') }}</button>
        </div>
        <section v-if="cview !== 'hidden'" class="gcal__contacts" :class="{ 'gcal__contacts--only': only }" data-test="gcal-contacts" :data-view="cview" :aria-label="t('gcal.contacts_title')">
          <p v-if="cview === 'failed'" class="gcal__warn" role="alert" data-test="gcal-contacts-failed">{{ t('gcal.contacts_load_failed') }}</p>
          <template v-else>
            <label class="gcal__switch">
              <span>
                <span class="gcal__switch-title">{{ t('gcal.contacts_switch') }}</span>
                <span class="muted gcal__switch-hint">{{ t('gcal.contacts_intro') }}</span>
              </span>
              <input
                type="checkbox"
                role="switch"
                data-test="gcal-contacts-switch"
                :checked="contactsChecked"
                :aria-checked="contactsChecked ? 'true' : 'false'"
                :disabled="busy || cview === 'elsewhere'"
                @change="toggleContacts(($event.target as HTMLInputElement).checked)"
              >
            </label>
            <p v-if="cview === 'elsewhere'" class="gcal__warn" role="status" data-test="gcal-contacts-elsewhere">{{ t('gcal.contacts_elsewhere') }}</p>
            <template v-if="cview === 'grant'">
              <p class="gcal__warn" role="status" data-test="gcal-contacts-grant-needed">{{ t('gcal.contacts_needs_grant') }}</p>
              <div class="gcal__actions">
                <button type="button" class="btn" data-test="gcal-contacts-grant" :disabled="busy" @click="grantContacts()">{{ t('gcal.contacts_grant') }}</button>
              </div>
            </template>
            <template v-if="cview === 'on'">
              <dl class="gcal__facts">
                <div class="gcal__row">
                  <dt>{{ t('gcal.last_sync') }}</dt>
                  <dd data-test="gcal-contacts-last-sync">{{ contactsLastSync }}</dd>
                </div>
              </dl>
              <p v-if="cstate?.status_detail" class="gcal__warn" role="status" data-test="gcal-contacts-detail">{{ cstate.status_detail }}</p>
              <div class="gcal__actions">
                <button type="button" class="btn" data-test="gcal-contacts-sync" :disabled="busy" @click="syncContacts()">{{ t('gcal.sync_now') }}</button>
              </div>
            </template>
          </template>
          <p v-if="contactsMsg" class="gcal__result" :class="{ 'gcal__warn': contactsWarn }" role="status" data-test="gcal-contacts-result">{{ t(contactsMsg) }}</p>
        </section>
        <div v-if="!only" class="gcal__disconnect">
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
import { useAccessStore } from '~/stores/access'
import {
  GCAL_WANT_CONTACTS, contactsSyncNow, contactsSyncSet, contactsSyncState, contactsSyncView,
  gcalConnect, gcalDisconnect, gcalReturnNotice, gcalStatus, gcalSync, gcalSyncFollower, gcalView,
} from '~/utils/gcal-client.mjs'

type GcalStatus = { connected?: boolean, google_email?: string, calendar_title?: string, status?: string, status_detail?: string, last_synced_at?: string }
type ContactsSync = { enabled?: boolean, elsewhere?: boolean, scope_granted?: boolean, status_detail?: string, last_synced_at?: string | null }

/* focus="contacts": Settings -> Contacts, the contacts part only (SPL-6284) */
const props = defineProps<{ focus?: string }>()
const only = computed(() => props.focus === 'contacts')
const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const api = useSpoolApi()
const status = ref<GcalStatus | null>(null)
const view = ref<string>('loading')
const busy = ref(false)
const removeImported = ref(false)
const actionMsg = ref('')
const actionWarn = ref(false)
const notice = computed(() => gcalReturnNotice(route.query as Record<string, unknown>, view.value))
const access = useAccessStore()
const cstate = ref<ContactsSync | null>(null)
const cview = ref<string>('hidden')
const contactsMsg = ref('')
const contactsWarn = ref(false)
const contactsChecked = computed(() => cview.value === 'on' || cview.value === 'grant')
const contactsLastSync = computed(() => {
  const at = cstate.value?.last_synced_at
  return (at && isoDateTime(at)) || t('gcal.never')
})

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
  await loadContacts()
}

// spec 154 B18: the switch's state, read only while Google is connected and
// the workspace is inside contacts.workspaces (no read to find that out, 2.9).
// SPL-6284: not connected, in such a workspace, is 'connect' (how to start).
async function loadContacts() {
  await access.ensure()
  if (!access.contacts || view.value !== 'connected') {
    cstate.value = null
    cview.value = access.contacts && view.value === 'disconnected' ? 'connect' : 'hidden'
    return
  }
  try {
    cstate.value = await contactsSyncState(api) as ContactsSync
    cview.value = contactsSyncView(cstate.value, null)
  } catch (e) {
    cstate.value = null
    cview.value = contactsSyncView(null, e as { status?: number })
  }
}

function saidContacts(key: string, warn = false) {
  contactsMsg.value = key
  contactsWarn.value = warn
}

// Google's consent page, once, for the contacts scope; the callback comes
// back here and the binding, already on, starts its first cycle
async function grantContacts() {
  busy.value = true
  saidContacts('')
  try {
    const url = await gcalConnect(api, GCAL_WANT_CONTACTS)
    if (url) {
      window.location.assign(url)
      return
    }
    await loadContacts()
  } catch (e) {
    const err = e as { status?: number }
    saidContacts(err.status === 503 ? 'gcal.not_configured' : 'gcal.connect_failed', true)
  } finally {
    busy.value = false
  }
}

async function toggleContacts(on: boolean) {
  busy.value = true
  saidContacts('')
  let refused = false
  try {
    await contactsSyncSet(api, on)
  } catch (e) {
    refused = true
    const err = e as { error?: string }
    saidContacts(err.error === 'contacts_sync_elsewhere' ? 'gcal.contacts_elsewhere' : 'gcal.contacts_failed', true)
  } finally {
    busy.value = false
  }
  await loadContacts()
  if (refused) return
  /* on without the contacts scope: Google's consent page; with no page to
     go to (the mock) the grant is already read back */
  if (on && cview.value === 'grant') await grantContacts()
  if (on && cview.value !== 'on') return
  saidContacts(on ? 'gcal.contacts_started' : 'gcal.contacts_stopped')
}

async function syncContacts() {
  busy.value = true
  try {
    await contactsSyncNow(api)
    saidContacts('gcal.sync_started')
    await loadContacts()
  } catch (e) {
    const err = e as { error?: string }
    if (err.error === 'sync_in_progress') saidContacts('gcal.sync_busy')
    else saidContacts('gcal.sync_failed', true)
  } finally {
    busy.value = false
  }
}

function said(key: string, warn = false) {
  actionMsg.value = key
  actionWarn.value = warn
}

async function connect(want?: string) {
  busy.value = true
  said('')
  try {
    const url = await gcalConnect(api, want)
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

// SPL-5726: a quiet re-read (no 'loading' flash) after Sync now, until the
// last sync moves or the reads run out: the sync ends after its 202, so the
// read right after it still shows the old time ("Not yet" on a new link).
// Leaving the page stops it, a read in flight included (gcalSyncFollower).
const follower = gcalSyncFollower(() => gcalStatus(api), (st) => {
  status.value = st as GcalStatus
  view.value = gcalView(status.value, null)
})

async function sync() {
  busy.value = true
  const before = status.value?.last_synced_at
  try {
    await gcalSync(api)
    said('gcal.sync_started')
    await load()
  } catch (e) {
    const err = e as { status?: number, error?: string }
    // a sync already running is news, not a failure (SPL-5726): said plainly
    if (err.error === 'sync_in_progress') said('gcal.sync_busy')
    else said('gcal.sync_failed', true)
  } finally {
    busy.value = false
  }
  if (actionMsg.value !== 'gcal.sync_failed' && status.value?.last_synced_at === before) follower.start(before)
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
onBeforeUnmount(() => follower.stop())
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
.gcal__contacts {
  margin-top: 16px;
  padding-top: 12px;
  border-top: 1px solid var(--color-border);
}
.gcal__switch {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  min-height: var(--tap, 44px);
  cursor: pointer;
}
.gcal__switch > span { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.gcal__switch-title { font-weight: 600; }
.gcal__switch-hint { font-size: 0.875rem; }
.gcal__switch input { width: 44px; height: 24px; flex: none; margin: 0; cursor: pointer; }
.gcal__contacts .gcal__warn { margin: 8px 0 0; }
.gcal__contacts--only { margin-top: 0; padding-top: 0; border-top: 0; }
.gcal__contacts > .gcal__switch-hint { margin: 2px 0 0; }
</style>
