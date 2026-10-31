<!-- spec 163 G5, build row B1 (SPL-4250): the Reporting Marketing tab.
     Owner HUM-10 (csitea topic b13f7763, poll 337fb605, msg 449350b3): Q7
     "A — Last touch, 28 days", Q8 "B — Workspace admins and the owner
     only". One card per stage in the overview's order (spec 163 section
     2), empty until a connector row writes numbers. The hub (GET
     /v1/reporting/marketing) is the control: it answers 403 to anyone but
     the workspace's owner or an admin, and this page then shows that line
     and no card. -->
<template>
  <div class="reporting-marketing" data-test="reporting-marketing">
    <p v-if="state === 'loading'" class="muted" role="status" data-test="reporting-marketing-loading">{{ t('reporting.marketing.loading') }}</p>
    <p v-else-if="state === 'forbidden'" class="muted" role="alert" data-test="reporting-marketing-forbidden">{{ t('reporting.marketing.forbidden') }}</p>
    <p v-else-if="state === 'error'" class="mkt-error" role="alert" data-test="reporting-marketing-error">{{ t('reporting.marketing.error') }}</p>
    <template v-else>
      <p class="muted mkt-intro" data-test="reporting-marketing-intro">{{ t('reporting.marketing.intro') }}</p>
      <p v-if="attribution" class="mkt-attribution" data-test="reporting-marketing-attribution">
        {{ t('reporting.marketing.attribution', { rule: t(attribution.ruleKey), days: attribution.days }) }}
      </p>
      <ul class="mkt-cards" :aria-label="t('reporting.marketing.cards_label')" data-test="reporting-marketing-cards">
        <li v-for="card in cards" :key="card.id" class="mkt-card" :data-test="'reporting-marketing-card-' + card.id">
          <h3 class="mkt-card-title">{{ t(card.labelKey) }}</h3>
          <p v-if="!card.samples.length" class="muted mkt-card-empty" data-test="reporting-marketing-card-empty">{{ t('reporting.marketing.empty') }}</p>
        </li>
      </ul>
    </template>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAccessStore } from '~/stores/access'
import { gateMe, staffReadable } from '~/utils/read-gates.mjs'
import { marketingAttribution, marketingReportRead, marketingStageCards } from '~/utils/reporting-marketing.mjs'

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi() as unknown as Parameters<typeof marketingReportRead>[0]

type Report = Parameters<typeof marketingStageCards>[0]
const state = ref<'loading' | 'ready' | 'forbidden' | 'error'>('loading')
const report = ref<Report>(undefined)
const cards = computed(() => marketingStageCards(report.value))
const attribution = computed(() => marketingAttribution(report.value))

/* in the browser only: the prerendered page is the loading line */
const access = useAccessStore()
onMounted(async () => {
  try {
    /* SPL-4453: a reader /v1/view/me names neither owner nor admin gets the line, no request */
    if (!staffReadable(await gateMe(access))) {
      state.value = 'forbidden'
      return
    }
    report.value = await marketingReportRead(api)
    state.value = 'ready'
  } catch (e) {
    state.value = (e as { status?: number })?.status === 403 ? 'forbidden' : 'error'
  }
})
</script>

<style scoped>
.reporting-marketing { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
.mkt-intro, .mkt-attribution { margin: 0; }
.mkt-attribution { font-weight: 600; }
.mkt-error { color: var(--color-danger); margin: 0; }
.mkt-cards {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(100%, 240px), 1fr));
  gap: 12px;
  margin: 0;
  padding: 0;
  list-style: none;
}
.mkt-card {
  display: flex;
  flex-direction: column;
  gap: 6px;
  min-width: 0;
  padding: 12px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
}
.mkt-card-title { margin: 0; font-size: 1rem; font-weight: 600; }
.mkt-card-empty { margin: 0; font-size: 0.875rem; }
</style>
