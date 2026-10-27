<!-- Spec 143 costs-redesign.md 3.6, slice S1 (SPL-3798): Reporting -> Costs -> Paid items, a shell (its
     title and a "coming" line, no data) until slice S5 moves the page in. Operator admins only
     (the operator pane's probe); hiding only, the hub's 403 on /v1/operator/* is the control. -->
<template>
  <section class="costs-shell" data-test="costs-shell-paid">
    <h3>{{ t('reporting.costs.page.paid') }}</h3>
    <p v-if="operator.visible" class="muted" data-test="costs-shell-coming">{{ t('reporting.costs.coming') }}</p>
    <p v-else class="muted" data-test="reporting-operators-only">{{ t('reporting.future.operators_only') }}</p>
  </section>
</template>

<script setup lang="ts">
import { useOperatorPane } from '~/stores/operator-pane'

const { t } = useI18n({ useScope: 'global' })
const operator = useOperatorPane()
</script>
