<!-- spec 104 T005: one OpenAPI operation in the API reference
     (ApiDocViewer): method badge, path, summary, an operator mark for
     `x-role: operator`, and - expanded with <details>, no script - its
     parameters, request body schema and responses (every error response is
     the {error, detail} envelope). Read-only: no "Try it out". -->
<template>
  <article
    class="api-route"
    data-test="api-route"
    :data-op="op.id"
    :data-method="op.method"
    :data-role="op.operator ? 'operator' : 'member'"
  >
    <details class="api-route__details">
      <summary class="api-route__head">
        <span class="api-route__method" :class="'api-route__method--' + op.method.toLowerCase()" data-test="api-route-method">{{ op.method }}</span>
        <code class="api-route__path" data-test="api-route-path">{{ op.path }}</code>
        <span class="api-route__summary">{{ op.summary }}</span>
        <span v-if="op.operator" class="api-route__mark" data-test="api-route-operator">{{ t('docs.api.operator') }}</span>
        <span v-if="op.deprecated" class="api-route__mark api-route__mark--old">{{ t('docs.api.deprecated') }}</span>
      </summary>
      <div class="api-route__body">
        <p v-if="op.description" class="api-route__desc">{{ op.description }}</p>
        <template v-if="op.params.length">
          <h3 class="api-route__h">{{ t('docs.api.params') }}</h3>
          <ul class="api-route__params" data-test="api-route-params">
            <li v-for="p in op.params" :key="p.in + ':' + p.name" class="api-route__param">
              <code>{{ p.name }}</code>
              <span class="muted">{{ p.in }}<template v-if="p.type"> · {{ p.type }}</template></span>
              <span v-if="p.required" class="api-route__req">{{ t('docs.api.required') }}</span>
              <span v-if="p.description" class="api-route__pdesc">{{ p.description }}</span>
            </li>
          </ul>
        </template>
        <template v-if="op.body">
          <h3 class="api-route__h">{{ t('docs.api.body') }}</h3>
          <pre class="api-route__schema" data-test="api-route-body">{{ op.body }}</pre>
        </template>
        <h3 class="api-route__h">{{ t('docs.api.responses') }}</h3>
        <ul class="api-route__responses" data-test="api-route-responses">
          <li v-for="r in op.responses" :key="r.code" class="api-route__response" :data-code="r.code">
            <code class="api-route__code" :class="{ 'api-route__code--err': /^[45]/.test(r.code) }">{{ r.code }}</code>
            <span>{{ r.description }}</span>
            <pre v-if="r.schema" class="api-route__schema">{{ r.schema }}</pre>
          </li>
        </ul>
      </div>
    </details>
  </article>
</template>

<script setup lang="ts">
import type { ApiOperation } from './ApiDocViewer.vue'

defineProps<{ op: ApiOperation }>()
const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
.api-route { border: 1px solid var(--color-border); border-radius: var(--radius-sm); background: var(--color-surface); }
.api-route__head {
  display: flex;
  align-items: baseline;
  gap: var(--spacing-sm);
  flex-wrap: wrap;
  padding: var(--spacing-xs) var(--spacing-sm);
  cursor: pointer;
  font-size: 0.875rem;
}
.api-route__head:hover { background: var(--color-surface-hover); }
.api-route__method {
  min-width: 4rem;
  padding: 0 var(--spacing-xs);
  font-family: var(--font-mono);
  font-size: 0.75rem;
  font-weight: 700;
  text-align: center;
  border: 1px solid currentColor;
  border-radius: var(--radius-sm);
  color: var(--color-accent);
}
.api-route__method--post, .api-route__method--put, .api-route__method--patch { color: var(--color-ok); }
.api-route__method--delete { color: var(--color-danger); }
.api-route__path { font-family: var(--font-mono); font-size: 0.875rem; color: var(--color-fg); overflow-wrap: anywhere; }
.api-route__summary { color: var(--color-muted); }
.api-route__mark {
  padding: 0 var(--spacing-xs);
  font-size: 0.75rem;
  color: var(--color-warn);
  border: 1px solid var(--color-warn);
  border-radius: var(--radius-pill);
}
.api-route__mark--old { color: var(--color-muted); border-color: var(--color-border-strong); }
.api-route__body { display: flex; flex-direction: column; gap: var(--spacing-xs); padding: var(--spacing-sm); border-top: 1px solid var(--color-border); }
.api-route__desc { margin: 0; font-size: 0.875rem; }
.api-route__h { margin: var(--spacing-xs) 0 0; font-size: 0.8125rem; color: var(--color-heading); }
.api-route__params, .api-route__responses { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: var(--spacing-xs); font-size: 0.8125rem; }
.api-route__param, .api-route__response { display: flex; flex-wrap: wrap; align-items: baseline; gap: var(--spacing-sm); }
.api-route__req { color: var(--color-danger); font-size: 0.75rem; }
.api-route__pdesc { flex-basis: 100%; color: var(--color-muted); }
.api-route__code { font-family: var(--font-mono); color: var(--color-ok); }
.api-route__code--err { color: var(--color-danger); }
.api-route__schema {
  flex-basis: 100%;
  margin: 0;
  padding: var(--spacing-xs) var(--spacing-sm);
  font-family: var(--font-mono);
  font-size: 0.75rem;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  background: var(--color-bg-2);
  border-radius: var(--radius-sm);
}
</style>
