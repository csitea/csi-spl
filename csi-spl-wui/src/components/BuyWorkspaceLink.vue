<!-- "Buy a workspace" (047 W2): the one way in to /checkout from the pages a
     stranger lands on. The link is static, so the prerendered documents carry
     it; with-price asks GET /checkout/plan after mount and adds the price line
     only while the plan is on sale (checkoutMode fake | card), never on the
     mock tenant. -->
<template>
  <p class="buy-workspace muted" data-test="buy-workspace">
    <NuxtLink :to="localePath('/checkout')" data-test="buy-workspace-link">{{ t('checkout.buy.link') }}</NuxtLink>
    <template v-if="price">
      · <span data-test="buy-workspace-price">{{ t('checkout.price', { price }) }}</span>
    </template>
  </p>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useSpoolApi } from '~/composables/useSpoolApi'

const props = defineProps<{ withPrice?: boolean }>()
const { t, locale } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const plan = ref<{ cents: unknown, currency: unknown } | null>(null)
const fmt = ref<((c: unknown, cur: unknown, loc: string) => string) | null>(null)
const price = computed(() => (plan.value && fmt.value ? fmt.value(plan.value.cents, plan.value.currency, locale.value) : ''))

onMounted(async () => {
  /* the mock tenant has no hub to price it (and a 404 is a console error) */
  if (!props.withPrice || useSpoolApi().mock) return
  try {
    /* loaded on demand: the sign-in page's first download stays as it was */
    const { createCheckoutClient, checkoutMode, formatPrice } = await import('~/utils/checkout-client.mjs')
    const out = await createCheckoutClient().plan()
    if (!out.ok || !out.data || !['fake', 'card'].includes(checkoutMode(out.data))) return
    fmt.value = formatPrice
    plan.value = { cents: out.data.amount_cents, currency: out.data.currency }
  } catch {
    /* no hub, no price: the link alone still leads to the plan */
  }
})
</script>

<style scoped>
.buy-workspace {
  margin-top: 16px;
}
</style>
