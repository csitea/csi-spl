<template>
  <div class="door-prompt" data-testid="view-door">
    <p class="muted">{{ modes.token ? t('view_token.need_member_or_token') : t('view_token.need_member') }}</p>
    <p v-if="modes.session">
      <a class="btn" :href="href">{{ t('nav.login') }}</a>
    </p>
    <form v-if="modes.token" class="create-row" @submit.prevent="onSave">
      <input
        v-model="token"
        type="password"
        autocomplete="off"
        :placeholder="t('view_token.placeholder')"
        :aria-label="t('view_token.label')"
      >
      <button class="btn ghost" type="submit">{{ t('view_token.use') }}</button>
    </form>
  </div>
</template>

<script setup lang="ts">
import { setViewToken, useSpoolApi } from '~/composables/useSpoolApi'
import { doorModes, signInHref } from '~/utils/live-follow.mjs'

/* view-v1 §2: the door prompt for a 401 view_door. The hub's detail names the
   ways in; no detail → both (sign in, view token). */
const props = defineProps<{ detail?: string }>()
const emit = defineEmits<{ saved: [] }>()
const token = ref('')
const route = useRoute()
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const modes = computed(() => doorModes(props.detail))
const href = computed(() => localePath(signInHref(route.fullPath, useSpoolApi().tenant)))

function onSave() {
  setViewToken(token.value)
  token.value = ''
  emit('saved')
}
</script>
