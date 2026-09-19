<!-- The tenant's own address after a purchase (specs/022). With no wildcard,
     <tenant>.<fqdn> is provisioned by a scheduled reconcile after the payment
     (Cloud Run domain mapping, DNS record, certificate; typically 15-30 min).
     While the hub reports host_status 'pending' this says the address is being
     prepared and polls GET /checkout/{id} (pollHostReady) until it is ready;
     'unknown' shows nothing. Shared by /checkout/success and /checkout/claim. -->
<template>
  <p v-if="status === 'pending'" class="muted" role="status" data-test="checkout-host-preparing" :data-host="host">
    {{ t('checkout.host.preparing', { host }) }}
  </p>
  <p v-else-if="status === 'ready' && waited" role="status" data-test="checkout-host-ready" :data-host="host">
    {{ t('checkout.host.ready', { host }) }}
  </p>
</template>

<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { createCheckoutClient, pollHostReady } from '~/utils/checkout-client.mjs'

const props = defineProps<{ checkoutId: string, host: string, initial: string }>()
const { t } = useI18n({ useScope: 'global' })
const status = ref(props.initial || 'unknown')
/* 'ready' is announced only after this page watched it flip from pending */
const waited = ref(false)
let stopped = false

onMounted(async () => {
  if (status.value !== 'pending' || !props.checkoutId) return
  waited.value = true
  status.value = await pollHostReady(createCheckoutClient(), props.checkoutId, { isStopped: () => stopped })
})
onBeforeUnmount(() => { stopped = true })
</script>
