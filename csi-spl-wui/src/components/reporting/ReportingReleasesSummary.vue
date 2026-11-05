<!-- Spec 143 2.2 T022 (SPL-2787): the Releases tab's KPI strip. The
     releases minted (distinct versions) and the commits landed in the
     window, the commits per day, and the deploys to dev and prd. A figure
     the answer lacks, or no answer at all, is a dash, never NaN or a false 0.
     SPL-4811 (owner HUM-10, t1 c7c44497, msg 60441a88: "one row only - aka
     first the value space space - space space - WHAT it is"): each card is
     one line, "<value>  -  <label>"; the dash is drawn, not read. -->
<template>
  <div class="rr-kpis" role="group" :aria-label="t('reporting.releases.kpis_label')" data-test="releases-kpis">
    <section class="rr-kpi" data-test="releases-kpi-releases">
      <p class="rr-kpi-value" data-test="releases-kpi-releases-value">{{ count(s.releases) }}</p>
      <span class="rr-kpi-sep" aria-hidden="true">{{ SEP }}</span>
      <h3>{{ t('reporting.releases.kpi_releases') }}</h3>
    </section>
    <section class="rr-kpi" data-test="releases-kpi-commits">
      <p class="rr-kpi-value" data-test="releases-kpi-commits-value">{{ count(s.commits) }}</p>
      <span class="rr-kpi-sep" aria-hidden="true">{{ SEP }}</span>
      <h3>{{ t('reporting.releases.kpi_commits') }}</h3>
    </section>
    <section class="rr-kpi" data-test="releases-kpi-per-day">
      <p class="rr-kpi-value" data-test="releases-kpi-per-day-value">{{ count(s.perDay) }}</p>
      <span class="rr-kpi-sep" aria-hidden="true">{{ SEP }}</span>
      <h3>{{ t('reporting.releases.kpi_per_day') }}</h3>
    </section>
    <section class="rr-kpi" data-test="releases-kpi-deploys">
      <p class="rr-kpi-value rr-kpi-value--pair" data-test="releases-kpi-deploys-value">{{ t('reporting.releases.kpi_deploys_value', { dev: count(s.dev), prd: count(s.prd) }) }}</p>
      <span class="rr-kpi-sep" aria-hidden="true">{{ SEP }}</span>
      <h3>{{ t('reporting.releases.kpi_deploys') }}</h3>
    </section>
  </div>
</template>

<script setup lang="ts">
import { fmtCount, type ReleaseSummary } from '~/utils/reporting-releases'

const props = defineProps<{ summary?: ReleaseSummary | null }>()
const { t, locale } = useI18n({ useScope: 'global' })
const EMPTY: ReleaseSummary = { releases: null, commits: null, perDay: null, dev: null, prd: null }
const s = computed(() => props.summary || EMPTY)
const count = (n: number | null) => fmtCount(n, locale.value)
const SEP = '  -  '
</script>

<style scoped>
/* SPL-4811: a card is as wide as its one line, the cards wrap as whole cards;
   a card wider than the page (a long locale on a phone) wraps inside itself,
   and the drawn dash is never copied with the text */
.rr-kpis { display: flex; flex-wrap: wrap; gap: 12px; }
.rr-kpi { display: flex; flex-wrap: wrap; align-items: baseline; flex: 1 1 auto; white-space: nowrap; border: 1px solid var(--color-border); border-radius: var(--radius-md, 8px); padding: 10px 12px; min-width: 0; }
.rr-kpi h3, .rr-kpi-sep { font-size: 0.8125rem; color: var(--color-muted); }
.rr-kpi h3 { margin: 0; font-weight: 600; }
.rr-kpi-sep { white-space: pre; user-select: none; }
.rr-kpi-value { margin: 0; font-size: 1.375rem; font-weight: 700; font-variant-numeric: tabular-nums; }
.rr-kpi-value--pair { font-size: 1rem; white-space: normal; }
@media (max-width: 600px) {
  .rr-kpis { gap: 6px; }
  .rr-kpi { padding: 6px 8px; }
  .rr-kpi-value { font-size: 1.0625rem; }
  .rr-kpi-value--pair { font-size: 0.875rem; }
}
</style>
