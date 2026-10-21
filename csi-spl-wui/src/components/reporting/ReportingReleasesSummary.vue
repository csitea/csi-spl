<!-- Spec 143 2.2 T022 (SPL-2787): the Releases tab's KPI strip. The
     releases minted (distinct versions) and the commits landed in the
     window, the commits per day, and the deploys to dev and prd. A figure
     the answer lacks, or no answer at all, is a dash, never NaN or a false 0. -->
<template>
  <div class="rr-kpis" role="group" :aria-label="t('reporting.releases.kpis_label')" data-test="releases-kpis">
    <section class="rr-kpi" data-test="releases-kpi-releases">
      <h3>{{ t('reporting.releases.kpi_releases') }}</h3>
      <p class="rr-kpi-value" data-test="releases-kpi-releases-value">{{ count(s.releases) }}</p>
    </section>
    <section class="rr-kpi" data-test="releases-kpi-commits">
      <h3>{{ t('reporting.releases.kpi_commits') }}</h3>
      <p class="rr-kpi-value" data-test="releases-kpi-commits-value">{{ count(s.commits) }}</p>
    </section>
    <section class="rr-kpi" data-test="releases-kpi-per-day">
      <h3>{{ t('reporting.releases.kpi_per_day') }}</h3>
      <p class="rr-kpi-value" data-test="releases-kpi-per-day-value">{{ count(s.perDay) }}</p>
    </section>
    <section class="rr-kpi" data-test="releases-kpi-deploys">
      <h3>{{ t('reporting.releases.kpi_deploys') }}</h3>
      <p class="rr-kpi-value rr-kpi-value--pair" data-test="releases-kpi-deploys-value">{{ t('reporting.releases.kpi_deploys_value', { dev: count(s.dev), prd: count(s.prd) }) }}</p>
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
</script>

<style scoped>
.rr-kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; }
.rr-kpi { border: 1px solid var(--color-border); border-radius: var(--radius-md, 8px); padding: 10px 12px; min-width: 0; }
.rr-kpi h3 { margin: 0 0 4px; font-size: 0.8125rem; font-weight: 600; color: var(--color-muted); }
.rr-kpi-value { margin: 0; font-size: 1.375rem; font-weight: 700; font-variant-numeric: tabular-nums; }
.rr-kpi-value--pair { font-size: 1rem; line-height: 1.9; }
@media (max-width: 600px) {
  .rr-kpis { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 6px; }
  .rr-kpi { padding: 6px 8px; }
  .rr-kpi-value { font-size: 1.0625rem; }
  .rr-kpi-value--pair { font-size: 0.875rem; line-height: 1.6; }
}
</style>
