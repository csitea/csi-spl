<!-- SPL-959: a signed-in human on the host of a tenant they are not a member
     of - or (047 B5, `pending`) on the apex while their own tenant's host is
     still being provisioned after the payment. The hub answers every read 403 not_member, so nothing of that tenant
     is shown; this says why, and offers their own tenant's host. Set by
     plugins/tenant-host.client.ts. -->
<template>
  <div v-if="state.tenant" class="tenant-not-member" role="alertdialog" aria-modal="true" data-test="tenant-not-member">
    <div class="tenant-not-member__card">
      <!-- 047 B5: a paid tenant's host is still being provisioned; the boot hop retries -->
      <p v-if="state.pending" role="status" data-test="tenant-host-preparing" :data-host="state.pending">{{ t('tenant_host.preparing', { host: state.pending }) }}</p>
      <p v-else>{{ t('tenant_host.not_member', { tenant: state.tenant }) }}</p>
      <a v-if="state.home && !state.pending" class="btn" :href="state.home" data-test="tenant-not-member-home">{{ t('tenant_host.open_mine') }}</a>
    </div>
  </div>
</template>

<script setup lang="ts">
const state = useState<{ tenant: string, home: string, pending?: string }>('tenant-host-not-member', () => ({ tenant: '', home: '', pending: '' }))
const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
.tenant-not-member {
  position: fixed;
  inset: 0;
  z-index: var(--z-overlay);
  display: grid;
  place-items: center;
  padding: 1rem;
  background: var(--color-bg);
}
.tenant-not-member__card {
  max-width: 32rem;
  text-align: center;
}
</style>
