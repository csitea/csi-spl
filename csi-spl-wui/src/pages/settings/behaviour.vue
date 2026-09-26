<!-- Settings → Behaviour (SPL-976, specs/023 §3.7): how the app reacts to the
     keyboard. "Text fields" decides what Enter does in every multi-line
     field (composer, replies, issue comments and descriptions). -->
<template>
  <SettingsSection id="settings-behaviour" :title="t('settings.behaviour')" data-test="settings-behaviour">
    <SubmitKeySetting />
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import SubmitKeySetting from '~/components/SubmitKeySetting.vue'

const { t } = useI18n({ useScope: 'global' })
</script>
