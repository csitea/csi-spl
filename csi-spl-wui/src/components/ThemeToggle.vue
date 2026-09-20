<!-- Icon-only theme toggle (GRK-3374). Shows the theme you would switch TO:
     sun in dark, half-moon in light. Accessible name on aria-label + title. -->
<template>
  <button
    type="button"
    class="icon-btn theme-toggle"
    data-test="theme-toggle"
    :aria-label="label"
    :title="label"
    :aria-pressed="theme === 'dark' ? 'true' : 'false'"
    @click="toggle"
  >
    <UiIcon :name="icon" :size="18" />
  </button>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { useTheme } from '~/composables/useTheme'
import { iconForTheme, labelKeyForTheme } from '~/utils/theme.mjs'
import type { UiIconName } from '@/utils/uiIcons'

const { theme, toggle } = useTheme()
const { t } = useI18n({ useScope: 'global' })
const icon = computed<UiIconName>(() => iconForTheme(theme.value) as UiIconName)
const label = computed(() => t(labelKeyForTheme(theme.value)))
</script>
