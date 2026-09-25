<!-- The one-time root private key render shared by /checkout/success and
     /checkout/claim (checkout-v1 1.2 §2.4–§2.5). The parent owns the key (in
     memory only) and clears it when it is left; this component only shows it,
     copies it and offers it as a file. Nothing here stores or logs it. -->
<template>
  <div data-test="checkout-key-reveal">
    <p class="login-error" role="alert" data-test="checkout-key-warning">
      {{ t('checkout.key.warning_once') }}
      <i18n-t keypath="checkout.key.warning_save" tag="span" scope="global">
        <template #var><code>SPOOL_TENANT_ROOT_KEY</code></template>
      </i18n-t>
    </p>
    <i18n-t keypath="checkout.key.tenant" tag="p" scope="global">
      <template #id><strong>{{ tenantId }}</strong></template>
      <template #url><a :href="tenantUrl" rel="noopener" data-test="checkout-tenant-url">{{ tenantUrl }}</a></template>
    </i18n-t>
    <pre class="checkout-key__text" data-test="checkout-key">{{ keyText }}</pre>
    <div class="checkout-key__actions">
      <button class="btn" type="button" data-test="checkout-key-copy" @click="copyKey">{{ copied ? t('common.copied') : t('checkout.key.copy') }}</button>
      <button class="btn ghost" type="button" data-test="checkout-key-download" @click="downloadKey">{{ t('checkout.key.download') }}</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref } from 'vue'
import { keyFileName } from '~/utils/checkout-client.mjs'

const props = defineProps<{ keyText: string, tenantUrl: string, tenantId: string }>()
const { t } = useI18n({ useScope: 'global' })
const copied = ref(false)

async function copyKey() {
  try {
    await navigator.clipboard.writeText(props.keyText)
    copied.value = true
  } catch {
    copied.value = false
  }
}

function downloadKey() {
  const url = URL.createObjectURL(new Blob([props.keyText + '\n'], { type: 'application/octet-stream' }))
  const a = document.createElement('a')
  a.href = url
  a.download = keyFileName(props.tenantId)
  a.rel = 'noopener'
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 0)
}
</script>

<style scoped>
.checkout-key__text {
  margin: 12px 0;
  padding: 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-composer);
  color: var(--color-fg);
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  font-size: 0.75rem;
  user-select: all;
}
.checkout-key__actions { display: flex; gap: 8px; flex-wrap: wrap; }
</style>
