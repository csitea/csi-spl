<!-- /settings → /settings/profile (specs/023 §3.4), locale prefix kept. -->
<template>
  <p class="muted">{{ t('common.loading') }}</p>
</template>

<script setup lang="ts">
import { DEFAULT_SETTINGS_SECTION } from '~/utils/settings-nav.mjs'

const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })
await navigateTo(localePath('/settings/' + DEFAULT_SETTINGS_SECTION), { replace: true })
</script>
