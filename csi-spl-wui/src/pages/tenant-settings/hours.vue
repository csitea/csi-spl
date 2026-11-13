<!-- Tenant settings -> Hours (spec 107 section 4.2): the workspace's hours
     keys (period, grace days, idle gap, time zone) in their own section,
     moved out of General (owner: "General" is too general for it). The
     form, its load and its save are HoursSettings.vue's. tenant.settings.
     FR-41 (SPL-5440): the average hours per day, HoursNormSetting.vue, for a
     holder of hours.norm; the product owner holds it without
     tenant.settings and sees that field alone. -->
<template>
  <SettingsSection id="tenant-hours-section" :title="t('tenant_settings.hours_title')" data-test="tenant-settings-hours">
    <p v-if="denied" class="muted" role="alert" data-test="tenant-section-forbidden">{{ t('tenant_settings.forbidden') }}</p>
    <template v-else-if="allowed">
      <HoursNormSetting v-if="access.can(HOURS_NORM_PERM)" class="hours-norm" />
      <HoursSettings v-if="access.can('tenant.settings')" />
    </template>
    <p v-else class="muted">{{ t('common.loading') }}</p>
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import HoursSettings from '~/components/HoursSettings.vue'
import HoursNormSetting from '~/components/HoursNormSetting.vue'
import { useTenantSectionGate } from '~/composables/useTenantSectionGate'
import { useAccessStore } from '~/stores/access'
import { HOURS_NORM_PERM } from '~/utils/hours-norm.mjs'

const { t } = useI18n({ useScope: 'global' })
const access = useAccessStore()
const { allowed, denied } = useTenantSectionGate('hours')
</script>

<style scoped>
.hours-norm { margin-block-end: 20px; padding-block-end: 16px; border-block-end: 1px solid var(--color-border); }
</style>
