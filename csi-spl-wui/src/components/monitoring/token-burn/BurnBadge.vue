<!-- Spec 140 4.4.1 (SPL-2322): the burn badge beside a tokens/min, from the
     fresh tokens/min (in + out + cache write): nothing when normal, amber
     "elevated" from 30k, red "surge" above 60k. -->
<template>
  <span
    v-if="level === 'elevated' || level === 'surge'"
    class="tk-burn"
    :class="'tk-burn--' + level"
    data-test="tokens-burn-badge"
    :data-level="level"
  >{{ t(level === 'surge' ? 'monitoring.tokens.burn_surge' : 'monitoring.tokens.burn_elevated') }}</span>
</template>

<script setup lang="ts">
defineProps<{ level: string }>()
const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
.tk-burn { display: inline-block; margin-inline-start: 6px; padding: 0 6px; border-radius: var(--radius-pill); font-size: 0.75rem; font-weight: 600; white-space: nowrap; }
.tk-burn--elevated { border: 1px solid var(--color-warn); color: var(--color-warn); }
.tk-burn--surge { background: var(--color-danger); color: var(--color-danger-fg); animation: tk-pulse 1.6s ease-in-out infinite; }
@keyframes tk-pulse { 50% { opacity: 0.6; } }
@media (prefers-reduced-motion: reduce) { .tk-burn--surge { animation: none; } }
</style>
