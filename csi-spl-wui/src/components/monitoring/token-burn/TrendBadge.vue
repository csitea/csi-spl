<!-- Plan 5.3 (SPL-2483): a lane's burn velocity beside its 1m rate, from
     tokenVelocity(rate1m, rate5m): ▲ rising, ▼ falling, — steady (not the
     sort arrows ↑/↓); nothing for null (an unmetered lane). The words are
     the aria-label, from the i18n keys monitoring.tokens.trend_*. -->
<template>
  <span
    v-if="trend === 'rising' || trend === 'falling' || trend === 'steady'"
    class="tk-trend"
    :class="'tk-trend--' + trend"
    role="img"
    data-test="tokens-trend-badge"
    :data-trend="trend"
    :aria-label="t(trend === 'rising' ? 'monitoring.tokens.trend_rising' : trend === 'falling' ? 'monitoring.tokens.trend_falling' : 'monitoring.tokens.trend_steady')"
  >{{ trend === 'rising' ? '▲' : trend === 'falling' ? '▼' : '—' }}</span>
</template>

<script setup lang="ts">
defineProps<{ trend: string | null }>()
const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
.tk-trend { display: inline-block; margin-inline-start: 4px; font-size: 0.75rem; line-height: 1; white-space: nowrap; }
.tk-trend--rising { color: var(--color-danger); }
.tk-trend--falling { color: var(--color-ok); }
.tk-trend--steady { color: var(--color-muted); }
</style>
