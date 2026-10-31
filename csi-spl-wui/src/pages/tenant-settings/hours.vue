<!-- Tenant settings -> Hours (spec 107 section 4.2): the workspace's hours
     keys (period, grace days, idle gap, time zone) in their own section,
     moved out of General (owner: "General" is too general for it). The
     form, its load and its save are HoursSettings.vue's. tenant.settings. -->
<template>
  <SettingsSection id="tenant-hours-section" :title="t('tenant_settings.hours_title')" data-test="tenant-settings-hours">
    <p v-if="denied" class="muted" role="alert" data-test="tenant-section-forbidden">{{ t('tenant_settings.forbidden') }}</p>
    <HoursSettings v-else-if="allowed" />
    <p v-else class="muted">{{ t('common.loading') }}</p>
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import HoursSettings from '~/components/HoursSettings.vue'
import { useTenantSectionGate } from '~/composables/useTenantSectionGate'

const { t } = useI18n({ useScope: 'global' })
const { allowed, denied } = useTenantSectionGate('hours')
</script>
