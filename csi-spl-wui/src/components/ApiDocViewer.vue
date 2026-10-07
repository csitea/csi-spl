<!-- spec 104 T005 (§4.4, FR-005/006/009): the API reference at /docs/api.
     Renders the hub's OpenAPI 3.0.3 document (GET /v1/openapi.json):
     operations grouped by tag, a search over path / tag / method / summary,
     and a scope toggle - member routes by default, `x-role: operator` routes
     on demand. The toggle is UX only: the hub's role checks are the access
     control (044, the repo is public). No "Try it out": the one request this
     component makes is the spec fetch, and none when `source` is given.
     Lazy only: T006 loads it with defineAsyncComponent from docs.vue, and
     nothing else may import it (0 KB initial-chunk delta, 027).
     CSP: no eval, no inline style=, no runtime <style>; theme tokens only.
     Strings: docs.api.* (title, intro, search, search_label, operator_toggle,
     loading, load_failed, empty, count, operator, params, body, responses,
     required, deprecated); the catalogue entries land with T006. -->
<template>
  <section class="api-doc" data-test="api-doc" :data-state="state" aria-labelledby="api-doc-h">
    <header class="api-doc__head">
      <h1 id="api-doc-h" class="api-doc__title">{{ title || t('docs.api.title') }}</h1>
      <p v-if="version" class="api-doc__ver muted" data-test="api-doc-version">{{ version }}</p>
    </header>
    <p v-if="state === 'loading'" class="muted" data-test="api-doc-loading">{{ t('docs.api.loading') }}</p>
    <p v-else-if="state === 'failed'" class="api-doc__bad" role="alert" data-test="api-doc-error">{{ t('docs.api.load_failed') }}</p>
    <template v-else>
      <div class="api-doc__bar">
        <label class="api-doc__search">
          <span class="sr-only">{{ t('docs.api.search_label') }}</span>
          <input
            class="api-doc__input"
            type="search"
            data-test="api-doc-search"
            :value="query"
            :placeholder="t('docs.api.search')"
            autocomplete="off"
            spellcheck="false"
            @input="onSearch"
          >
        </label>
        <label class="api-doc__scope">
          <input
            type="checkbox"
            data-test="api-doc-operator"
            :checked="operator"
            @change="onScope"
          >
          <span>{{ t('docs.api.operator_toggle') }}</span>
        </label>
        <span class="api-doc__count muted" data-test="api-doc-count">{{ t('docs.api.count', { n: shown }) }}</span>
      </div>
      <p v-if="!groups.length" class="muted" data-test="api-doc-empty">{{ t('docs.api.empty') }}</p>
      <section
        v-for="g in groups"
        :key="g.tag"
        class="api-doc__group"
        data-test="api-doc-tag"
        :data-tag="g.tag"
      >
        <h2 class="api-doc__tag">{{ g.tag }}</h2>
        <ApiRouteCard v-for="op in g.ops" :key="op.id" :op="op" />
      </section>
    </template>
  </section>
</template>

<script lang="ts">
export type ApiParam = { name: string, in: string, required: boolean, description: string, type: string }
export type ApiResponse = { code: string, description: string, schema: string }
export type ApiOperation = {
  id: string, method: string, path: string, tag: string, summary: string, description: string,
  operator: boolean, deprecated: boolean, params: ApiParam[], body: string, responses: ApiResponse[],
}
export type ApiDoc = { title: string, version: string, ops: ApiOperation[] }
type Obj = Record<string, any>

const METHODS = ['get', 'put', 'post', 'delete', 'patch', 'head', 'options', 'trace']
const MAX_REF_DEPTH = 6

/** A local `#/a/b` reference into the document, or the node itself. */
export function resolveRef(doc: Obj, node: any, depth = 0): any {
  if (!node || typeof node !== 'object' || typeof node.$ref !== 'string' || depth > MAX_REF_DEPTH) return node
  if (!node.$ref.startsWith('#/')) return node
  const target = node.$ref.slice(2).split('/').reduce((o: any, k: string) => o?.[k.replace(/~1/g, '/').replace(/~0/g, '~')], doc)
  return target === undefined ? node : resolveRef(doc, target, depth + 1)
}

/** A schema with its refs expanded (a cycle stops at MAX_REF_DEPTH), as indented JSON text. */
export function schemaText(doc: Obj, schema: any): string {
  if (!schema) return ''
  const expand = (n: any, depth: number): any => {
    if (Array.isArray(n)) return n.map((v) => expand(v, depth))
    if (!n || typeof n !== 'object') return n
    if (typeof n.$ref === 'string') {
      return depth >= MAX_REF_DEPTH ? { $ref: n.$ref } : expand(resolveRef(doc, { $ref: n.$ref }), depth + 1)
    }
    return Object.fromEntries(Object.entries(n).map(([k, v]) => [k, expand(v, depth)]))
  }
  return JSON.stringify(expand(schema, 0), null, 2)
}

function jsonSchemaOf(doc: Obj, holder: any): string {
  const content = resolveRef(doc, holder)?.content
  if (!content || typeof content !== 'object') return ''
  const media = content['application/json'] ?? Object.values(content)[0]
  return schemaText(doc, (media as Obj | undefined)?.schema)
}

function paramsOf(doc: Obj, pathItem: Obj, op: Obj): ApiParam[] {
  const byKey = new Map<string, ApiParam>()
  for (const raw of [...(pathItem.parameters || []), ...(op.parameters || [])]) {
    const p = resolveRef(doc, raw)
    if (!p || typeof p.name !== 'string') continue
    const schema = resolveRef(doc, p.schema) || {}
    byKey.set(`${p.in}:${p.name}`, {
      name: p.name,
      in: String(p.in || ''),
      required: Boolean(p.required) || p.in === 'path',
      description: String(p.description || ''),
      type: String(schema.type || ''),
    })
  }
  return [...byKey.values()]
}

function responsesOf(doc: Obj, op: Obj): ApiResponse[] {
  return Object.keys(op.responses || {}).sort().map((code) => {
    const r = resolveRef(doc, op.responses[code]) || {}
    return { code, description: String(r.description || ''), schema: jsonSchemaOf(doc, r) }
  })
}

function operationOf(doc: Obj, path: string, method: string, pathItem: Obj): ApiOperation {
  const op = pathItem[method] as Obj
  return {
    id: String(op.operationId || `${method} ${path}`),
    method: method.toUpperCase(),
    path,
    tag: String(op.tags?.[0] || 'default'),
    summary: String(op.summary || ''),
    description: String(op.description || ''),
    operator: op['x-role'] === 'operator',
    deprecated: Boolean(op.deprecated),
    params: paramsOf(doc, pathItem, op),
    body: jsonSchemaOf(doc, op.requestBody),
    responses: responsesOf(doc, op),
  }
}

/**
 * The document as rows to render. Throws on input that is not an OpenAPI 3
 * object with `paths` (the viewer shows its error state); a malformed
 * operation inside a good document is skipped, not fatal.
 */
export function parseApiDoc(input: unknown): ApiDoc {
  const doc = typeof input === 'string' ? JSON.parse(input) : input
  if (!doc || typeof doc !== 'object' || !/^3\./.test(String((doc as Obj).openapi)) || typeof (doc as Obj).paths !== 'object') {
    throw new Error('not an OpenAPI 3 document')
  }
  const ops: ApiOperation[] = []
  for (const [path, item] of Object.entries((doc as Obj).paths || {})) {
    if (!item || typeof item !== 'object') continue
    for (const m of METHODS) {
      if ((item as Obj)[m] && typeof (item as Obj)[m] === 'object') ops.push(operationOf(doc as Obj, path, m, item as Obj))
    }
  }
  ops.sort((a, b) => a.path.localeCompare(b.path) || METHODS.indexOf(a.method.toLowerCase()) - METHODS.indexOf(b.method.toLowerCase()))
  return { title: String((doc as Obj).info?.title || ''), version: String((doc as Obj).info?.version || ''), ops }
}

/** Search (every word must match path, tag, method, summary or operationId) and scope. */
export function filterOperations(ops: ApiOperation[], query: string, operator: boolean): ApiOperation[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean)
  return ops.filter((op) => {
    if (op.operator && !operator) return false
    const hay = `${op.method} ${op.path} ${op.tag} ${op.summary} ${op.id}`.toLowerCase()
    return words.every((w) => hay.includes(w))
  })
}

/** Operations by tag, tags in alphabetical order. */
export function groupByTag(ops: ApiOperation[]): { tag: string, ops: ApiOperation[] }[] {
  const m = new Map<string, ApiOperation[]>()
  for (const op of ops) {
    if (!m.has(op.tag)) m.set(op.tag, [])
    m.get(op.tag)!.push(op)
  }
  return [...m.keys()].sort().map((tag) => ({ tag, ops: m.get(tag)! }))
}
</script>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import ApiRouteCard from './ApiRouteCard.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'

/* `source`: the document as JSON text, rendered without a fetch (the mock
   bundle and the tests); otherwise the hub's GET /v1/openapi.json */
const props = defineProps<{ source?: string }>()
const { t } = useI18n({ useScope: 'global' })

const state = ref<'loading' | 'ready' | 'failed'>('loading')
const doc = ref<ApiDoc>({ title: '', version: '', ops: [] })
const query = ref('')
const operator = ref(false)

function load(text: string) {
  try {
    doc.value = parseApiDoc(text)
    state.value = 'ready'
  } catch {
    state.value = 'failed'
  }
}
if (typeof props.source === 'string') load(props.source)

async function fetchSpec() {
  const api = useSpoolApi()
  const headers: Record<string, string> = { accept: 'application/json' }
  if (api.token) headers.authorization = `Bearer ${api.token}`
  try {
    const r = await fetch(`${api.base}/v1/openapi.json`, { credentials: api.credentials, cache: 'no-cache', headers })
    if (!r.ok) throw new Error('openapi ' + r.status)
    load(await r.text())
  } catch {
    state.value = 'failed'
  }
}
onMounted(() => {
  if (typeof props.source !== 'string') void fetchSpec()
})

const title = computed(() => doc.value.title)
const version = computed(() => doc.value.version)
const visible = computed(() => filterOperations(doc.value.ops, query.value, operator.value))
const groups = computed(() => groupByTag(visible.value))
const shown = computed(() => visible.value.length)
function onSearch(e: Event) { query.value = (e.target as HTMLInputElement).value }
function onScope(e: Event) { operator.value = (e.target as HTMLInputElement).checked }
</script>

<style scoped>
.api-doc { display: flex; flex-direction: column; gap: var(--spacing-md); max-width: 60rem; }
.api-doc__head { display: flex; align-items: baseline; gap: var(--spacing-sm); flex-wrap: wrap; }
.api-doc__title { margin: 0; font-size: 1.375rem; color: var(--color-heading); }
.api-doc__ver { margin: 0; font-size: 0.8125rem; font-family: var(--font-mono); }
.api-doc__bad { margin: 0; color: var(--color-danger); }
.api-doc__bar { display: flex; align-items: center; gap: var(--spacing-md); flex-wrap: wrap; }
.api-doc__search { flex: 1 1 16rem; }
.api-doc__input {
  width: 100%;
  padding: var(--spacing-xs) var(--spacing-sm);
  font-size: 0.875rem;
  color: var(--color-fg);
  background: var(--color-bg);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
}
.api-doc__scope { display: inline-flex; align-items: center; gap: var(--spacing-xs); font-size: 0.875rem; }
.api-doc__count { font-size: 0.8125rem; }
.api-doc__group { display: flex; flex-direction: column; gap: var(--spacing-sm); }
.api-doc__tag {
  margin: 0;
  padding-block-end: var(--spacing-xs);
  font-size: 1rem;
  color: var(--color-heading);
  border-bottom: 1px solid var(--color-border);
}
</style>
