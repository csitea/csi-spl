<!-- Settings → Appearance (the theme, the font size, the time zone (CLE-77908);
     specs/023 §3.4; the "Debug pane" checkbox). -->
<template>
  <SettingsSection id="settings-appearance" :title="t('settings.appearance')" data-test="settings-appearance">
    <div class="settings__row">
      <span>{{ t('settings.theme') }}</span>
      <ThemeToggle align="end" />
    </div>
    <FontSizeSetting />
    <TimeZoneSetting />
    <div class="settings__row" data-test="list-clip-default-msgs">
      <span id="list-clip-label-msgs">{{ t('feed.clip.pane.msgs') }}</span>
      <div class="list-clip" role="radiogroup" aria-labelledby="list-clip-label-msgs">
        <label v-for="m in CARD_CLIP_MODES" :key="'msgs-' + m" class="list-clip__opt" :class="{ 'list-clip__opt--on': clipMsgs === m }">
          <input
            type="radio"
            name="list-clip-default-msgs"
            :value="m"
            :checked="clipMsgs === m"
            :data-test="`list-clip-msgs-${m}`"
            @change="setClipMsgs(m)"
          />
          {{ t('feed.clip.mode.' + m) }}
        </label>
      </div>
    </div>
    <div class="settings__row" data-test="list-clip-default-thread">
      <span id="list-clip-label-thread">{{ t('feed.clip.pane.thread') }}</span>
      <div class="list-clip" role="radiogroup" aria-labelledby="list-clip-label-thread">
        <label v-for="m in CARD_CLIP_MODES" :key="'thread-' + m" class="list-clip__opt" :class="{ 'list-clip__opt--on': clipThread === m }">
          <input
            type="radio"
            name="list-clip-default-thread"
            :value="m"
            :checked="clipThread === m"
            :data-test="`list-clip-thread-${m}`"
            @change="setClipThread(m)"
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
import TimeZoneSetting from '~/components/TimeZoneSetting.vue'
import DebugPaneSetting from '~/components/DebugPaneSetting.vue'
import { useCardClipDefault } from '~/composables/useCardClip'
import { CARD_CLIP_MODES } from '~/utils/card-clip.mjs'

const { t } = useI18n({ useScope: 'global' })
const { mode: clipMsgs, setDefault: setClipMsgs } = useCardClipDefault('msgs')
const { mode: clipThread, setDefault: setClipThread } = useCardClipDefault('thread')
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
