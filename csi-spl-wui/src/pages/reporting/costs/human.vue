<!-- SPL-4187 (spec 123 5.5 and 13.5; owner HUM-10, t1 e2c0e6b4, msg 81217a3f:
     "three main types of costs: cloud costs, AI token costs, and human
     costs"): Reporting -> Costs -> Human, a section of its own. Human costs
     are approved time at each person's own price (spec 107 section 21), not
     built yet: the page says "not tracked yet" and names the spec 107 rows
     that build it, never a number until they land. -->
<template>
  <section class="costs-human" data-test="costs-human">
    <h3>{{ t('reporting.costs.human.title') }}</h3>
    <p class="muted" data-test="costs-human-not-tracked">{{ t('reporting.costs.human.not_tracked', { rows: HUMAN_ROWS }) }}</p>
  </section>
</template>

<script setup lang="ts">
import { HUMAN_ROWS } from '~/utils/costs-sections.mjs'

const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
.costs-human { display: flex; flex-direction: column; gap: 8px; }
.costs-human h3 { margin: 0; font-size: 1rem; }
</style>
