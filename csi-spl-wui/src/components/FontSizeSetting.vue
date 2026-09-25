<!-- Font size (CLE-3495, specs/023 §3.4 Appearance). Five levels as a real
     radiogroup — native radios in one named group, so arrow keys move between
     them — flanked by − (one level smaller) and + (one level bigger), each
     disabled at its end. The level lives on <html data-font-size> and in this
     browser's storage (utils/font-size.mjs); every text size is rem, so the
     whole app follows. The "A" samples are fixed px on purpose: they show the
     five sizes side by side whatever the current level is. -->
<template>
  <div class="font-size" data-test="font-size-setting">
    <span id="font-size-label">{{ t('settings.font_size.label') }}</span>
    <div class="font-size__ctl">
      <button
        type="button"
        class="icon-btn"
        data-test="font-size-smaller"
        :aria-label="t('settings.font_size.smaller')"
        :title="t('settings.font_size.smaller')"
        :disabled="!canShrinkFont(level)"
        @click="step(-1)"
      >
        <UiIcon name="minus" :size="18" />
      </button>
      <div class="font-size__levels" role="radiogroup" aria-labelledby="font-size-label" data-test="font-size-levels">
        <label
          v-for="n in FONT_SIZE_LEVELS"
          :key="n"
          class="font-size__level"
          :class="{ 'font-size__level--on': level === n }"
          :title="levelLabel(n)"
        >
          <input
            type="radio"
            name="spool-font-size"
            :value="n"
            :checked="level === n"
            :aria-label="levelLabel(n)"
            :data-test="`font-size-radio-${n}`"
            @change="setLevel(n)"
          />
          <span class="font-size__glyph" :class="`font-size__glyph--${n}`" aria-hidden="true">A</span>
        </label>
      </div>
      <button
        type="button"
        class="icon-btn"
        data-test="font-size-bigger"
        :aria-label="t('settings.font_size.bigger')"
        :title="t('settings.font_size.bigger')"
        :disabled="!canGrowFont(level)"
        @click="step(1)"
      >
        <UiIcon name="plus" :size="18" />
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useFontSize } from '~/composables/useFontSize'
import {
  canGrowFont,
  canShrinkFont,
  FONT_SIZE_DEFAULT,
  FONT_SIZE_LEVELS,
  FONT_SIZE_MAX,
} from '~/utils/font-size.mjs'

const { t } = useI18n({ useScope: 'global' })
const { level, setLevel, step } = useFontSize()

function levelLabel(n: number) {
  const key = n === FONT_SIZE_DEFAULT ? 'settings.font_size.level_default' : 'settings.font_size.level'
  return t(key, { n, total: FONT_SIZE_MAX })
}
</script>

<style scoped>
.font-size {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
  min-height: var(--tap, 44px);
}
.font-size__ctl {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
  min-width: 0;
}
.icon-btn:disabled {
  opacity: 0.4;
  cursor: not-allowed;
}
.font-size__levels {
  display: flex;
  align-items: flex-end;
  gap: 4px;
}
.font-size__level {
  display: inline-flex;
  flex-direction: column;
  align-items: center;
  justify-content: flex-end;
  gap: 2px;
  min-width: 36px;
  min-height: var(--tap, 44px);
  padding: 2px 4px;
  border: 1px solid transparent;
  border-radius: var(--radius-sm);
  cursor: pointer;
}
.font-size__level--on {
  border-color: var(--color-border-strong);
  background: var(--color-surface);
}
.font-size__level input {
  margin: 0;
  accent-color: var(--color-accent);
}
.font-size__level input:focus-visible {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: var(--focus-offset);
}
.font-size__glyph { line-height: 1; font-weight: 600; }
.font-size__glyph--1 { font-size: 14px; }
.font-size__glyph--2 { font-size: 16px; }
.font-size__glyph--3 { font-size: 18px; }
.font-size__glyph--4 { font-size: 20px; }
.font-size__glyph--5 { font-size: 22px; }
</style>
