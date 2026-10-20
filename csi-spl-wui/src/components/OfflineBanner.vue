<!-- SPL-2149 (owner HUM-10, t1 1061f05f msg 4d63f24c, suggestion 8): offline,
     the open feed is the copy this device kept (utils/offline-feed.mjs), and
     this strip says so, with the time that copy was read. The channel and
     DM pages mount it (a page chunk, not the first download); it renders
     only while the browser is offline (a kept copy is shown only then).

     Lazy (LazyOfflineBanner) and on demand: its strings wait in the second
     catalogue (utils/i18n-first-screen.mjs) and it renders once they are
     merged (te()). Its chunk loads with the page while online, so the
     service worker holds it for the offline reload. role=status: read
     once when it appears. CSP: classes only, no :style. -->
<template>
  <div
    v-if="ready && offline"
    class="offline-banner"
    role="status"
    aria-live="polite"
    data-test="offline-banner"
    :data-kept="keptAt ? 'true' : undefined"
  >
    <span class="offline-banner__title">{{ t('offline.banner.title') }}</span>
    <span class="offline-banner__hint" data-test="offline-banner-hint">{{ keptAt ? t('offline.banner.kept', { time: isoDateTime(keptAt) }) : t('offline.banner.none') }}</span>
  </div>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'
import { isoDateTime } from '~/utils/date-iso.mjs'

const { t, te } = useI18n({ useScope: 'global' })
const channel = useChannelStore()
/* the second catalogue holds the copy; nothing shows until it is merged */
const ready = computed(() => te('offline.banner.title'))
const keptAt = computed(() => channel.offlineAt || '')
/* read after mount: the prerendered page knows no network state */
const offline = ref(false)
const read = () => { offline.value = navigator.onLine === false }
onMounted(() => {
  read()
  addEventListener('online', read)
  addEventListener('offline', read)
})
onBeforeUnmount(() => {
  removeEventListener('online', read)
  removeEventListener('offline', read)
})
</script>

<style scoped>
.offline-banner {
  position: fixed;
  top: calc(var(--top-bar-h) + 0.5rem);
  /* centred by auto margins, as the build bar: left:50% would wrap on phones */
  left: 0;
  right: 0;
  margin-inline: auto;
  width: fit-content;
  max-width: calc(100vw - 2rem);
  box-sizing: border-box;
  z-index: var(--z-banner);
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0.25rem 0.625rem;
  padding: 0.375rem 0.875rem;
  border: 1px solid var(--color-warn);
  border-radius: var(--radius-sm);
  background: color-mix(in srgb, var(--color-warn) 14%, var(--color-surface));
  color: var(--color-fg);
  font-size: 0.875rem;
  pointer-events: none;
}
.offline-banner__title { font-weight: 600; }
.offline-banner__hint { min-width: 0; overflow-wrap: anywhere; }
</style>
