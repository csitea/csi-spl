<!-- /checkout/private-workspace — order a private workspace and its private VM
     (spec 181 4.1, row B3). An ORDER form, no card field and no payment step
     [Q-18 C]: the submit (B2, POST /api/v1/checkout/private-workspace)
     creates the workspace at once; the invoice comes monthly in arrears, paid
     by bank transfer [Q-9 B, Q-16 B, Q-19 A]. The price lines are the seats
     (9 EUR per human member per month, Q-6 A, Q-7 A) and the VM's cloud cost
     + 33 % (Q-8 A, Q-11 A); never a token line: we never resell tokens
     [Q-10 A, P5]. The submit goes to the api host with credentials, as the
     auth calls do (useAuthBase); on dev/prd it waits for credentialed CORS on
     the route (an api row, not B3). The e2e checkout-private-workspace.test.mjs holds both. -->
<template>
  <div class="login-card" data-test="pw-order" :data-pw-state="state">
    <h1>{{ t('checkout_private.title') }}</h1>
    <p class="muted">{{ t('checkout_private.intro') }}</p>
    <section class="pw__lines" data-test="pw-price-lines" :aria-label="t('checkout_private.lines_title')">
      <h2 class="pw__h2">{{ t('checkout_private.lines_title') }}</h2>
      <ul>
        <li data-test="pw-line" data-line="seat_member">
          {{ t('checkout_private.line_seat', { seats: seatsShown, price: seatPrice, total: seatsTotal }) }}
          <small class="muted">{{ t('checkout_private.line_seat_note') }}</small>
        </li>
        <li data-test="pw-line" data-line="vm_cost">{{ t('checkout_private.line_vm', { pct: plan.vmMarginPct }) }}</li>
      </ul>
      <p data-test="pw-invoice">{{ t('checkout_private.invoice', { pct: plan.vmMarginPct }) }}</p>
      <p class="muted" data-test="pw-root">{{ t('checkout_private.root') }}</p>
      <p class="muted" data-test="pw-agents">{{ t('checkout_private.agents') }}</p>
    </section>
    <div v-if="state === 'done'" class="pw__form" role="status" data-test="pw-done">
      <p>{{ t(replayed ? 'checkout_private.done_replayed' : 'checkout_private.done', { tenant: doneTenant }) }}</p>
      <a v-if="doneUrl" class="btn" :href="doneUrl" data-test="pw-open">{{ t('checkout_private.done_open') }}</a>
    </div>
    <form v-else class="pw__form" novalidate data-test="pw-form" @submit.prevent="submit">
      <label class="pw__field">
        <span>{{ t('checkout_private.tenant_name') }}</span>
        <input v-model.trim="form.tenant" type="text" autocomplete="off" autocapitalize="off" spellcheck="false" required data-test="pw-tenant">
      </label>
      <label class="pw__field">
        <span>{{ t('checkout_private.seats') }}</span>
        <input v-model.number="form.seats" type="number" min="1" step="1" inputmode="numeric" required data-test="pw-seats">
      </label>
      <label class="pw__field">
        <span>{{ t('checkout_private.billing_name') }}</span>
        <input v-model.trim="form.name" type="text" autocomplete="organization" required data-test="pw-billing-name">
      </label>
      <label class="pw__field">
        <span>{{ t('checkout_private.billing_address') }}</span>
        <textarea v-model.trim="form.address" rows="3" autocomplete="street-address" required data-test="pw-billing-address" />
      </label>
      <label class="pw__field">
        <span>{{ t('checkout_private.billing_country') }}</span>
        <input v-model.trim="form.country" type="text" maxlength="2" autocomplete="country" autocapitalize="characters" required data-test="pw-billing-country">
      </label>
      <label class="pw__field">
        <span>{{ t('checkout_private.billing_vat') }}</span>
        <input v-model.trim="form.vatId" type="text" autocomplete="off" data-test="pw-billing-vat">
      </label>
      <p v-if="error" class="login-error" role="alert" data-test="pw-error">
        {{ error }}
        <NuxtLink v-if="errorCode === 'unauthorized'" :to="localePath('/login')" data-test="pw-sign-in">{{ t('checkout_private.sign_in') }}</NuxtLink>
      </p>
      <button class="btn" type="submit" :disabled="busy" data-test="pw-submit">{{ t('checkout_private.submit') }}</button>
    </form>
  </div>
</template>

<script setup lang="ts">
import { computed, reactive, ref } from 'vue'
import { formatPrice } from '~/utils/checkout-client'
import { validTenant } from '~/utils/tenant.mjs'
import { useAuthBase } from '~/composables/useAuthClient'
import {
  PRIVATE_VM_PLAN,
  orderBody,
  orderErrorKey,
  orderInvalid,
  planFromAnswer,
  seatCount,
  seatsMonthCents,
  submitOrder,
} from '~/utils/private-workspace-order.mjs'

definePageMeta({ layout: 'login' })

const { t, locale } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
/* the api host with credentials, as the auth calls (authCORS); '' = same-origin, the lde devProxy */
const orderBase = useAuthBase()
const state = ref<'form' | 'done'>('form')
const busy = ref(false)
const errorCode = ref('')
const error = computed(() => {
  const k = orderErrorKey(errorCode.value)
  return k ? t(k) : ''
})
const form = reactive({ tenant: '', seats: 1, name: '', address: '', country: '', vatId: '' })
/* the B1 plan: the WUI copy until the submit answers with the hub's own values */
const plan = ref<{ currency: string, seatMemberCents: number, vmMarginPct: number }>({ ...PRIVATE_VM_PLAN })
const seatsShown = computed(() => seatCount(form.seats) || 1)
const seatPrice = computed(() => formatPrice(plan.value.seatMemberCents, plan.value.currency, locale.value))
const seatsTotal = computed(() => formatPrice(seatsMonthCents(seatsShown.value, plan.value), plan.value.currency, locale.value))
const doneTenant = ref('')
const doneUrl = ref('')
const replayed = ref(false)

/** Only an https URL the hub gave is a link (never a javascript: or relative one). */
function safeUrl(u: unknown): string {
  const s = String(u || '')
  return /^https:\/\/[a-z0-9.-]+(:\d+)?(\/\S*)?$/i.test(s) ? s : ''
}

async function submit() {
  if (busy.value) return
  errorCode.value = ''
  const body = orderBody({ ...form, locale: locale.value })
  const bad = orderInvalid(body, validTenant)
  if (bad) {
    errorCode.value = bad
    return
  }
  busy.value = true
  try {
    const out = await submitOrder(body, { base: orderBase })
    if (!out.ok || !out.data) {
      errorCode.value = out.error || 'generic'
      return
    }
    plan.value = planFromAnswer(out.data)
    doneTenant.value = String(out.data.tenant_id || body.tenant_id)
    doneUrl.value = safeUrl(out.data.tenant_url)
    replayed.value = out.data.replayed === true
    state.value = 'done'
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.pw__h2 { font-size: 0.9375rem; margin: 12px 0 4px; }
.pw__lines ul { margin: 0; padding-left: 18px; display: grid; gap: 4px; }
.pw__lines small { display: block; }
.pw__lines p { overflow-wrap: anywhere; }
.pw__form { display: grid; gap: 10px; margin-top: 12px; min-width: 0; }
.pw__field { display: grid; gap: 4px; font-size: 0.8125rem; color: var(--color-muted); min-width: 0; }
.pw__field input, .pw__field textarea {
  min-width: 0;
  max-width: 100%;
  box-sizing: border-box;
  background: var(--color-composer);
  border: 1px solid var(--color-border);
  color: var(--color-fg);
  border-radius: var(--radius-sm);
  padding: 6px 8px;
  min-height: var(--tap);
  font: inherit;
}
</style>
