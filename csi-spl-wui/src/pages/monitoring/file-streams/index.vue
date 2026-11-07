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
     while the tab is visible, a file is open and not paused (decision D3).
     File globs (3.8, row B12, SPL-4695, owner answer B, poll 376e9435): under
     each box its typed globs, each with the state only the box reports
     (pending until it does: never "following" before the box says so) and
     "N of M matches followed", a Remove that asks first, the folders the
     box announced, and "Add a file glob" (key and glob; the hub's refusal
     shown as its code's sentence). Below the boxes, the newest 50 glob
     changes. Drawn for the workspace's owner or an admin only (the routes'
     gate), never on operator status.
     A file out of the view (3.10, SPL-4979, owner msg 5bb5d078): each row has
     a Remove that asks first; the hub keeps the removal and the box stops
     following it. Under the box "Removed files" lists them, each with a Put
     back. -->
<template>
  <div class="monitoring-file-streams" data-test="fs-page">
    <p v-if="state === 'loading'" class="muted" data-test="fs-loading">{{ t('monitoring.file_streams.loading') }}</p>
    <p v-else-if="state === 'forbidden'" class="fs-error" data-test="fs-forbidden">{{ t('monitoring.file_streams.forbidden') }}</p>
    <p v-else-if="state === 'error'" class="fs-error" data-test="fs-error">
      {{ t('monitoring.file_streams.error') }}
      <button type="button" class="btn" data-test="fs-retry" @click="loadStreams()">{{ t('monitoring.tokens.retry') }}</button>
    </p>
    <p v-else-if="groups.length === 0" class="muted" data-test="fs-none">{{ t('monitoring.file_streams.none') }}</p>

    <template v-else>
      <p v-if="streams.length === 0" class="muted" data-test="fs-none">{{ t('monitoring.file_streams.none') }}</p>
      <p v-if="globsState === 'error'" class="fs-error" data-test="fs-globs-error">{{ t('monitoring.file_streams.glob.unavailable') }}</p>
      <section v-for="g in groups" :key="g.boxId" class="fs-group" :data-box="g.boxId" data-test="fs-group">
        <h3 class="fs-box-name">{{ g.boxId }}</h3>
        <ul v-if="g.streams.length" class="fs-rows">
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
              <button v-if="asking !== s.id" type="button" class="btn" data-test="fs-remove" @click="askRemove(s.id)">{{ t('monitoring.file_streams.glob.remove') }}</button>
            </div>
            <div v-if="asking === s.id" class="fs-ask" role="alertdialog" :aria-label="t('monitoring.file_streams.file.remove_ask', { key: s.streamKey })" data-test="fs-remove-confirm">
              <span>{{ t('monitoring.file_streams.file.remove_ask', { key: s.streamKey }) }}</span>
              <button type="button" class="btn" :disabled="busy" data-test="fs-remove-yes" @click="removeFile(s)">{{ t('monitoring.file_streams.glob.remove') }}</button>
              <button type="button" class="btn" data-test="fs-remove-no" @click="asking = ''">{{ t('monitoring.file_streams.glob.keep') }}</button>
            </div>
            <p v-if="rowErr.id === s.id" class="fs-error" :data-code="rowErr.code" data-test="fs-row-error">{{ t(rowErr.key) }}</p>

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

        <div v-if="g.removed.length" class="fs-globs" data-test="fs-removed">
          <h4 class="fs-globs-title">{{ t('monitoring.file_streams.file.removed_title') }}</h4>
          <ul class="fs-rows">
            <li v-for="s in g.removed" :key="s.id" class="fs-row" :data-stream="s.streamKey" data-test="fs-removed-row">
              <div class="fs-row-head">
                <div class="fs-name">
                  <span class="fs-key">{{ s.streamKey }}</span>
                  <span class="fs-path muted">{{ s.path }}</span>
                </div>
                <button type="button" class="btn" :disabled="busy" data-test="fs-put-back" @click="putBack(s)">{{ t('monitoring.file_streams.file.put_back') }}</button>
              </div>
              <p v-if="rowErr.id === s.id" class="fs-error" :data-code="rowErr.code" data-test="fs-row-error">{{ t(rowErr.key) }}</p>
            </li>
          </ul>
        </div>

        <div v-if="canGlob" class="fs-globs" data-test="fs-globs">
          <h4 class="fs-globs-title">{{ t('monitoring.file_streams.glob.title') }}</h4>
          <p class="muted fs-folders" data-test="fs-glob-folders">
            {{ allowedOf(g.folders).length ? t('monitoring.file_streams.glob.folders', { list: allowedOf(g.folders).join(', ') }) : t('monitoring.file_streams.glob.no_folders') }}
          </p>
          <ul v-if="g.globs.length" class="fs-rows">
            <li v-for="x in g.globs" :key="x.id" class="fs-row fs-glob" :data-glob="x.key" data-test="fs-glob">
              <div class="fs-row-head">
                <div class="fs-name">
                  <span class="fs-key">{{ x.key }}</span>
                  <code class="fs-path" data-test="fs-glob-text">{{ x.glob }}</code>
                </div>
                <span class="fs-state" :class="{ 'fs-state-off': x.state !== 'following' }" :data-state="x.state" data-test="fs-glob-state">{{ t(fileStreamGlobStateKey(x.state)) }}</span>
                <span v-if="fileStreamGlobCounted(x)" class="fs-meta muted" data-test="fs-glob-matches">
                  {{ t('monitoring.file_streams.glob.matches', { followed: x.followed, matched: x.matched }) }}
                </span>
                <span v-if="fileStreamGlobCounted(x) && x.overCap" class="fs-meta muted" data-test="fs-glob-over-cap">{{ t('monitoring.file_streams.glob.over_cap', { n: x.overCap }) }}</span>
                <span v-if="x.reason" class="fs-meta muted" data-test="fs-glob-reason">{{ t('monitoring.file_streams.glob.reason', { reason: x.reason }) }}</span>
                <button v-if="asking !== x.id" type="button" class="btn" data-test="fs-glob-remove" @click="askRemove(x.id)">{{ t('monitoring.file_streams.glob.remove') }}</button>
              </div>
              <div v-if="asking === x.id" class="fs-ask" role="alertdialog" :aria-label="t('monitoring.file_streams.glob.remove_ask', { key: x.key })" data-test="fs-glob-confirm">
                <span>{{ t('monitoring.file_streams.glob.remove_ask', { key: x.key }) }}</span>
                <button type="button" class="btn" :disabled="busy" data-test="fs-glob-remove-yes" @click="removeGlob(x.id)">{{ t('monitoring.file_streams.glob.remove') }}</button>
                <button type="button" class="btn" data-test="fs-glob-remove-no" @click="asking = ''">{{ t('monitoring.file_streams.glob.keep') }}</button>
              </div>
              <p v-if="rowErr.id === x.id" class="fs-error" :data-code="rowErr.code" data-test="fs-glob-row-error">{{ t(rowErr.key) }}</p>
            </li>
          </ul>
          <p v-else class="muted" data-test="fs-glob-none">{{ t('monitoring.file_streams.glob.none') }}</p>

          <button v-if="adding !== g.boxId" type="button" class="btn fs-glob-add" data-test="fs-glob-add" @click="openAdd(g.boxId)">{{ t('monitoring.file_streams.glob.add') }}</button>
          <form v-else class="fs-glob-form" :aria-label="t('monitoring.file_streams.glob.add')" data-test="fs-glob-form" @submit.prevent="addGlob(g.boxId)">
            <label class="fs-field">
              <span>{{ t('monitoring.file_streams.glob.key') }}</span>
              <input v-model="form.key" type="text" maxlength="24" autocomplete="off" spellcheck="false" required data-test="fs-glob-key">
              <small class="muted">{{ t('monitoring.file_streams.glob.key_hint') }}</small>
            </label>
            <label class="fs-field fs-glob-field">
              <span>{{ t('monitoring.file_streams.glob.glob') }}</span>
              <input v-model="form.glob" type="text" maxlength="512" autocomplete="off" spellcheck="false" required data-test="fs-glob-glob">
              <small class="muted">{{ t('monitoring.file_streams.glob.glob_hint') }}</small>
            </label>
            <div class="fs-bar">
              <button type="submit" class="btn" :disabled="busy" data-test="fs-glob-submit">{{ busy ? t('monitoring.file_streams.glob.adding') : t('monitoring.file_streams.glob.submit') }}</button>
              <button type="button" class="btn" data-test="fs-glob-cancel" @click="adding = ''">{{ t('monitoring.file_streams.glob.cancel') }}</button>
            </div>
            <p v-if="formErr.key" class="fs-error" role="alert" :data-code="formErr.code" data-test="fs-glob-error">{{ t(formErr.key) }}</p>
          </form>
        </div>
      </section>

      <section v-if="canGlob" class="fs-audit" data-test="fs-audit">
        <h3 class="fs-box-name">{{ t('monitoring.file_streams.glob.audit_title') }}</h3>
        <p v-if="audit.length === 0" class="muted" data-test="fs-audit-none">{{ t('monitoring.file_streams.glob.audit_none') }}</p>
        <ul v-else class="fs-audit-rows">
          <li v-for="a in audit" :key="a.id" class="fs-audit-row" :data-action="a.action" data-test="fs-audit-row">
            <span class="muted" :title="a.at">{{ isoDateTime(a.at) }}</span>
            <span>{{ a.boxId }}</span>
            <span class="fs-audit-action">{{ t('monitoring.file_streams.glob.audit.' + a.action) }}</span>
            <span class="fs-key">{{ a.key }}</span>
            <code class="fs-path">{{ a.glob }}</code>
            <span class="muted">{{ a.actor }}</span>
            <code v-if="a.reason" class="fs-state" data-test="fs-audit-reason">{{ a.reason }}</code>
          </li>
        </ul>
      </section>
    </template>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAccessStore } from '~/stores/access'
import { gateMe, staffReadable } from '~/utils/read-gates.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'
import {
  FS_FIRST, FS_GLOB_AUDIT_PAGE, FS_PAGE, atBottom, fileStreamGlobAuditOf, fileStreamGlobCounted, fileStreamGlobErrorKey, fileStreamGlobStateKey,
  fileStreamGlobsOf, fileStreamGroupsOf, fileStreamLinesOf, fileStreamOpenOf, fileStreamQuery, fileStreamRowErrorKey, fileStreamsOf, fileStreamsRemovedOf,
  filterFileStreamLines, lastSeqOf, mergeFileStreamLines, startFileStreamPoll,
} from '~/utils/monitoring-file-streams.mjs'

type FsApi = {
  getFileStreams: () => Promise<unknown>
  getFileStreamLines: (id: string, q?: { after?: number, before?: number, limit?: number }) => Promise<unknown>
  fileStreamGlobs: (op: 'list' | 'add' | 'remove' | 'audit' | 'file_remove' | 'file_restore', arg?: unknown) => Promise<unknown>
}
type Stream = ReturnType<typeof fileStreamsOf>[number]
type Line = ReturnType<typeof fileStreamLinesOf>[number]
type Globs = ReturnType<typeof fileStreamGlobsOf>
type Folder = Globs['folders'][number]
type AuditRow = ReturnType<typeof fileStreamGlobAuditOf>['rows'][number]

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const router = useRouter()
const api = () => useSpoolApi() as unknown as FsApi

const state = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')
const streams = ref<Stream[]>([])
const removed = ref<Stream[]>([])
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

const globs = ref<Globs>({ globs: [], folders: [] })
const globsState = ref<'off' | 'ok' | 'error'>('off')
const audit = ref<AuditRow[]>([])
const adding = ref('')
const asking = ref('')
const busy = ref(false)
const form = ref({ key: '', glob: '' })
const formErr = ref({ key: '', code: '' })
const rowErr = ref({ id: '', key: '', code: '' })
/* the glob form: only once the globs route answered this owner or admin (3.8.3's gate), never on operator status (C55) */
const canGlob = computed(() => state.value === 'ok' && globsState.value === 'ok')
const groups = computed(() => fileStreamGroupsOf(streams.value, globs.value, removed.value))
const shown = computed(() => filterFileStreamLines(lines.value, find.value))

/* a stale answer (the pick changed meanwhile) is dropped */
let gen = 0
function failed(e: unknown) {
  state.value = (e as { status?: number })?.status === 403 ? 'forbidden' : 'error'
}

const access = useAccessStore()
async function loadStreams() {
  state.value = 'loading'
  try {
    /* SPL-4453: a reader /v1/view/me names neither owner nor admin gets the line, no request */
    if (!staffReadable(await gateMe(access))) {
      state.value = 'forbidden'
      return
    }
    await readStreams()
    await loadGlobs()
    state.value = 'ok'
    await openPick(fileStreamOpenOf(route.query, streams.value))
  } catch (e) {
    failed(e)
  }
}

/** Both lists of the one read route: the files in the view, and those removed from it. */
async function readStreams() {
  const body = await api().getFileStreams()
  streams.value = fileStreamsOf(body)
  removed.value = fileStreamsRemovedOf(body)
}

/** The globs, the boxes' folders and the newest audit rows; a failure hides the form and says so, the streams stay. */
async function loadGlobs() {
  try {
    const [list, rows] = await Promise.all([api().fileStreamGlobs('list'), api().fileStreamGlobs('audit', { limit: FS_GLOB_AUDIT_PAGE })])
    globs.value = fileStreamGlobsOf(list)
    audit.value = fileStreamGlobAuditOf(rows).rows
    globsState.value = 'ok'
  } catch {
    globsState.value = 'error'
  }
}

function allowedOf(folders: Folder[]) {
  return folders.filter((f) => f.state === 'allowed').map((f) => f.path)
}

function openAdd(boxId: string) {
  adding.value = boxId
  form.value = { key: '', glob: '' }
  formErr.value = { key: '', code: '' }
}

const codeOf = (e: unknown) => String((e as { token?: string })?.token || (e as { status?: number })?.status || '')

/** Add a glob (C55): the body is {box_id, key, glob}; a refusal shows its code's sentence, the form stays. */
async function addGlob(boxId: string) {
  if (busy.value) return
  busy.value = true
  formErr.value = { key: '', code: '' }
  try {
    await api().fileStreamGlobs('add', { boxId, key: form.value.key, glob: form.value.glob })
    adding.value = ''
  } catch (e) {
    formErr.value = { key: fileStreamGlobErrorKey(e), code: codeOf(e) }
  } finally {
    busy.value = false
  }
  await loadGlobs()
}

function askRemove(id: string) {
  asking.value = id
  rowErr.value = { id: '', key: '', code: '' }
}

/** Remove a glob after the reader said yes: DELETE, then the list again. */
async function removeGlob(id: string) {
  if (busy.value) return
  busy.value = true
  try {
    await api().fileStreamGlobs('remove', id)
    asking.value = ''
  } catch (e) {
    rowErr.value = { id, key: fileStreamGlobErrorKey(e), code: codeOf(e) }
  } finally {
    busy.value = false
  }
  await loadGlobs()
}

/** A file's remove or put back, then both lists and the audit again; a refusal shows its sentence on the row. */
async function changeFile(op: 'file_remove' | 'file_restore', s: Stream) {
  if (busy.value) return
  busy.value = true
  rowErr.value = { id: '', key: '', code: '' }
  try {
    await api().fileStreamGlobs(op, s.id)
    asking.value = ''
  } catch (e) {
    rowErr.value = { id: s.id, key: fileStreamRowErrorKey(e), code: codeOf(e) }
  } finally {
    busy.value = false
  }
  try {
    await readStreams()
  } catch { /* the rows stay as they were, the next visit reads them */ }
  await loadGlobs()
}

/** Remove a file after the reader said yes; the open file closes when it is this one. */
async function removeFile(s: Stream) {
  await changeFile('file_remove', s)
  if (s.id === pick.value.id && !streams.value.some((x) => x.id === s.id)) void router.push({ query: {} })
}

async function putBack(s: Stream) {
  await changeFile('file_restore', s)
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
/* the globs under a box, and the audit list */
.fs-globs { display: flex; flex-direction: column; gap: 6px; margin-top: 4px; min-width: 0; }
.fs-globs-title { margin: 0; font-size: 0.875rem; }
.fs-folders { margin: 0; font-size: 0.875rem; overflow-wrap: anywhere; }
.fs-glob-add { align-self: flex-start; }
.fs-glob-form { display: flex; flex-wrap: wrap; align-items: end; gap: 8px 16px; min-width: 0; }
.fs-glob-field { flex: 1 1 16rem; }
.fs-glob-form .fs-error { flex-basis: 100%; margin: 0; }
.fs-ask { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-top: 6px; }
.fs-audit { display: flex; flex-direction: column; gap: 6px; min-width: 0; }
.fs-audit-rows { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
.fs-audit-row { display: flex; flex-wrap: wrap; gap: 4px 12px; font-size: 0.875rem; min-width: 0; overflow-wrap: anywhere; }
.fs-audit-action { font-weight: 600; }
/* a phone: a row's facts and button wrap under its name */
@media (max-width: 600px) {
  .fs-row-head { flex-direction: column; align-items: stretch; }
}
</style>
