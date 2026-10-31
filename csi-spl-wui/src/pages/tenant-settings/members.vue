<!-- Tenant settings -> Members (specs/046 §4.2): the users CRUD - the same
     list and edit pane as /users (<TenantUsers embedded />). members.invite. -->
<template>
  <div data-test="tenant-settings-members">
    <p v-if="denied" class="muted" role="alert" data-test="tenant-section-forbidden">{{ t('tenant_settings.forbidden') }}</p>
    <TenantUsers v-else-if="allowed" embedded />
    <p v-else class="muted">{{ t('common.loading') }}</p>
  </div>
</template>

<script setup lang="ts">
import TenantUsers from '~/components/TenantUsers.vue'
import { useTenantSectionGate } from '~/composables/useTenantSectionGate'

const { t } = useI18n({ useScope: 'global' })
const { allowed, denied } = useTenantSectionGate('members')
</script>
