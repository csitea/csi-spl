<!-- /checkout/claim#checkout=<id>&token=<t> — the link in the one email
     (checkout-v1 1.2 §1.8, §2.5; 017 T008 / SEC-03). The token rides in the
     URL FRAGMENT, so no server or proxy log sees it. This page reads it once,
     clears it from the address bar (history.replaceState) BEFORE any request,
     keeps it only in a local variable, and POSTs /claim ONCE (claimOnce). The
     key is rendered exactly like the success page and lives only in memory. -->
<template>
  <div class="login-card" data-test="checkout-claim" :data-claim-state="state">
    <h1>Your spool</h1>
    <p v-if="state === 'claiming'" class="muted" role="status" data-test="checkout-claiming">Collecting your key…</p>
    <CheckoutKeyReveal v-else-if="state === 'ok'" :key-text="keyText" :tenant-url="tenantUrl" :tenant-id="tenantId" />
    <p v-else-if="state === 'claimed'" role="status" data-test="checkout-claimed">
      This key was already collected — on the success page or from this link. The hub does not keep it.
    </p>
    <p v-else-if="state === 'expired'" class="login-error" role="alert" data-test="checkout-expired">
      This link has expired — contact support to re-key the tenant.
    </p>
    <p v-else-if="state === 'bad_link'" class="login-error" role="alert" data-test="checkout-bad-link">
      This link is incomplete — open the link from the email again.
    </p>
    <template v-else-if="state === 'error'">
      <p class="login-error" role="alert" data-test="checkout-claim-error">{{ error }}</p>
      <button v-if="retryable" class="btn" type="button" data-test="checkout-claim-retry" @click="retry">Try again</button>
    </template>
  </div>
</template>

<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, shallowRef } from 'vue'
import CheckoutKeyReveal from '~/components/CheckoutKeyReveal.vue'
import {
  checkoutErrorMessage,
  claimOnce,
  createCheckoutClient,
  readClaimFragment,
  resetClaim,
} from '~/utils/checkout-client.mjs'

// scrollToTop: false makes Nuxt's scrollBehavior return before it reads
// to.hash. Otherwise vue-router treats "#checkout=…&token=…" as a CSS selector
// and, in dev, prints the token in a console warning (measured 2026-09-19).
definePageMeta({ layout: 'login', scrollToTop: false })

const client = createCheckoutClient()
const state = ref<'claiming' | 'ok' | 'claimed' | 'expired' | 'bad_link' | 'error'>('claiming')
const error = ref('')
const retryable = ref(false)
const keyText = shallowRef('')
const tenantId = ref('')
const tenantUrl = ref('')
// deliberately NOT reactive: the link token never reaches a template, devtools or a store
let link = { id: '', token: '' }
let left = false

/** Read the fragment and wipe it from the address bar and history entry. */
function takeFragment() {
  link = readClaimFragment(window.location.hash)
  if (window.location.hash) {
    window.history.replaceState(window.history.state, '', window.location.pathname + window.location.search)
  }
}

async function claim() {
  if (!link.id) {
    state.value = 'bad_link'
    return
  }
  state.value = 'claiming'
  const out = await claimOnce(client, link)
  if (left) return
  if (out.state === 'ok') {
    const r = out.result
    keyText.value = String(r.root_private_key || '')
    tenantId.value = String(r.tenant_id || '')
    tenantUrl.value = String(r.tenant_url || '')
    link = { id: '', token: '' }
    state.value = 'ok'
    return
  }
  if (out.state === 'claimed' || out.state === 'expired') {
    link = { id: '', token: '' }
    state.value = out.state
    return
  }
  const code = out.state === 'error' ? out.error : 'unavailable'
  error.value = checkoutErrorMessage(code === 'not_found' ? 'bad_link' : code)
  // a lost connection or a 5xx may be retried by a click; a wrong link, a
  // conflict or an unpaid checkout may not
  retryable.value = !['not_found', 'conflict', 'not_paid'].includes(code)
  state.value = 'error'
}

async function retry() {
  retryable.value = false
  await resetClaim(link.id)
  await claim()
}

onMounted(() => {
  takeFragment()
  void claim()
})
onBeforeUnmount(() => {
  left = true
  link = { id: '', token: '' }
  keyText.value = ''
})
</script>
