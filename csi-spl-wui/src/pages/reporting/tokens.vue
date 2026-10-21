<!-- spec 143 5.1, 6.1, task T050 (SPL-2791): the Tokens tab, reserved.
     Owner HUM-10 (t1 af25a1f3, msg a8bfcdd0): operator admins only, never a
     workspace admin. Its row in utils/reporting-tabs.mjs stays ready: false,
     so the bar never draws it; a reader who opens the path anyway sees the
     page only as an operator admin (the operator pane's probe). Hiding only:
     the hub's 403 on /v1/operator/* is the control. Until the report lands,
     the fleet's burn (GET /v1/operator/fleet-tokens) is Monitoring > Tokens. -->
<template>
  <div v-if="operator.visible" data-test="reporting-tokens">
    <p class="reporting-soon muted">{{ t('reporting.future.tokens') }}</p>
    <NuxtLink :to="localePath('/monitoring/tokens')" data-test="reporting-tokens-monitoring">{{ t('reporting.future.tokens_link') }}</NuxtLink>
  </div>
  <p v-else class="reporting-soon muted" data-test="reporting-operators-only">{{ t('reporting.future.operators_only') }}</p>
</template>

<script setup lang="ts">
import { useOperatorPane } from '~/stores/operator-pane'

const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const operator = useOperatorPane()
</script>
