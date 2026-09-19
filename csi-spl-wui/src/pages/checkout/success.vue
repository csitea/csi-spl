<!-- /checkout/success — where payment returns the browser (spec 006 T021w,
     contracts/checkout-v1.md §2.3–§2.4). Reads checkout_id + claim_token from
     sessionStorage (never the URL), polls GET /checkout/{id} until paid, then
     POSTs /claim ONCE (claimOnce: one POST per checkout per page load, shared
     by overlapping polls and re-mounts). The root private key lives only in
     this component's memory: shown once (CheckoutKeyReveal), cleared when the
     page is left. 410 claimed → "already collected", 410 claim_expired →
     "window closed" (1.2: the key is minted at claim and never emailed). -->
<template>
  <div class="login-card" data-test="checkout-success" :data-claim-state="state">
    <h1>{{ t('checkout.your_spool') }}</h1>
    <p v-if="state === 'waiting'" class="muted" role="status" data-test="checkout-waiting">{{ t('checkout.success.waiting') }}</p>
    <template v-else-if="state === 'ok'">
      <CheckoutKeyReveal :key-text="keyText" :tenant-url="tenantUrl" :tenant-id="tenantId" />
      <CheckoutHostStatus :checkout-id="hostCheckoutId" :host="tenantHost" :initial="hostStatus" />
    </template>
    <p v-else-if="state === 'claimed'" role="status" data-test="checkout-claimed">
      {{ t('checkout.success.claimed') }}
    </p>
    <p v-else-if="state === 'expired'" class="login-error" role="alert" data-test="checkout-expired">
      {{ t('checkout.success.expired') }}
    </p>
    <p v-else-if="state === 'none'" class="login-error" role="alert" data-test="checkout-none">
      {{ t('checkout.success.none') }}
    </p>
    <p v-else-if="state === 'failed' || state === 'cancelled'" class="login-error" role="alert" data-test="checkout-failed">
      {{ state === 'failed' ? t('checkout.success.failed') : t('checkout.success.cancelled') }}
    </p>
    <template v-else-if="state === 'error'">
      <p class="login-error" role="alert" data-test="checkout-claim-error">{{ error }}</p>
      <button v-if="retryable" class="btn" type="button" data-test="checkout-claim-retry" @click="retry">{{ t('checkout.try_again') }}</button>
    </template>
    <p><NuxtLink :to="localePath('/checkout')">{{ t('checkout.success.back') }}</NuxtLink></p>
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, shallowRef } from 'vue'
import CheckoutKeyReveal from '~/components/CheckoutKeyReveal.vue'
import CheckoutHostStatus from '~/components/CheckoutHostStatus.vue'
import {
  checkoutErrorKey,
  createCheckoutClient,
  loadCheckout,
  pollAndClaim,
  resetClaim,
} from '~/utils/checkout-client.mjs'

definePageMeta({ layout: 'login' })

const client = createCheckoutClient()
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const state = ref<'waiting' | 'ok' | 'claimed' | 'expired' | 'none' | 'failed' | 'cancelled' | 'error'>('waiting')
/* a checkout error code, rendered through the catalogue (spec 021) */
const errorCode = ref('')
const error = computed(() => {
  const k = checkoutErrorKey(errorCode.value)
  return k ? t(k.key, k.params) : ''
})
const retryable = ref(false)
const keyText = shallowRef('')
const tenantId = ref('')
const tenantUrl = ref('')
/* specs/022: the tenant host and whether it is provisioned yet */
const tenantHost = ref('')
const hostStatus = ref('')
const hostCheckoutId = ref('')
let stopped = false
let checkoutId = ''

async function run() {
  const { id, token } = loadCheckout()
  checkoutId = id
  if (!id) {
    state.value = 'none'
    return
  }
  state.value = 'waiting'
  const out = await pollAndClaim(client, { id, token }, { isStopped: () => stopped })
  if (stopped || out.state === 'stopped') return
  if (out.state === 'ok') {
    const r = out.result
    keyText.value = String(r.root_private_key || '')
    tenantId.value = String(r.tenant_id || '')
    tenantUrl.value = String(r.tenant_url || '')
    tenantHost.value = String(r.tenant_host || '')
    hostStatus.value = String(r.host_status || '')
    hostCheckoutId.value = checkoutId
    state.value = 'ok'
    return
  }
  if (out.state === 'claimed' || out.state === 'expired' || out.state === 'failed' || out.state === 'cancelled') {
    state.value = out.state
    return
  }
  const code = out.state === 'error' ? out.error : 'unavailable'
  errorCode.value = code
  // A lost connection or a 5xx may be retried by a click; a wrong / missing token may not.
  retryable.value = !['not_found', 'no_token', 'conflict'].includes(code)
  state.value = 'error'
}

async function retry() {
  retryable.value = false
  await resetClaim(checkoutId)
  await run()
}

onMounted(run)
onBeforeUnmount(() => {
  stopped = true
  keyText.value = ''
})
</script>
