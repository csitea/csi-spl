<!-- Settings → Appearance (the theme and the font size; specs/023 §3.4; the
     "Debug pane" checkbox). -->
<template>
  <SettingsSection id="settings-appearance" :title="t('settings.appearance')" data-test="settings-appearance">
    <div class="settings__row">
      <span>{{ t('settings.theme') }}</span>
      <ThemeToggle align="end" />
    </div>
    <FontSizeSetting />
    <div class="settings__row" data-test="list-clip-default">
      <span id="list-clip-label">{{ t('feed.clip.label') }}</span>
      <div class="list-clip" role="radiogroup" aria-labelledby="list-clip-label">
        <label v-for="m in CARD_CLIP_MODES" :key="m" class="list-clip__opt" :class="{ 'list-clip__opt--on': clipDefault === m }">
          <input
            type="radio"
            name="list-clip-default"
            :value="m"
            :checked="clipDefault === m"
            :data-test="`list-clip-${m}`"
            @change="setClipDefault(m)"
          />
          {{ t('feed.clip.mode.' + m) }}
        </label>
      </div>
    </div>
    <DebugPaneSetting />
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import FontSizeSetting from '~/components/FontSizeSetting.vue'
import DebugPaneSetting from '~/components/DebugPaneSetting.vue'
import { useCardClipDefault } from '~/composables/useCardClip'
import { CARD_CLIP_MODES } from '~/utils/card-clip.mjs'

const { t } = useI18n({ useScope: 'global' })
const { mode: clipDefault, setDefault: setClipDefault } = useCardClipDefault()
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
.list-clip { display: flex; gap: 8px; flex-wrap: wrap; }
.list-clip__opt {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-height: var(--tap, 44px);
}
.list-clip__opt--on { color: var(--color-accent); }
</style>
