<!-- /checkout/success — where payment returns the browser (spec 006 T021w,
     contracts/checkout-v1.md §2.3–§2.4). Reads checkout_id + claim_token from
     sessionStorage (never the URL), polls GET /checkout/{id} until paid, then
     POSTs /claim ONCE (claimOnce: one POST per checkout per page load, shared
     by overlapping polls and re-mounts). The root private key lives only in
     this component's memory: shown once with copy + download, cleared when the
     page is left. 410 / claimed → "already claimed". -->
<template>
  <div class="login-card" data-test="checkout-success" :data-claim-state="state">
    <h1>Your spool</h1>
    <p v-if="state === 'waiting'" class="muted" role="status" data-test="checkout-waiting">Waiting for the payment to be confirmed…</p>
    <template v-else-if="state === 'ok'">
      <p class="login-error" role="alert" data-test="checkout-key-warning">
        This is the only time we show this key. It was {{ emailed ? 'also emailed to you' : 'NOT emailed — save it now' }}.
        Save it as a file readable only by you (mode 0600) and point <code>SPOOL_TENANT_ROOT_KEY</code> at it.
      </p>
      <p>Tenant: <a :href="tenantUrl" rel="noopener" data-test="checkout-tenant-url">{{ tenantUrl }}</a></p>
      <pre class="checkout__key" data-test="checkout-key">{{ keyText }}</pre>
      <div class="checkout__actions">
        <button class="btn" type="button" data-test="checkout-key-copy" @click="copyKey">{{ copied ? 'Copied' : 'Copy key' }}</button>
        <button class="btn ghost" type="button" data-test="checkout-key-download" @click="downloadKey">Download key</button>
      </div>
    </template>
    <p v-else-if="state === 'claimed'" role="status" data-test="checkout-claimed">
      This key was already shown once and the hub no longer has it. Look for it in the email we sent.
    </p>
    <p v-else-if="state === 'none'" class="login-error" role="alert" data-test="checkout-none">
      This browser tab holds no checkout. Open this page in the tab you paid from.
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
import {
  checkoutErrorMessage,
  createCheckoutClient,
  keyFileName,
  loadCheckout,
  pollAndClaim,
  resetClaim,
} from '~/utils/checkout-client.mjs'

definePageMeta({ layout: 'login' })

const client = createCheckoutClient()
const state = ref<'waiting' | 'ok' | 'claimed' | 'none' | 'failed' | 'cancelled' | 'error'>('waiting')
const error = ref('')
const retryable = ref(false)
const keyText = shallowRef('')
const tenantId = ref('')
const tenantUrl = ref('')
const emailed = ref(false)
const copied = ref(false)
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
    emailed.value = r.emailed === true
    state.value = 'ok'
    return
  }
  if (out.state === 'claimed' || out.state === 'failed' || out.state === 'cancelled') {
    state.value = out.state
    return
  }
  const code = out.state === 'error' ? out.error : 'unavailable'
  error.value = checkoutErrorMessage(code)
  // A lost connection or a 5xx may be retried by a click; a wrong / missing token may not.
  retryable.value = !['not_found', 'no_token'].includes(code)
  state.value = 'error'
}

async function retry() {
  retryable.value = false
  await resetClaim(checkoutId)
  await run()
}

async function copyKey() {
  try {
    await navigator.clipboard.writeText(keyText.value)
    copied.value = true
  } catch {
    copied.value = false
  }
}

function downloadKey() {
  const url = URL.createObjectURL(new Blob([keyText.value + '\n'], { type: 'application/octet-stream' }))
  const a = document.createElement('a')
  a.href = url
  a.download = keyFileName(tenantId.value)
  a.rel = 'noopener'
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 0)
}

onMounted(run)
onBeforeUnmount(() => {
  stopped = true
  keyText.value = ''
})
</script>

<style scoped>
.checkout__key {
  margin: 12px 0;
  padding: 8px;
  border: 1px solid var(--color-border);
  border-radius: 6px;
  background: var(--color-composer);
  color: var(--color-fg);
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  font-size: 12px;
  user-select: all;
}
.checkout__actions { display: flex; gap: 8px; flex-wrap: wrap; }
</style>
