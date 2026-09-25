<!-- Settings → Appearance (the theme and the font size; specs/023 §3.4; the
     "Debug pane" checkbox, CLE-34963). -->
<template>
  <SettingsSection id="settings-appearance" :title="t('settings.appearance')" data-test="settings-appearance">
    <div class="settings__row">
      <span>{{ t('settings.theme') }}</span>
      <ThemeToggle />
    </div>
    <FontSizeSetting />
    <DebugPaneSetting />
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import FontSizeSetting from '~/components/FontSizeSetting.vue'
import DebugPaneSetting from '~/components/DebugPaneSetting.vue'

const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
.settings__row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
  min-height: var(--tap, 44px);
}
</style>
