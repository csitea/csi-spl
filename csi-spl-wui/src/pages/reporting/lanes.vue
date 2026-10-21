<!-- spec 143 5.4, 6.1, task T053 (SPL-2791): the Lanes tab, reserved; operator admins only (spec 143 6.1).
     Its row in utils/reporting-tabs.mjs stays ready: false, so the bar never
     draws it; a reader who opens the path anyway sees the page only as an
     operator admin (the operator pane's probe). Hiding only: the hub's 403
     on the operator routes is the control. -->
<template>
  <p v-if="operator.visible" class="reporting-soon muted" data-test="reporting-lanes">{{ t('reporting.future.lanes') }}</p>
  <p v-else class="reporting-soon muted" data-test="reporting-operators-only">{{ t('reporting.future.operators_only') }}</p>
</template>

<script setup lang="ts">
import { useOperatorPane } from '~/stores/operator-pane'

const { t } = useI18n({ useScope: 'global' })
const operator = useOperatorPane()
</script>
