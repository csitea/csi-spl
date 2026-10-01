<!-- Settings → Language (CLE-3403's <LanguageSetting />, specs/023 §3.4). -->
<template>
  <SettingsSection id="settings-language" :title="t('settings.language_title')" data-test="settings-language">
    <LanguageSetting />
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'

const { t } = useI18n({ useScope: 'global' })
</script>
