<!-- SPL-5719 (spec 149 section 2.7): the member's Google Calendar connection
     is broken (status revoked or error) and the Calendar page says so, with
     a one-click Reconnect. Before this, only Settings -> Google Calendar
     showed it, so a connection that Google ended went unseen for days while
     the member's events stopped reaching Google (prd: three workspaces
     revoked by invalid_grant, each 7 days after its connect).
     It reads GET /v1/me/google-calendar once per page; a workspace without
     the feature (404), a hub without it (503), a failed read, no connection
     or a healthy one show nothing. No new text: the words are the Settings
     section's own keys. Its own chunk, with utils/gcal-client.mjs (C27). -->
<template>
  <div v-if="key" class="gcal-banner" role="alert" data-test="calendar-gcal-banner" :data-status="status?.status">
    <span class="gcal-banner__text">
      <strong>{{ t('settings.calendar_google') }}</strong>: {{ t(key) }}<template v-if="status?.status_detail"> ({{ status.status_detail }})</template>
    </span>
    <button type="button" class="btn gcal-banner__btn" data-test="calendar-gcal-reconnect" :disabled="busy" @click="reconnect()">
      {{ busy ? t('gcal.connecting') : t('gcal.reconnect') }}
    </button>
    <span v-if="failed" class="gcal-banner__warn" data-test="calendar-gcal-failed">{{ t('gcal.connect_failed') }}</span>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { gcalBannerKey, gcalConnect, gcalStatus } from '~/utils/gcal-client.mjs'

type GcalStatus = { connected?: boolean, status?: string, status_detail?: string }

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const status = ref<GcalStatus | null>(null)
const busy = ref(false)
const failed = ref(false)
const key = computed(() => gcalBannerKey(status.value))

async function load() {
  try {
    status.value = await gcalStatus(api) as GcalStatus
  } catch {
    status.value = null
  }
}

async function reconnect() {
  busy.value = true
  failed.value = false
  try {
    const url = await gcalConnect(api)
    if (url) {
      window.location.assign(url)
      return
    }
    await load()
  } catch {
    failed.value = true
  } finally {
    busy.value = false
  }
}

onMounted(load)
</script>

<style scoped>
.gcal-banner {
  display: flex;
  align-items: center;
  gap: 8px 12px;
  flex-wrap: wrap;
  padding: 8px 12px;
  border-bottom: 1px solid var(--color-border);
  color: var(--color-danger);
  background: var(--color-bg);
}
.gcal-banner__text { flex: 1 1 16rem; min-width: 0; overflow-wrap: anywhere; }
.gcal-banner__btn { min-height: var(--tap, 44px); }
.gcal-banner__warn { flex-basis: 100%; font-size: 0.875rem; }
</style>
