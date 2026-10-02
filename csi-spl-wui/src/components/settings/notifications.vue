<!-- Settings -> Notifications (owner, 2026-09-26: "those enable alerts, chime
     settings should be in the personal settings of each user"). The same
     notification store as the icon row at the foot of the left pane, so the
     two always agree. Browser alerts are a permission of THIS browser; the
     chime is kept per browser as well (loadChime / saveChime).
     051 (owner dd88348d: "the beep sound is too plain. Could it be something
     more funny"): a sound picker, each playable, kept per browser too.
     HUM-24 (311427c6, third "no notification" report): the bell said "on"
     while the browser had never been asked or blocked alerts, so the section
     now names the real state, asks / tests in one click, says what a platform
     cannot do, and lists the channels muted in this browser. -->
<template>
  <SettingsSection id="settings-notifications" :title="t('settings.notifications')" data-test="settings-notifications">
    <div class="settings__row">
      <span>{{ t('notify.enable_alerts') }}</span>
      <button
        type="button"
        class="btn"
        data-test="settings-notify-alerts"
        :aria-pressed="alertsWanted"
        @click="notes.toggleAlerts()"
      >
        <UiIcon :name="alertsWanted ? 'bell' : 'bell-off'" :size="18" />
        {{ alertsWanted ? t('notify.alerts_on') : t('notify.enable_alerts') }}
      </button>
    </div>
    <div class="settings__state" data-test="settings-notify-state" :data-state="notes.alertStatus" role="status">
      <p class="settings__state-text" :class="{ 'settings__state-text--warn': warn }">{{ t(`notify.state_${notes.alertStatus}`) }}</p>
      <div class="settings__state-actions">
        <button
          v-if="notes.alertStatus === 'ask'"
          type="button"
          class="btn"
          data-test="settings-notify-allow"
          @click="notes.requestPush()"
        >
          {{ t('notify.allow') }}
        </button>
        <button
          v-if="canTest"
          type="button"
          class="btn"
          data-test="settings-notify-test"
          @click="test()"
        >
          {{ t('notify.test') }}
        </button>
      </div>
      <p v-if="testResult" class="muted settings__state-result" data-test="settings-notify-test-result" :data-result="testResult">
        {{ t(testResult === 'shown' ? 'notify.test_shown' : testResult === 'failed' ? 'notify.test_failed' : `notify.state_${testResult}`) }}
      </p>
      <!-- HUM-24 (311427c6, msg 031f937d: "the page is reloaded, no sound is
           heard"): the chime is opt-in (005), and with it off every alert is
           silent too (SPL-998), so say so where the reader looks -->
      <p v-if="!notes.chime" class="settings__state-text--warn" data-test="settings-notify-silent">{{ t('notify.sound_off_hint') }}</p>
      <p class="muted settings__state-hint">{{ t('notify.background_hint') }}</p>
    </div>
    <div v-if="muted.length" class="settings__muted" data-test="settings-notify-muted">
      <span class="settings__sound-label">{{ t('notify.muted_label') }}</span>
      <div v-for="ch in muted" :key="ch" class="settings__row">
        <span>#{{ ch }}</span>
        <button type="button" class="btn" :data-test="`settings-notify-unmute-${ch}`" @click="unmute(ch)">
          <UiIcon name="bell" :size="16" />
          {{ t('notify.unmute') }}
        </button>
      </div>
    </div>
    <div class="settings__row">
      <label for="settings-chime">{{ t('notify.chime') }}</label>
      <input id="settings-chime" v-model="notes.chime" type="checkbox" data-test="settings-notify-chime">
    </div>
    <div class="settings__sound" data-test="settings-notify-sound">
      <span :id="`${uid}-sound-label`" class="settings__sound-label">{{ t('notify.sound_label') }}</span>
      <div class="settings__sound-opts" role="radiogroup" :aria-labelledby="`${uid}-sound-label`" :aria-describedby="`${uid}-sound-hint`">
        <div v-for="name in SOUND_NAMES" :key="name" class="settings__sound-opt" :class="{ 'settings__sound-opt--on': notes.sound === name }">
          <label class="settings__sound-pick">
            <input
              type="radio"
              name="notify-sound"
              :value="name"
              :checked="notes.sound === name"
              :data-test="`settings-notify-sound-${name}`"
              @change="pick(name)"
            >
            <span>{{ t(`notify.sound_${name}`) }}</span>
          </label>
          <button
            type="button"
            class="btn settings__sound-play"
            :data-test="`settings-notify-sound-play-${name}`"
            :aria-label="t('notify.sound_preview') + ': ' + t(`notify.sound_${name}`)"
            @click="preview(name)"
          >
            <UiIcon name="music" :size="16" />
            {{ t('notify.sound_preview') }}
          </button>
        </div>
      </div>
      <p :id="`${uid}-sound-hint`" class="muted settings__sound-hint">{{ t('notify.sound_hint') }}</p>
    </div>
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import { useNotificationStore } from '~/stores/notification'
import {
  MUTED_CHANNELS_KEY,
  SOUND_NAMES,
  loadMutedChannels,
  playSound,
  saveMutedChannels,
  toggleMutedChannel,
} from '~/utils/notify.mjs'

const { t } = useI18n({ useScope: 'global' })
const notes = useNotificationStore()
const uid = useId()
const alertsWanted = computed(() => notes.alertsEnabled)
const warn = computed(() => ['ask', 'blocked', 'install', 'unsupported'].includes(notes.alertStatus))
/* a test is worth offering wherever the browser can still answer it */
const canTest = computed(() => ['on', 'off', 'ask'].includes(notes.alertStatus))
const testResult = ref('')
async function test() {
  testResult.value = ''
  testResult.value = await notes.testAlert()
}

/* this browser's muted channels (the sidebar's row menu mutes them): a muted
   channel neither chimes nor alerts, which is easy to forget months later */
const muted = ref<string[]>([])
onMounted(() => { muted.value = loadMutedChannels() })
function unmute(ch: string) {
  muted.value = saveMutedChannels(toggleMutedChannel(muted.value, ch))
  /* the sidebar listens for this key, as for a change made in another tab */
  window.dispatchEvent(new StorageEvent('storage', { key: MUTED_CHANNELS_KEY }))
}

/** Choosing a sound also plays it, so the pick and its sound arrive together. */
function pick(name: string) {
  notes.sound = name
  playSound(name)
}
function preview(name: string) {
  playSound(name)
}
</script>

<style scoped>
.settings__row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
  min-height: var(--tap, 44px);
}
.settings__row .btn { display: inline-flex; align-items: center; gap: 6px; }
.settings__state { display: grid; gap: 6px; margin-bottom: 8px; min-width: 0; }
.settings__state p { margin: 0; overflow-wrap: anywhere; }
.settings__state-text--warn { color: var(--color-warn); font-weight: 600; }
.settings__state-actions { display: flex; flex-wrap: wrap; gap: 8px; }
.settings__state-actions .btn { min-height: var(--tap, 44px); }
.settings__muted { display: grid; gap: 2px; margin-bottom: 8px; min-width: 0; }
.settings__sound {
  display: grid;
  gap: 6px;
  margin-top: 8px;
  min-width: 0;
}
.settings__sound-label { font-weight: 600; }
.settings__sound-opts { display: grid; gap: 2px; }
.settings__sound-opt {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  min-height: var(--tap, 44px);
}
.settings__sound-pick {
  display: flex;
  align-items: center;
  gap: 8px;
  cursor: pointer;
  min-width: 0;
  overflow-wrap: anywhere;
  /* SPL-1221: the label IS the radio's touch target (mobile-m5 measures the
     closest label), so it must be a full 44 px tall, not just its ~27 px of
     text - the enclosing opt row was 44 px but the label sat centred inside. */
  min-height: var(--tap, 44px);
}
.settings__sound-opt--on { color: var(--color-accent); }
.settings__sound-play { display: inline-flex; align-items: center; gap: 6px; flex: 0 0 auto; }
.settings__sound-hint { margin: 0; overflow-wrap: anywhere; }
/* SPL-993: on a touch screen the whole row is the checkbox's target. */
@media (max-width: 820px) {
  .settings__row label { flex: 1 1 auto; align-self: stretch; display: flex; align-items: center; }
  .settings__row input[type='checkbox'] { width: 22px; height: 22px; }
  .settings__sound-opt input[type='radio'] { width: 22px; height: 22px; }
}
</style>
