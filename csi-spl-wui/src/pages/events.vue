<!-- Personal event log (GRK-3514, topic 4335f075).

     Lists GET /api/v1/auth/events via createEventsClient (CLE-34990).
     Signed-out shows the catalogue line and never POSTs. A failed read
     is a sentence, never written back into the journal. -->
<template>
  <div class="feed-col" data-test="events-page">
    <header class="feed-header">
      <h2>{{ t('events.title') }}</h2>
      <span class="events-spacer" />
      <button
        v-if="signedIn && rows.length"
        type="button"
        class="btn"
        data-test="events-clear"
        :disabled="busy"
        @click="onClear"
      >{{ t('events.clear') }}</button>
    </header>
    <div class="feed-body">
      <p v-if="session.state === 'loading'" class="muted" data-test="events-loading">{{ t('common.loading') }}</p>
      <p v-else-if="!signedIn" class="muted" data-test="events-signed-out">{{ t('events.signed_out') }}</p>
      <p v-else-if="loadError" class="events-error" role="alert" data-test="events-error">{{ t(loadError) }}</p>
      <p v-else-if="loading" class="muted" data-test="events-loading">{{ t('common.loading') }}</p>
      <p v-else-if="!rows.length" class="muted" data-test="events-empty">{{ t('events.empty') }}</p>
      <div v-else class="events-table-wrap">
        <table class="events-table" data-test="events-table">
          <thead>
            <tr>
              <th scope="col">{{ t('events.col_when') }}</th>
              <th scope="col">{{ t('events.col_id') }}</th>
              <th scope="col">{{ t('events.col_source') }}</th>
              <th scope="col">{{ t('events.col_status') }}</th>
              <th scope="col">{{ t('events.col_message') }}</th>
              <th scope="col">{{ t('events.col_route') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="r in rows" :key="r.id" data-test="events-row">
              <td dir="ltr">{{ whenOf(r) }}</td>
              <td><code dir="ltr">{{ r.error_id }}</code></td>
              <td dir="ltr">{{ r.source }}</td>
              <td dir="ltr">{{ r.status ? String(r.status) : '' }}</td>
              <td>{{ r.message }}</td>
              <td><code dir="ltr">{{ r.route }}</code></td>
            </tr>
          </tbody>
        </table>
        <button
          v-if="nextBefore"
          type="button"
          class="btn ghost"
          data-test="events-load-more"
          :disabled="busy"
          @click="loadMore"
        >{{ t('events.load_more') }}</button>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { createEventsClient, eventsErrorKey } from '~/utils/event-log.mjs'

type EventRow = {
  id: number
  error_id: string
  at: string | null
  received_at: string
  source: string
  status: number
  message: string
  route: string
}

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const client = createEventsClient({ base: useAuthBase() })
const signedIn = computed(() => session.state === 'in')

const rows = ref<EventRow[]>([])
const nextBefore = ref(0)
const loading = ref(false)
const busy = ref(false)
const loadError = ref('')

function whenOf(r: EventRow) {
  return r.at || r.received_at || ''
}

function asRows(data: unknown): EventRow[] {
  const list = data && typeof data === 'object' ? (data as { events?: unknown }).events : null
  if (!Array.isArray(list)) return []
  const out: EventRow[] = []
  for (const x of list) {
    if (!x || typeof x !== 'object') continue
    const o = x as Record<string, unknown>
    const id = Number(o.id)
    if (!Number.isFinite(id) || id <= 0) continue
    out.push({
      id,
      error_id: String(o.error_id || ''),
      at: o.at == null ? null : String(o.at),
      received_at: String(o.received_at || ''),
      source: String(o.source || ''),
      status: Number(o.status) || 0,
      message: String(o.message || ''),
      route: String(o.route || ''),
    })
  }
  return out
}

async function load(before = 0, append = false) {
  if (!signedIn.value) {
    rows.value = []
    nextBefore.value = 0
    loadError.value = ''
    return
  }
  if (append) busy.value = true
  else loading.value = true
  loadError.value = ''
  const res = await client.list({ limit: 50, before })
  if (!res.ok) {
    loadError.value = eventsErrorKey(res.error)
    if (!append) rows.value = []
  } else {
    const page = asRows(res.data)
    rows.value = append ? [...rows.value, ...page] : page
    const nb = res.data && typeof res.data === 'object' ? Number((res.data as { next_before?: unknown }).next_before) : 0
    nextBefore.value = Number.isFinite(nb) && nb > 0 ? nb : 0
  }
  loading.value = false
  busy.value = false
}

function loadMore() {
  if (!nextBefore.value || busy.value) return
  void load(nextBefore.value, true)
}

async function onClear() {
  if (!signedIn.value || busy.value) return
  busy.value = true
  const res = await client.clear()
  busy.value = false
  if (!res.ok) {
    loadError.value = eventsErrorKey(res.error)
    return
  }
  rows.value = []
  nextBefore.value = 0
}

watch(() => session.state, (st) => {
  if (st === 'in') void load()
  else if (st === 'out') {
    rows.value = []
    nextBefore.value = 0
    loadError.value = ''
  }
}, { immediate: true })
</script>

<style scoped>
.events-spacer { flex: 1 1 auto; }
.events-error {
  margin: 0;
  color: var(--color-danger);
  overflow-wrap: anywhere;
}
.events-table-wrap {
  max-width: 100%;
  min-width: 0;
  overflow-x: auto;
}
.events-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.875rem;
}
.events-table th,
.events-table td {
  text-align: start;
  padding: 0.4rem 0.6rem;
  border-bottom: 1px solid var(--color-border);
  overflow-wrap: anywhere;
  vertical-align: top;
}
.events-table th {
  font-size: 0.75rem;
  font-weight: 600;
  color: var(--color-muted);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.events-table code {
  font-family: var(--font-mono);
  font-size: 0.8125rem;
}
.events-table-wrap .btn { margin-top: 0.75rem; }
</style>
