<template>
  <button
    class="theme-toggle"
    type="button"
    :aria-label="theme === 'dark' ? t('theme.to_light') : t('theme.to_dark')"
    @click="toggle"
  >
    {{ theme === 'dark' ? t('theme.light') : t('theme.dark') }}
  </button>
</template>

<script setup lang="ts">
import { useTheme } from '~/composables/useTheme'

const { theme, toggle } = useTheme()
const { t } = useI18n({ useScope: 'global' })
</script>
