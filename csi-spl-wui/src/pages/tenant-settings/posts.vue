<!-- Tenant settings -> Posts (spec 090 section 22, SPL-5240): the
     workspace's own marketing posts, written here and published by their
     author on the connected accounts. The editor is MarketingPostEditor.vue.
     tenant.settings (admin, biz_owner). -->
<template>
  <SettingsSection id="tenant-posts-section" :title="t('tenant_settings.posts_title')" data-test="tenant-settings-posts">
    <p v-if="denied" class="muted" role="alert" data-test="tenant-section-forbidden">{{ t('tenant_settings.forbidden') }}</p>
    <MarketingPostEditor v-else-if="allowed" />
    <p v-else class="muted">{{ t('common.loading') }}</p>
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import MarketingPostEditor from '~/components/MarketingPostEditor.vue'
import { useTenantSectionGate } from '~/composables/useTenantSectionGate'

const { t } = useI18n({ useScope: 'global' })
const { allowed, denied } = useTenantSectionGate('posts')
</script>
