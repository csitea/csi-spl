<!-- Settings → Behaviour (specs/023 §3.7, §3.8): "Text fields" decides what
     Enter does in every multi-line field (SPL-976); "Left panel order" is the
     order of the left-rail icons (SPL-979). -->
<template>
  <SettingsSection id="settings-behaviour" :title="t('settings.behaviour')" data-test="settings-behaviour">
    <SubmitKeySetting />
    <RailOrderSetting />
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import SubmitKeySetting from '~/components/SubmitKeySetting.vue'
import RailOrderSetting from '~/components/RailOrderSetting.vue'

const { t } = useI18n({ useScope: 'global' })
</script>
