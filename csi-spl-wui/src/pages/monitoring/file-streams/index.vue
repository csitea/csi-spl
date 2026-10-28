<!-- Spec 160 3.5 (SPL-3888, row B5; owner HUM-10, t1 c168784c, GO 44ec2e44
     and 5c6686f2): Monitoring -> File streams, a box file followed live.
     Two selects, Box then File; the pick is in the URL (?box=&stream=), so
     it survives a reload and Back. The view: a monospace list, newest at the
     bottom, at most FS_VIEW_MAX lines (the oldest dropped), a line's UTC
     time on hover, marker lines styled apart, long lines wrapped. Follow
     (default on) keeps the bottom in view; scrolling up turns it off, "Jump
     to latest" back on. Pause stops the poll; Resume fetches what came
     meanwhile (after=<last seq>, pages of FS_PAGE) and says how many. Find
     in view filters the loaded lines. A search hit (?seq=, spec 160 3.6)
     opens the view at that line with Follow off. The routes answer the
     workspace's owner or an admin only (3.4); anyone else reaching the URL
     sees the 403 as a sentence. The poll: every FS_POLL_MS while the tab is
     visible and not paused (decision D3). -->
<template>
  <div class="monitoring-file-streams" data-test="fs-page">
    <p v-if="state === 'loading'" class="muted" data-test="fs-loading">{{ t('monitoring.file_streams.loading') }}</p>
    <p v-else-if="state === 'forbidden'" class="fs-error" data-test="fs-forbidden">{{ t('monitoring.file_streams.forbidden') }}</p>
    <p v-else-if="state === 'error'" class="fs-error" data-test="fs-error">
      {{ t('monitoring.file_streams.error') }}
      <button type="button" class="btn" data-test="fs-retry" @click="loadStreams()">{{ t('monitoring.tokens.retry') }}</button>
    </p>
    <p v-else-if="streams.length === 0" class="muted" data-test="fs-none">{{ t('monitoring.file_streams.none') }}</p>

    <template v-else>
      <div class="fs-pick">
        <label class="fs-field">
          <span>{{ t('monitoring.file_streams.box') }}</span>
          <select :value="pick.box" data-test="fs-box" @change="onBox(($event.target as HTMLSelectElement).value)">
            <option v-for="b in boxes" :key="b" :value="b">{{ b }}</option>
          </select>
        </label>
        <label class="fs-field">
          <span>{{ t('monitoring.file_streams.file') }}</span>
          <select :value="pick.stream" data-test="fs-file" @change="onStream(($event.target as HTMLSelectElement).value)">
            <option v-for="s in boxStreams" :key="s.id" :value="s.streamKey" :title="s.path">{{ s.streamKey }}</option>
          </select>
        </label>
        <label class="fs-field fs-find">
          <span>{{ t('monitoring.file_streams.find') }}</span>
          <input v-model="find" type="search" data-test="fs-find">
        </label>
      </div>

      <div class="fs-bar">
        <label class="fs-check">
          <input type="checkbox" :checked="follow" data-test="fs-follow" @change="setFollow(($event.target as HTMLInputElement).checked)">
          {{ t('monitoring.file_streams.follow') }}
        </label>
        <button type="button" class="btn" :aria-pressed="paused ? 'true' : 'false'" data-test="fs-pause" @click="togglePause()">
          {{ paused ? t('monitoring.file_streams.resume') : t('monitoring.file_streams.pause') }}
        </button>
        <button v-if="!follow" type="button" class="btn" data-test="fs-jump" @click="jumpLatest()">{{ t('monitoring.file_streams.jump_latest') }}</button>
        <span v-if="newCount > 0" class="fs-new" role="status" data-test="fs-new">{{ t('monitoring.file_streams.new_lines', { n: newCount }, newCount) }}</span>
      </div>
      <p v-if="current && current.state !== 'following'" class="muted" data-test="fs-not-following">
        {{ t('monitoring.file_streams.not_following', { state: current.reason || current.state }) }}
      </p>

      <div ref="viewEl" class="fs-view" tabindex="0" :aria-label="t('monitoring.file_streams.log_label', { file: pick.stream })" data-test="fs-view" @scroll="onScroll">
        <button v-if="lines.length && lines[0].seq > 1" type="button" class="btn fs-older" data-test="fs-older" @click="loadOlder()">{{ t('monitoring.file_streams.load_older') }}</button>
        <p v-if="shown.length === 0" class="muted" data-test="fs-empty">{{ t('monitoring.file_streams.empty') }}</p>
        <div v-for="l in shown" :key="l.seq" class="fs-line" :class="{ 'fs-marker': l.marker, 'fs-hit': l.seq === hitSeq }" :title="l.at" :data-seq="l.seq" data-test="fs-line">{{ l.text }}</div>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import {
  FS_FIRST, FS_PAGE, atBottom, fileStreamBoxes, fileStreamLinesOf, fileStreamPickOf, fileStreamQuery, fileStreamsOf,
  filterFileStreamLines, lastSeqOf, mergeFileStreamLines, startFileStreamPoll,
} from '~/utils/monitoring-file-streams.mjs'

type FsApi = {
  getFileStreams: () => Promise<unknown>
  getFileStreamLines: (id: string, q?: { after?: number, before?: number, limit?: number }) => Promise<unknown>
}
type Stream = ReturnType<typeof fileStreamsOf>[number]
type Line = ReturnType<typeof fileStreamLinesOf>[number]

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const router = useRouter()
const api = () => useSpoolApi() as unknown as FsApi

const state = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')
const streams = ref<Stream[]>([])
const pick = ref({ box: '', stream: '', id: '', seq: 0 })
const lines = ref<Line[]>([])
const follow = ref(true)
const paused = ref(false)
const newCount = ref(0)
const find = ref('')
const hitSeq = ref(0)
const viewEl = ref<HTMLElement | null>(null)

const boxes = computed(() => fileStreamBoxes(streams.value))
const boxStreams = computed(() => streams.value.filter((s) => s.boxId === pick.value.box))
const current = computed(() => streams.value.find((s) => s.id === pick.value.id) || null)
const shown = computed(() => filterFileStreamLines(lines.value, find.value))

/* a stale answer (the pick changed meanwhile) is dropped */
let gen = 0
function failed(e: unknown) {
  state.value = (e as { status?: number })?.status === 403 ? 'forbidden' : 'error'
}

async function loadStreams() {
  state.value = 'loading'
  try {
    streams.value = fileStreamsOf(await api().getFileStreams())
    state.value = 'ok'
    await openPick(fileStreamPickOf(route.query, streams.value))
  } catch (e) {
    failed(e)
  }
}

/** Show a pick: the newest lines, or (a search hit) the lines up to and after seq with Follow off. */
async function openPick(p: ReturnType<typeof fileStreamPickOf>) {
  const mine = ++gen
  pick.value = p
  lines.value = []
  newCount.value = 0
  hitSeq.value = p.seq
  follow.value = p.seq === 0
  if (!p.id) return
  try {
    let got = fileStreamLinesOf(await api().getFileStreamLines(p.id, p.seq ? { before: p.seq + 1, limit: FS_FIRST } : { limit: FS_FIRST }))
    if (p.seq) got = mergeFileStreamLines(got, fileStreamLinesOf(await api().getFileStreamLines(p.id, { after: p.seq, limit: FS_FIRST })))
    if (mine !== gen) return
    lines.value = got
    await nextTick()
    if (p.seq) scrollToSeq(p.seq)
    else scrollBottom()
  } catch (e) {
    if (mine === gen) failed(e)
  }
}

/** The lines after the newest one in view: one page, or (resume) every page; the count added. */
async function fetchNew(all: boolean): Promise<number> {
  const mine = gen
  const id = pick.value.id
  let added = 0
  for (;;) {
    const got = fileStreamLinesOf(await api().getFileStreamLines(id, { after: lastSeqOf(lines.value), limit: FS_PAGE }))
    if (mine !== gen) return 0
    lines.value = mergeFileStreamLines(lines.value, got)
    added += got.length
    if (!all || got.length < FS_PAGE) break
  }
  if (added && follow.value) {
    await nextTick()
    scrollBottom()
  }
  return added
}

async function poll() {
  if (!pick.value.id || state.value !== 'ok') return
  try {
    await fetchNew(false)
  } catch { /* the next poll tries again */ }
}

async function loadOlder() {
  const first = lines.value[0]
  if (!first || !pick.value.id) return
  const mine = gen
  const el = viewEl.value
  const before = el ? el.scrollHeight - el.scrollTop : 0
  try {
    const got = fileStreamLinesOf(await api().getFileStreamLines(pick.value.id, { before: first.seq, limit: FS_FIRST }))
    if (mine !== gen) return
    lines.value = mergeFileStreamLines(got, lines.value)
    await nextTick()
    if (el) el.scrollTop = el.scrollHeight - before
  } catch { /* the button stays */ }
}

function scrollBottom() {
  const el = viewEl.value
  if (el) el.scrollTop = el.scrollHeight
}
function scrollToSeq(seq: number) {
  const row = viewEl.value?.querySelector(`[data-seq="${seq}"]`) as HTMLElement | null
  if (row) row.scrollIntoView({ block: 'center' })
}

/* Follow off when the reader scrolls up (C20); a programmatic scroll to the bottom keeps it */
function onScroll() {
  if (follow.value && !atBottom(viewEl.value)) follow.value = false
}
function setFollow(on: boolean) {
  follow.value = on
  if (on) void nextTick().then(scrollBottom)
}
function jumpLatest() {
  hitSeq.value = 0
  setFollow(true)
}

async function togglePause() {
  if (!paused.value) {
    paused.value = true
    newCount.value = 0
    return
  }
  paused.value = false
  try {
    newCount.value = await fetchNew(true)
  } catch { /* the poll catches up */ }
}

function go(box: string, stream: string) {
  void router.replace({ query: fileStreamQuery(box, stream) })
}
function onBox(box: string) {
  const first = streams.value.find((s) => s.boxId === box)
  go(box, first ? first.streamKey : '')
}
function onStream(stream: string) {
  go(pick.value.box, stream)
}
watch(() => [route.query.box, route.query.stream, route.query.seq], () => {
  if (state.value === 'ok') void openPick(fileStreamPickOf(route.query, streams.value))
})

let timer: ReturnType<typeof startFileStreamPoll> | null = null
onMounted(() => {
  void loadStreams()
  timer = startFileStreamPoll({ load: () => { void poll() }, visibility: () => document.visibilityState, paused: () => paused.value })
})
onBeforeUnmount(() => {
  if (timer) timer.stop()
  gen++
})
</script>

<style scoped>
.monitoring-file-streams { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
.fs-error { color: var(--color-danger); display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.fs-pick, .fs-bar { display: flex; flex-wrap: wrap; align-items: end; gap: 8px 16px; }
.fs-field { display: flex; flex-direction: column; gap: 4px; font-size: 0.875rem; min-width: 0; }
.fs-field select, .fs-field input { max-width: 100%; }
.fs-find { flex: 1 1 12rem; }
.fs-check { display: inline-flex; align-items: center; gap: 6px; }
.fs-new { color: var(--color-muted); font-size: 0.875rem; }
/* the log: monospace, wrapped, never a sideways scroll (3.5) */
.fs-view { height: min(60vh, 640px); overflow-y: auto; overflow-x: hidden; border: 1px solid var(--color-border);
  border-radius: var(--radius-md, 6px); padding: 6px 8px; font-family: var(--font-mono); font-size: 0.8125rem; line-height: 1.45; }
.fs-line { white-space: pre-wrap; overflow-wrap: anywhere; }
.fs-marker { color: var(--color-muted); font-style: italic; }
.fs-hit { background: var(--color-highlight, rgba(255, 213, 0, 0.25)); }
.fs-older { margin-bottom: 6px; }
/* a phone: the selects stacked */
@media (max-width: 600px) {
  .fs-pick { flex-direction: column; align-items: stretch; }
}
</style>
