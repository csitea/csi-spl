<!-- Settings → Keys (specs/023 §3.1-3.3). -->
<template>
  <SettingsSection id="settings-keys" :title="t('settings.keys_title')" data-test="settings-keys">
    <ClientOnly>
      <KeysSetting />
    </ClientOnly>
  </SettingsSection>
</template>

<script setup lang="ts">
import KeysSetting from '~/components/KeysSetting.vue'
import SettingsSection from '~/components/SettingsSection.vue'

const { t } = useI18n({ useScope: 'global' })
</script>
