<!-- CLE-77882: /m/<msg_id>, the deep link of one message. It resolves the id
     and replaces itself with the message's original place (channel or DM,
     topic open, the message marked; a reply in its thread). A message that
     cannot be shown leaves this page saying why. -->
<template>
  <div class="feed-col">
    <header class="feed-header">
      <MobileBack />
      <h2>{{ t('open_message.title') }}</h2>
    </header>
    <div class="feed-body open-msg-page">
      <p v-if="!reason" class="muted" data-testid="open-msg-loading" aria-live="polite">{{ t('open_message.opening') }}</p>
      <div v-else class="open-msg-notice" role="alert" data-testid="open-msg-notice" :data-reason="reason" :data-id="msgId">
        <p>{{ t('open_message.' + reason) }}</p>
        <NuxtLink :to="localePath('/')">{{ t('open_message.home') }}</NuxtLink>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useOpenMessage } from '~/composables/useOpenMessage'
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'

const route = useRoute()
const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const session = useSessionStore()
const { openMessage } = useOpenMessage()
const msgId = computed(() => String(route.params.id || '').toLowerCase())
const reason = ref('')
let started = ''

/* live waits for a member session (as every feed page does); the mock opens at once */
watch([msgId, () => session.state], async ([id, st]) => {
  if (!api.mock && String(st) !== 'in') return
  if (!id || started === id) return
  started = id
  reason.value = ''
  const out = await openMessage(id, { keepList: false, notify: false, replace: true })
  if (!out.ok && msgId.value === id) reason.value = out.reason
}, { immediate: true })

useHead(() => ({ title: t('open_message.title') }))
</script>

<style scoped>
.open-msg-page { padding: var(--space-4, 1rem); }
.open-msg-notice { display: grid; gap: 0.5rem; justify-items: start; }
</style>
