<!-- /settings → /settings/profile (specs/023 §3.4), locale prefix kept.
     SPL-993: not on a phone (<= 820 px), where /settings IS the list of
     sections (pages/settings.vue); widening past 820 px redirects then. -->
<template>
  <p v-if="!listed" class="muted">{{ t('common.loading') }}</p>
</template>

<script setup lang="ts">
import { DEFAULT_SETTINGS_SECTION } from '~/utils/settings-nav.mjs'
import { MOBILE_STACK_QUERY } from '~/utils/mobile-stack.mjs'

const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })
const toDefault = () => navigateTo(localePath('/settings/' + DEFAULT_SETTINGS_SECTION), { replace: true })
const mq = import.meta.client ? window.matchMedia(MOBILE_STACK_QUERY) : null
const listed = ref(Boolean(mq?.matches))
if (!listed.value) await toDefault()
const onWiden = (e: MediaQueryListEvent) => { if (!e.matches) void toDefault() }
onMounted(() => mq?.addEventListener('change', onWiden))
onUnmounted(() => mq?.removeEventListener('change', onWiden))
</script>
