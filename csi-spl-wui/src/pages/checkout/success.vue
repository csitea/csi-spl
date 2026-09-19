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
    <h1>Your spool</h1>
    <p v-if="state === 'waiting'" class="muted" role="status" data-test="checkout-waiting">Waiting for the payment to be confirmed…</p>
    <CheckoutKeyReveal v-else-if="state === 'ok'" :key-text="keyText" :tenant-url="tenantUrl" :tenant-id="tenantId" />
    <p v-else-if="state === 'claimed'" role="status" data-test="checkout-claimed">
      This key was already collected — on this page or from the emailed link. The hub does not keep it.
    </p>
    <p v-else-if="state === 'expired'" class="login-error" role="alert" data-test="checkout-expired">
      The claim window has closed — contact support to re-key the tenant.
    </p>
    <p v-else-if="state === 'none'" class="login-error" role="alert" data-test="checkout-none">
      This browser tab holds no checkout. Use the claim link from the email we sent.
    </p>
    <p v-else-if="state === 'failed' || state === 'cancelled'" class="login-error" role="alert" data-test="checkout-failed">
      The payment was {{ state === 'failed' ? 'not completed' : 'cancelled' }}. No spool was created.
    </p>
    <template v-else-if="state === 'error'">
      <p class="login-error" role="alert" data-test="checkout-claim-error">{{ error }}</p>
      <button v-if="retryable" class="btn" type="button" data-test="checkout-claim-retry" @click="retry">Try again</button>
    </template>
    <p><NuxtLink to="/checkout">Back to checkout</NuxtLink></p>
  </div>
</template>

<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, shallowRef } from 'vue'
import CheckoutKeyReveal from '~/components/CheckoutKeyReveal.vue'
import {
  checkoutErrorMessage,
  createCheckoutClient,
  loadCheckout,
  pollAndClaim,
  resetClaim,
} from '~/utils/checkout-client.mjs'

definePageMeta({ layout: 'login' })

const client = createCheckoutClient()
const state = ref<'waiting' | 'ok' | 'claimed' | 'expired' | 'none' | 'failed' | 'cancelled' | 'error'>('waiting')
const error = ref('')
const retryable = ref(false)
const keyText = shallowRef('')
const tenantId = ref('')
const tenantUrl = ref('')
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
    state.value = 'ok'
    return
  }
  if (out.state === 'claimed' || out.state === 'expired' || out.state === 'failed' || out.state === 'cancelled') {
    state.value = out.state
    return
  }
  const code = out.state === 'error' ? out.error : 'unavailable'
  error.value = checkoutErrorMessage(code)
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
