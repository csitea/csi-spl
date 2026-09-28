<!-- /tenant-settings -> its first section the caller may open (specs/046),
     locale prefix kept. Not on a phone (<= 820 px), where /tenant-settings IS
     the list of sections; widening past 820 px redirects then. -->
<template>
  <p v-if="!listed" class="muted">{{ t('common.loading') }}</p>
</template>

<script setup lang="ts">
import { MOBILE_STACK_QUERY } from '~/utils/mobile-stack.mjs'
import { tenantSettingsSections } from '~/utils/tenant-settings-nav.mjs'
import { useAccessStore } from '~/stores/access'
import { useSpoolApi } from '~/composables/useSpoolApi'

const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })
const access = useAccessStore()
const api = useSpoolApi()
const mq = import.meta.client ? window.matchMedia(MOBILE_STACK_QUERY) : null
const listed = ref(Boolean(mq?.matches))
async function toFirst() {
  await access.load()
  const first = tenantSettingsSections(access.me, { mock: api.mock })[0]
  if (first) await navigateTo(localePath('/tenant-settings/' + first.id), { replace: true })
  else listed.value = true
}
if (!listed.value && import.meta.client) void toFirst()
const onWiden = (e: MediaQueryListEvent) => { if (!e.matches) void toFirst() }
onMounted(() => mq?.addEventListener('change', onWiden))
onUnmounted(() => mq?.removeEventListener('change', onWiden))
</script>
