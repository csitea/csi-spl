<!-- /checkout — buy a tenant (spec 006 T021w, contracts/checkout-v1.md 1.1 §2.1–§2.2).
     GET plan → price + rail (checkoutMode):
       fake        → the form POSTs {tenant_id, email}; checkout_id + claim_token
                     go to sessionStorage (never a URL); "Pay (dev fake)", then
                     /checkout/success,
       none        → "not on sale" (rail=none or available=false),
       unsupported → the card rail has no payment step in this page yet: no
                     form, so no checkout holds a slug it cannot pay for. -->
<template>
  <div class="login-card" data-test="checkout" :data-checkout-state="state" :data-rail="rail">
    <h1>{{ t('checkout.title') }}</h1>
    <p v-if="state === 'loading'" class="muted">{{ t('checkout.loading') }}</p>
    <p v-else-if="state === 'unavailable'" class="login-error" role="alert" data-test="checkout-unavailable">{{ error }}</p>
    <p v-else-if="mode === 'none'" role="status" data-test="checkout-not-on-sale">{{ t('checkout.not_on_sale') }}</p>
    <p v-else-if="mode === 'unsupported'" role="status" data-test="checkout-unsupported">{{ t('checkout.unsupported') }}</p>
    <template v-else>
      <i18n-t keypath="checkout.price" tag="p" scope="global" data-test="checkout-price">
        <template #price><strong>{{ price }}</strong></template>
      </i18n-t>
      <form v-if="state === 'form'" class="checkout__form" novalidate @submit.prevent="submit">
        <label class="checkout__field">
          <span>{{ t('checkout.tenant_name') }}</span>
          <input v-model.trim="tenant" type="text" autocomplete="off" autocapitalize="off" spellcheck="false" required data-test="checkout-tenant">
          <small v-if="tenantPreview" class="muted">{{ tenantPreview }}</small>
        </label>
        <label class="checkout__field">
          <span>{{ t('checkout.email') }}</span>
          <input v-model.trim="email" type="email" autocomplete="email" required data-test="checkout-email">
        </label>
        <p v-if="error" class="login-error" role="alert" data-test="checkout-error">{{ error }}</p>
        <button class="btn" type="submit" :disabled="busy" data-test="checkout-submit">{{ t('checkout.submit') }}</button>
      </form>
      <div v-else-if="state === 'fake'" class="checkout__form">
        <p class="muted">{{ t('checkout.fake_note') }}</p>
        <p v-if="error" class="login-error" role="alert" data-test="checkout-error">{{ error }}</p>
        <button class="btn" type="button" :disabled="busy" data-test="checkout-fake-pay" @click="fakePay">{{ t('checkout.fake_pay') }}</button>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import {
  checkoutErrorKey,
  createCheckoutClient,
  forgetCheckout,
  checkoutMode,
  formatPrice,
  saveCheckout,
} from '~/utils/checkout-client.mjs'
import { validTenant } from '~/utils/tenant.mjs'

definePageMeta({ layout: 'login' })

const router = useRouter()
const { t, locale } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const client = createCheckoutClient()
const state = ref<'loading' | 'unavailable' | 'form' | 'fake'>('loading')
const rail = ref('')
const mode = ref<'fake' | 'none' | 'unsupported'>('none')
/* the plan's raw amount: formatted in the ACTIVE locale, so a language switch re-renders it */
const plan = ref<{ cents: unknown, currency: unknown } | null>(null)
const price = computed(() => (plan.value ? formatPrice(plan.value.cents, plan.value.currency, locale.value) : ''))
const pattern = ref('')
const tenant = ref('')
const email = ref('')
/* a checkout error code, rendered through the catalogue (spec 021) */
const errorCode = ref('')
const error = computed(() => {
  const k = checkoutErrorKey(errorCode.value)
  return k ? t(k.key, k.params) : ''
})
const busy = ref(false)
const checkoutId = ref('')

const tenantPreview = computed(() =>
  tenant.value && pattern.value && validTenant(tenant.value) ? pattern.value.replace('{tenant}', tenant.value) : '')

onMounted(async () => {
  const out = await client.plan()
  if (!out.ok || !out.data) {
    state.value = 'unavailable'
    errorCode.value = out.error === 'network' ? 'network' : 'payment_unavailable'
    return
  }
  rail.value = String(out.data.rail || 'none')
  mode.value = checkoutMode(out.data)
  plan.value = { cents: out.data.amount_cents, currency: out.data.currency }
  pattern.value = String(out.data.tenant_url_pattern || '')
  state.value = 'form'
})

async function submit() {
  if (busy.value || mode.value !== 'fake') return
  errorCode.value = ''
  if (!validTenant(tenant.value)) {
    errorCode.value = 'bad_tenant_id'
    return
  }
  busy.value = true
  try {
    forgetCheckout()
    const out = await client.start({ tenant_id: tenant.value, email: email.value })
    if (!out.ok || !out.data) {
      errorCode.value = out.error
      return
    }
    // §1.2: keep id + token BEFORE leaving the page; without them the key is lost
    if (!saveCheckout(out.data)) {
      errorCode.value = 'storage_blocked'
      return
    }
    checkoutId.value = String(out.data.checkout_id || '')
    if (String(out.data.rail || rail.value) === 'fake') {
      state.value = 'fake'
      return
    }
    errorCode.value = 'payment_unavailable'
  } finally {
    busy.value = false
  }
}

async function fakePay() {
  if (busy.value) return
  busy.value = true
  errorCode.value = ''
  try {
    const out = await client.fakePay(checkoutId.value)
    if (!out.ok) {
      errorCode.value = out.error
      return
    }
    await router.push(localePath('/checkout/success'))
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.checkout__form { display: grid; gap: 10px; margin-top: 12px; min-width: 0; }
.checkout__field { display: grid; gap: 4px; font-size: 13px; color: var(--color-muted); min-width: 0; }
.checkout__field input {
  min-width: 0;
  max-width: 100%;
  box-sizing: border-box;
  background: var(--color-composer);
  border: 1px solid var(--color-border);
  color: var(--color-fg);
  border-radius: 6px;
  padding: 6px 8px;
  min-height: var(--tap);
}
.checkout__field small { overflow-wrap: anywhere; }
</style>
