<!-- The top-bar clock: local HH:mm:ss of the last hub response.
     It is the only reader of that stamp, so a response re-renders this
     node and not the bar. No timer: the text changes when data arrives. -->
<template>
  <time
    class="last-data-clock"
    data-test="last-data-clock"
    :datetime="iso || undefined"
    :data-at="iso"
    :title="title"
    :aria-label="title"
  >{{ text }}</time>
</template>

<script setup lang="ts">
import { formatLastDataClock, formatLastDataDate, lastDataAt, onLastData } from '~/utils/last-data.mjs'

const { t } = useI18n({ useScope: 'global' })
const ms = ref(0)
let off: () => void = () => {}

onMounted(() => {
  off = onLastData((n: number) => { ms.value = n })
  const n = lastDataAt()
  if (n) ms.value = n
})
onBeforeUnmount(() => off())

const text = computed(() => formatLastDataClock(ms.value))
const iso = computed(() => (ms.value ? new Date(ms.value).toISOString() : ''))
const title = computed(() => {
  if (!ms.value) return t('topbar.last_updated')
  return t('topbar.last_updated_title', { date: formatLastDataDate(ms.value) })
})
</script>

<style scoped>
/* Eight glyphs in every state, so the first response does not move the bar. */
.last-data-clock {
  display: inline-block;
  flex: none;
  box-sizing: content-box;
  min-width: 8ch;
  font-family: var(--font-mono);
  font-variant-numeric: tabular-nums;
  font-size: 0.6875rem;
  line-height: 1;
  color: var(--color-muted);
  white-space: nowrap;
  text-align: end;
}
</style>
