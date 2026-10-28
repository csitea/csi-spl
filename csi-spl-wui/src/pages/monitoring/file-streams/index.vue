<!-- Spec 160 3.5 (SPL-3888, row B5; the list SPL-4124, row B8; owner
     HUM-10, t1 c168784c, GO 44ec2e44 and 5c6686f2, list msg b2717710):
     Monitoring -> File streams, every box's followed files as a list. Under
     each box a row per file: its key (the path as hover and second line),
     state, last line time and lines total, and its own tail -f button. The
     button opens THAT file's live view under its row (one open file at a
     time, never a merged output); pressed again it closes. The open file is
     in the URL (?box=&stream=), so it survives a reload and Back; only a
     file the hub returned opens, never a typed path. The view: a monospace
     list, newest at the bottom, at most FS_VIEW_MAX lines (the oldest
     dropped), a line's UTC time on hover, marker lines styled apart, long
     lines wrapped. Follow (default on) keeps the bottom in view; scrolling
     up turns it off, "Jump to latest" back on. Pause stops the poll; Resume
     fetches what came meanwhile (after=<last seq>, pages of FS_PAGE) and
     says how many. Find in view filters the loaded lines. A search hit
     (?seq=, spec 160 3.6) opens the view at that line with Follow off. The
     routes answer the workspace's owner or an admin only (3.4); anyone else
     reaching the URL sees the 403 as a sentence. The poll: every FS_POLL_MS
     while the tab is visible, a file is open and not paused (decision D3). -->
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
      <section v-for="g in groups" :key="g.boxId" class="fs-group" :data-box="g.boxId" data-test="fs-group">
        <h3 class="fs-box-name">{{ g.boxId }}</h3>
        <ul class="fs-rows">
          <li v-for="s in g.streams" :key="s.id" class="fs-row" :class="{ 'fs-row-open': s.id === pick.id }" :data-stream="s.streamKey" data-test="fs-row">
            <div class="fs-row-head">
              <div class="fs-name">
                <span class="fs-key" :title="s.path">{{ s.streamKey }}</span>
                <span class="fs-path muted">{{ s.path }}</span>
              </div>
              <code class="fs-state" :class="{ 'fs-state-off': s.state !== 'following' }" data-test="fs-state">{{ s.state }}</code>
              <span class="fs-meta muted" :title="s.lastLineAt ? s.lastLineAt : undefined" data-test="fs-last">
                {{ s.lastLineAt ? t('monitoring.file_streams.last_line', { at: isoDateTime(s.lastLineAt) }) : t('monitoring.file_streams.empty') }}
              </span>
              <span class="fs-meta muted" data-test="fs-total">{{ t('monitoring.file_streams.lines_total', { n: s.linesTotal }, s.linesTotal) }}</span>
              <button type="button" class="btn fs-tail" :aria-pressed="s.id === pick.id ? 'true' : 'false'" :title="t('monitoring.file_streams.tail_title', { file: s.streamKey })" data-test="fs-tail" @click="onTail(s)">{{ t('monitoring.file_streams.tail') }}</button>
            </div>

            <div v-if="s.id === pick.id" class="fs-open">
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
                <label class="fs-field fs-find">
                  <span>{{ t('monitoring.file_streams.find') }}</span>
                  <input v-model="find" type="search" data-test="fs-find">
                </label>
              </div>
              <p v-if="s.state !== 'following'" class="muted" data-test="fs-not-following">
                {{ t('monitoring.file_streams.not_following', { state: s.reason || s.state }) }}
              </p>
              <div ref="viewRefs" class="fs-view" tabindex="0" :aria-label="t('monitoring.file_streams.log_label', { file: s.streamKey })" data-test="fs-view" @scroll="onScroll">
                <button v-if="lines.length && lines[0].seq > 1" type="button" class="btn fs-older" data-test="fs-older" @click="loadOlder()">{{ t('monitoring.file_streams.load_older') }}</button>
                <p v-if="shown.length === 0" class="muted" data-test="fs-empty">{{ t('monitoring.file_streams.empty') }}</p>
                <div v-for="l in shown" :key="l.seq" class="fs-line" :class="{ 'fs-marker': l.marker, 'fs-hit': l.seq === hitSeq }" :title="l.at" :data-seq="l.seq" data-test="fs-line">{{ l.text }}</div>
              </div>
            </div>
          </li>
        </ul>
      </section>
    </template>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { isoDateTime } from '~/utils/date-iso.mjs'
import {
  FS_FIRST, FS_PAGE, atBottom, fileStreamGroupsOf, fileStreamLinesOf, fileStreamOpenOf, fileStreamQuery, fileStreamsOf,
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
/* the one open view sits in a v-for row, so its template ref is an array */
const viewRefs = ref<HTMLElement[] | HTMLElement | null>(null)
const viewEl = computed<HTMLElement | null>(() => (Array.isArray(viewRefs.value) ? viewRefs.value[0] || null : viewRefs.value))

const groups = computed(() => fileStreamGroupsOf(streams.value))
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
    await openPick(fileStreamOpenOf(route.query, streams.value))
  } catch (e) {
    failed(e)
  }
}

/** Open a file: the newest lines, or (a search hit) the lines up to and after seq with Follow off. */
async function openPick(p: ReturnType<typeof fileStreamOpenOf>) {
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

/* each tail -f click is a history entry, so Back opens the file before; pressed on the open file it closes */
function onTail(s: Stream) {
  const open = s.id === pick.value.id
  void router.push({ query: open ? {} : fileStreamQuery(s.boxId, s.streamKey) })
}
watch(() => [route.query.box, route.query.stream, route.query.seq], () => {
  if (state.value === 'ok') void openPick(fileStreamOpenOf(route.query, streams.value))
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
.fs-bar { display: flex; flex-wrap: wrap; align-items: end; gap: 8px 16px; }
.fs-group { display: flex; flex-direction: column; gap: 6px; min-width: 0; }
.fs-box-name { margin: 0; font-size: 1rem; }
.fs-rows { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
.fs-row { border: 1px solid var(--color-border); border-radius: var(--radius-md, 6px); padding: 6px 8px; min-width: 0; }
.fs-row-head { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 16px; min-width: 0; }
.fs-name { display: flex; flex-direction: column; flex: 1 1 12rem; min-width: 0; }
.fs-key { font-weight: 600; overflow-wrap: anywhere; }
.fs-path { font-family: var(--font-mono); font-size: 0.8125rem; overflow-wrap: anywhere; }
.fs-state { font-size: 0.8125rem; }
.fs-state-off { color: var(--color-danger); }
.fs-meta { font-size: 0.875rem; }
.fs-open { display: flex; flex-direction: column; gap: 8px; margin-top: 8px; min-width: 0; }
.fs-field { display: flex; flex-direction: column; gap: 4px; font-size: 0.875rem; min-width: 0; }
.fs-field input { max-width: 100%; }
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
/* a phone: a row's facts and button wrap under its name */
@media (max-width: 600px) {
  .fs-row-head { flex-direction: column; align-items: stretch; }
}
</style>
