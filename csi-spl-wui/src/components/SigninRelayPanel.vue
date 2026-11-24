<!-- One Agent keys row's subscription sign-in (spec 181 row B11, gap G11;
     owner Q-5, Q-14 A; spec 159 4.3): the CLI on the workspace's private VM
     signs in to the person's own subscription, driven from here only. Start
     asks the hub to start the CLI's own terminal login on the VM; the page
     polls the relay until the VM reports the vendor's https URL, shows it as
     a link, and takes the code the vendor shows back in one password field,
     sent once and cleared at that moment. The hub's switch is per vendor and
     off until that vendor's written OK (403 signin_relay_off). -->
<template>
  <div class="sr" data-test="sr" :data-kind="kind" :data-state="state">
    <p class="muted sr-line">{{ t('tenant_settings.agent_keys.signin.hint') }}</p>
    <div v-if="!relay || done" class="sr-actions">
      <button type="button" class="btn" :disabled="busy" data-test="sr-start" @click="start">
        {{ t('tenant_settings.agent_keys.signin.start') }}
      </button>
    </div>
    <p v-if="relay && state === 'starting'" class="muted sr-line" role="status" data-test="sr-starting">
      {{ t('tenant_settings.agent_keys.signin.starting') }}
    </p>
    <form v-if="relay && url && !done" class="sr-form" @submit.prevent="send">
      <a :href="url" target="_blank" rel="noopener noreferrer" data-test="sr-link">{{ t('tenant_settings.agent_keys.signin.open_link') }}</a>
      <label class="sr-field">
        <span>{{ t('tenant_settings.agent_keys.signin.code_label') }}</span>
        <input v-model="code" type="password" autocomplete="off" spellcheck="false" :disabled="busy" data-test="sr-code">
      </label>
      <div class="sr-actions">
        <button type="submit" class="btn" :disabled="busy || !code" data-test="sr-send">{{ t('tenant_settings.agent_keys.signin.send') }}</button>
        <button type="button" class="btn ghost" :disabled="busy" data-test="sr-cancel" @click="cancel">{{ t('tenant_settings.agent_keys.signin.cancel') }}</button>
      </div>
    </form>
    <p v-if="state === 'input_sent'" class="muted sr-line" role="status" data-test="sr-sent">{{ t('tenant_settings.agent_keys.signin.sent') }}</p>
    <p v-if="state === 'signed_in'" class="sr-ok sr-line" role="status" data-test="sr-signed-in">{{ t('tenant_settings.agent_keys.signin.signed_in') }}</p>
    <p v-if="state === 'delivered'" class="muted sr-line" role="status" data-test="sr-delivered">{{ t('tenant_settings.agent_keys.signin.delivered') }}</p>
    <p v-if="error" class="sr-error sr-line" role="alert" data-test="sr-error">{{ error }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { SIGNIN_RELAY_DONE, normalizeSigninRelay, signinInputOK, signinRelayErrorKey } from '~/utils/signin-relay.mjs'

const props = defineProps<{ kind: string }>()

type SigninRelayApi = { signinRelay: (op: 'start' | 'get' | 'input' | 'end', id?: string | null, body?: unknown) => Promise<unknown> }

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi() as unknown as SigninRelayApi

const POLL_MS = 2000
const relay = ref('')
const state = ref('')
const url = ref('')
const code = ref('')
const busy = ref(false)
const error = ref('')
let timer: ReturnType<typeof setTimeout> | null = null

const done = computed(() => SIGNIN_RELAY_DONE.includes(state.value))

function stop() {
  if (timer) clearTimeout(timer)
  timer = null
}

function fail(e: unknown) {
  stop()
  error.value = t(signinRelayErrorKey(e))
}

/* reads the relay until it shows a URL to act on, or ends */
async function poll() {
  stop()
  try {
    const v = normalizeSigninRelay(await api.signinRelay('get', relay.value))
    state.value = v.state
    if (v.url) url.value = v.url
    if (v.state === 'failed') {
      error.value = t('tenant_settings.agent_keys.signin.error.failed', { reason: v.reason || '-' })
      return
    }
    if (done.value || (v.state === 'url' && url.value)) return
    timer = setTimeout(() => { void poll() }, POLL_MS)
  } catch (e) {
    fail(e)
  }
}

async function start() {
  busy.value = true
  error.value = ''
  url.value = ''
  try {
    const v = normalizeSigninRelay(await api.signinRelay('start', null, { kind: props.kind }))
    relay.value = v.relay
    state.value = v.state
    void poll()
  } catch (e) {
    relay.value = ''
    fail(e)
  } finally {
    busy.value = false
  }
}

async function send() {
  const input = code.value
  code.value = '' /* sent once, never kept */
  if (!signinInputOK(input)) {
    error.value = t('tenant_settings.agent_keys.signin.error.bad_input')
    return
  }
  busy.value = true
  error.value = ''
  try {
    await api.signinRelay('input', relay.value, { input })
    state.value = 'input_sent'
    url.value = ''
    void poll()
  } catch (e) {
    fail(e)
  } finally {
    busy.value = false
  }
}

async function cancel() {
  stop()
  code.value = ''
  try {
    await api.signinRelay('end', relay.value)
  } catch { /* the relay ends at its deadline anyway */ }
  state.value = 'ended'
  url.value = ''
}

onBeforeUnmount(stop)
</script>

<style scoped>
.sr { display: flex; flex-direction: column; gap: 6px; }
.sr-line { margin: 0; }
.sr-form { display: flex; flex-direction: column; gap: 6px; }
.sr-field { display: flex; flex-direction: column; gap: 4px; }
.sr-actions { display: flex; gap: 8px; flex-wrap: wrap; }
.sr-ok { color: var(--color-ok); }
.sr-error { color: var(--color-danger); overflow-wrap: anywhere; }
</style>
