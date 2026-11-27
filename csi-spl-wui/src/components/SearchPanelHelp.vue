<!-- SPL-6675: a bare /search opens the search panel with this help - what the
     retired /search page showed with no query: the examples (one click runs
     one) and the operators. Lazy: only a bare search mounts it. -->
<template>
  <section class="search-help" data-test="search-help">
    <p class="muted">{{ t('search.help_intro') }}</p>
    <ul>
      <li v-for="ex in examples" :key="ex">
        <button type="button" class="search-help__ex" @click="emit('search', ex)"><code dir="ltr">/search: {{ ex }}</code></button>
      </li>
    </ul>
    <p class="muted">{{ t('search.help_operators') }}</p>
    <ul data-test="search-operator-help">
      <li v-for="row in helpRows" :key="row.op">
        <code dir="ltr">/search: {{ row.example }}</code>
        <span v-if="te(row.hintKey)" class="muted"> · {{ t(row.hintKey) }}</span>
      </li>
    </ul>
  </section>
</template>

<script setup lang="ts">
import { useSearchStore } from '~/stores/search'
import { operatorHelpRows } from '~/utils/search.mjs'

const emit = defineEmits<{ (e: 'search', q: string): void }>()
const { t, te } = useI18n({ useScope: 'global' })
const search = useSearchStore()
const examples = [
  'from:CLE-07 is:task',
  '"dry run" after:7d',
  'type:robot is:online',
  'title:migration',
  'type:file ext:pdf larger:1M',
  'has:code in:#lobby',
  'type:channel name:dev',
  'type:tenant name:ops',
  'type:tenant csitea',
  'type:event fetch',
  'type:calendar',
  'status:in_progress',
]
const helpRows = computed(() => operatorHelpRows(search.operators))
</script>

<style scoped>
.search-help { padding: 4px 10px; font-size: 0.8125rem; }
.search-help ul { list-style: none; padding: 0; margin: 0 0 12px; }
.search-help li { margin: 4px 0; overflow-wrap: anywhere; }
.search-help code { font-family: var(--font-mono); overflow-wrap: anywhere; }
.search-help__ex {
  all: unset;
  cursor: pointer;
  color: var(--color-link, var(--color-accent));
  overflow-wrap: anywhere;
}
.search-help__ex:focus-visible { outline: 2px solid var(--focus-ring); border-radius: var(--radius-sm); }
@media (max-width: 820px) {
  .search-help__ex { display: block; min-height: var(--tap, 44px); padding-block: 10px; box-sizing: border-box; }
}
</style>
