<!-- Spec 065 L6 (owner, t1 4a31aa83, Q7 + Q10 yes): the release notes, ONE
     modal for every way in - the "Release notes" button on the version card
     (desktop footer, ChannelSidebar; phone strip, MobileStatusStrip) and the
     stable link /releases/<ref> (pages/releases/[ref].vue).

     One table, already expanded (owner, t1 55b6de46): the 30 latest changes,
     newest first, columns # / version / short sha / title. # is the hub's
     rolling `seq`, 1 = the oldest change of all, so the newest row shows n
     and a row keeps its number across loads. A version is a level-2 row
     inside the table carrying only the version ("you are here" on the
     running one), above the changes released under it. The title links to
     /releases/<sha>; a plain click shows that note in place: the plain-words
     What / How / Why first, the technical three below, the full sha with a
     copy button and the link.

     Reads (spec 065 L4, every signed-in member, Q11):
       GET /v1/release-notes?limit=30
           -> { off?, versions: [{ version, display, notes: [note + seq] }], next_before }
           (30 versions carry at least 30 changes; the newest 30 are shown)
       GET /v1/release-notes/<sha | 7+ prefix>  -> { note }
       GET /v1/release-notes/v<X.Y.Z>[-c<N>]    -> { version, display, notes }
     A version is keyed by its release key, the full tag (after 9.9.9 the
     mint starts over at 1.0.1 as v1.0.1-c2, owner t1 1c5b6d53), and shown
     plain (`display`, v1.0.1: "version is just a number", t1 e82eea7c).
     The mock tenant answers from a generated list (mockReleaseNotes). -->
<template>
  <UiDialog :open="open" :title="t('release_notes.title')" size="xl" @update:open="onOpen">
    <div class="rn" data-test="release-notes">
      <template v-if="note">
        <button type="button" class="rn__back" data-test="release-note-back" @click="showList">
          <UiIcon name="chevron-left" :size="16" /> {{ t('release_notes.back') }}
        </button>
        <article class="rn-note" data-test="release-note" :data-state="note.state" :data-sha="note.sha">
          <h3 class="rn-note__subject">{{ note.subject || shortSha(note.sha) }}</h3>
          <p class="rn-note__meta muted">
            <span v-if="note.version" data-test="release-note-version">{{ displayVersion(plainVersion(note.version)) }}</span>
            <span v-if="note.kind">{{ note.kind }}</span>
            <span v-if="note.area">{{ note.area }}</span>
          </p>
          <p v-if="stateText(note.state)" class="rn-note__state" :class="'is-' + note.state" data-test="release-note-state">{{ stateText(note.state) }}</p>
          <section v-if="hasAny(note, 'lay')" class="rn-note__part" data-test="release-note-lay">
            <h4>{{ t('release_notes.lay') }}</h4>
            <dl>
              <template v-for="k in PARTS" :key="'lay' + k">
                <template v-if="note['lay_' + k]">
                  <dt>{{ t('release_notes.' + k) }}</dt>
                  <dd>{{ note['lay_' + k] }}</dd>
                </template>
              </template>
            </dl>
          </section>
          <section v-if="hasAny(note, 'tech')" class="rn-note__part" data-test="release-note-tech">
            <h4>{{ t('release_notes.tech') }}</h4>
            <dl>
              <template v-for="k in PARTS" :key="'tech' + k">
                <template v-if="note['tech_' + k]">
                  <dt>{{ t('release_notes.' + k) }}</dt>
                  <dd>{{ note['tech_' + k] }}</dd>
                </template>
              </template>
            </dl>
          </section>
          <p class="rn-note__sha">
            <code dir="ltr" data-test="release-note-full-sha">{{ note.sha }}</code>
            <button
              type="button"
              class="rn__icon"
              data-test="release-note-copy"
              :title="copied === 'sha' ? t('code.copied') : t('code.copy')"
              :aria-label="copied === 'sha' ? t('code.copied') : t('code.copy')"
              @click="copy(note.sha, 'sha')"
            >
              <UiIcon :name="copied === 'sha' ? 'check' : 'copy'" :size="15" />
            </button>
          </p>
          <p class="rn-note__links">
            <a v-if="note.link" :href="note.link" target="_blank" rel="noopener" data-test="release-note-link">{{ t('release_notes.open_commit') }}</a>
            <button type="button" class="rn__linkbtn" data-test="release-note-copy-link" @click="copy(noteUrl(note.sha), 'link')">
              {{ copied === 'link' ? t('code.copied') : t('release_notes.copy_link') }}
            </button>
          </p>
        </article>
      </template>
      <template v-else>
        <p class="rn__lead muted" data-test="release-notes-lead">{{ t('release_notes.latest', { n: LATEST }) }}</p>
        <p v-if="message" class="muted" role="status" data-test="release-notes-message">{{ message }}</p>
        <p v-else-if="loading && !versions.length" class="muted">{{ t('common.loading') }}</p>
        <p v-else-if="!versions.length" class="muted" data-test="release-notes-empty">{{ t('release_notes.empty') }}</p>
        <table v-else class="rn-table" data-test="release-table">
          <thead>
            <tr>
              <th scope="col" class="rn-table__seq">{{ t('release_notes.col_seq') }}</th>
              <th scope="col" class="rn-table__ver">{{ t('release_notes.col_version') }}</th>
              <th scope="col" class="rn-table__sha">{{ t('release_notes.col_commit') }}</th>
              <th scope="col">{{ t('release_notes.col_title') }}</th>
            </tr>
          </thead>
          <tbody
            v-for="v in latest"
            :key="v.version || '-'"
            data-test="release-version"
            :data-version="v.version"
            :data-current="v.version === currentKey ? 'true' : undefined"
          >
            <tr class="rn-ver" data-test="release-version-head">
              <th colspan="4" scope="rowgroup" class="rn-ver__head">
                <span class="rn-ver__name" role="heading" aria-level="2">{{ shownVersion(v) || t('release_notes.unversioned') }}</span>
                <span v-if="v.version === currentKey" class="rn-ver__here" data-test="release-version-here">{{ t('release_notes.you_are_here') }}</span>
                <span v-else-if="liveIn(v)" class="rn-ver__newer" data-test="release-version-newer">{{ t('release_notes.newer_live') }}</span>
              </th>
            </tr>
            <tr v-for="n in v.notes" :key="n.sha" class="rn-row" data-test="release-row" :data-state="n.state" :data-seq="n.seq || undefined">
              <td class="rn-table__seq" data-test="release-row-seq">{{ n.seq || '' }}</td>
              <td class="rn-table__ver">{{ shownVersion(v) }}</td>
              <td class="rn-table__sha"><code dir="ltr" data-test="release-row-sha">{{ shortSha(n.sha) }}</code></td>
              <td class="rn-row__title">
                <a
                  :href="localePath('/releases/' + n.sha)"
                  data-test="release-row-title"
                  :data-sha="n.sha"
                  @click="onTitle($event, n)"
                >{{ n.subject || shortSha(n.sha) }}</a>
                <span v-if="badge(n.state)" class="rn-row__badge" :class="'is-' + n.state" data-test="release-row-badge">{{ badge(n.state) }}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </template>
    </div>
  </UiDialog>
</template>

<script setup lang="ts">
import { useCopyText } from '~/composables/useCopyText'
import { useBuildWatch } from '~/composables/useBuildWatch'
import { isNewer } from '~/utils/build-watch.mjs'
import { displayVersion } from '~/utils/display-version.mjs'

interface ReleaseNote {
  sha: string
  version?: string
  committed_at?: string
  kind?: string
  area?: string
  subject?: string
  lay_what?: string
  lay_how?: string
  lay_why?: string
  tech_what?: string
  tech_how?: string
  tech_why?: string
  state: string
  reverts?: string
  link?: string
  /** the rolling #, 1 = the oldest change (the hub's seq) */
  seq?: number
  [k: string]: string | number | undefined
}
interface ReleaseVersion { version: string, display?: string, notes: ReleaseNote[] }

const props = withDefaults(defineProps<{
  open: boolean
  /** a sha, a 7+ char prefix or v<X.Y.Z> to open on (the /releases/<ref> link) */
  initialRef?: string
}>(), { initialRef: '' })
const emit = defineEmits<{ 'update:open': [boolean] }>()

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const config = useRuntimeConfig()
const localePath = useLocalePath()
const buildWatch = useBuildWatch()
const { copied, copy } = useCopyText()

/* the changes shown; one page of this many versions carries at least as many */
const LATEST = 30
const PARTS = ['what', 'how', 'why'] as const
const SHA_RE = /^[0-9a-f]{7,40}$/
const VERSION_RE = /^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c([2-9]|[1-9][0-9]{1,3}))?$/

const running = computed(() => String(config.public.appVersion || '').trim())
const versions = ref<ReleaseVersion[]>([])
/* a release key as a reader sees it: v1.0.1-c2 -> v1.0.1 */
const plainVersion = (v: string) => String(v || '').replace(/-c[0-9]+$/, '')
const shownVersion = (v: ReleaseVersion) => displayVersion(v.display || plainVersion(v.version))
/* the running build's version is plain, so two cycles share it: the newest
   (first listed) release key carrying it is the one "you are here" marks */
const currentKey = computed(() => versions.value.find((v) => plainVersion(v.version) === running.value)?.version || '')
const loading = ref(false)
const message = ref('')
const note = ref<ReleaseNote | null>(null)

function onOpen(v: boolean) { emit('update:open', v) }
const shortSha = (s: string) => String(s || '').slice(0, 7)
const hasAny = (n: ReleaseNote, side: 'lay' | 'tech') => PARTS.some((k) => n[`${side}_${k}`])
function stateText(state: string) {
  return ['missing', 'backfill', 'skip', 'revert'].includes(state) ? t('release_notes.state_' + state) : ''
}
function badge(state: string) {
  if (state === 'missing') return t('release_notes.badge_missing')
  return state === 'ok' ? '' : stateText(state)
}
function noteUrl(sha: string) {
  return `${window.location.origin}${localePath('/releases/' + sha)}`
}

/* a newer build that is live but not loaded: mark the version carrying it */
function liveIn(v: ReleaseVersion) {
  const live = String(buildWatch.value.live || '')
  if (!live || !isNewer(buildWatch.value.running, live)) return false
  return v.notes.some((n) => n.sha.startsWith(live) || live.startsWith(n.sha))
}

/* the newest LATEST changes, still grouped under their versions */
const latest = computed(() => {
  const out: ReleaseVersion[] = []
  let left = LATEST
  for (const v of versions.value) {
    if (left <= 0) break
    const notes = v.notes.slice(0, left)
    left -= notes.length
    if (notes.length) out.push({ ...v, notes })
  }
  return out
})

async function hubGet(path: string): Promise<unknown> {
  if (api.mock) return mockReleaseNotes(path, running.value)
  const headers: Record<string, string> = { accept: 'application/json' }
  if (api.token) headers.authorization = `Bearer ${api.token}`
  const r = await fetch(`${api.base}${path}`, { credentials: api.credentials, headers })
  if (!r.ok) throw Object.assign(new Error(`release notes ${r.status}`), { status: r.status })
  return r.json()
}

async function loadLatest() {
  if (loading.value) return
  loading.value = true
  try {
    const body = await hubGet(`/v1/release-notes?limit=${LATEST}`) as { off?: boolean, versions?: ReleaseVersion[] }
    if (body?.off) message.value = t('release_notes.off')
    versions.value = body?.versions || []
  } catch {
    message.value = t('release_notes.error')
  } finally {
    loading.value = false
  }
}

function openNote(n: ReleaseNote) { note.value = n }
function showList() { note.value = null }
/* a plain click shows the note in place; a modified one opens /releases/<sha> */
function onTitle(e: MouseEvent, n: ReleaseNote) {
  if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
  e.preventDefault()
  openNote(n)
}

/* the /releases/<ref> link: a sha (or 7+ prefix) opens its note, v<X.Y.Z> its version */
async function openRef(raw: string) {
  const want = raw.trim().toLowerCase()
  if (!want) return
  if (!SHA_RE.test(want) && !VERSION_RE.test(want)) {
    message.value = t('release_notes.bad_ref', { ref: raw })
    return
  }
  try {
    const body = await hubGet(`/v1/release-notes/${encodeURIComponent(want)}`) as { note?: ReleaseNote, version?: string, display?: string, notes?: ReleaseNote[] }
    if (body?.note) {
      note.value = body.note
    } else if (body?.version) {
      const v = { version: body.version, display: body.display, notes: body.notes || [] }
      versions.value = [v]
    }
  } catch (e) {
    const status = (e as { status?: number }).status
    message.value = status === 404 ? t('release_notes.not_found', { ref: raw }) : t('release_notes.error')
  }
}

/* The mock tenant's release notes: 70 versions, two commits each, every
   state; the running version is the newest. Kept here so the dialog stays
   one file; it only runs on a mock build. */
const MOCK_VERSIONS = 70
const MOCK_STATES = ['ok', 'backfill', 'missing', 'ok', 'skip', 'revert']
const MOCK_KINDS = ['feat', 'fix', 'perf', 'docs']
const MOCK_AREAS = ['wui', 'hub', 'orc', 'iac']
function mockNote(j: number, version: string): ReleaseNote {
  const state = MOCK_STATES[j % MOCK_STATES.length] as string
  const area = MOCK_AREAS[j % MOCK_AREAS.length] as string
  const full = state === 'ok' || state === 'backfill'
  return {
    sha: (j + 1).toString(16).padStart(8, '0').repeat(5),
    version,
    kind: MOCK_KINDS[j % MOCK_KINDS.length],
    area,
    subject: `mock change ${j + 1}: the ${area} does a thing better`,
    lay_what: state === 'missing' ? '' : `Change number ${j + 1} makes something easier to use.`,
    lay_how: full ? 'The app now does the step for you.' : '',
    lay_why: state === 'missing' ? '' : 'You had to do it by hand before.',
    tech_what: full ? `Mock module ${j + 1} handles the case.` : '',
    tech_how: full ? 'One function call replaces three.' : '',
    tech_why: full ? 'The old path skipped the check.' : '',
    state,
    link: '',
    seq: MOCK_VERSIONS * 2 - j,
  }
}
function mockVersions(top: string): ReleaseVersion[] {
  const out: ReleaseVersion[] = []
  for (let i = 0; i < MOCK_VERSIONS; i++) {
    const version = i === 0 && VERSION_RE.test(top) ? top : `v0.1.${MOCK_VERSIONS - i}`
    out.push({ version, notes: [mockNote(i * 2, version), mockNote(i * 2 + 1, version)] })
  }
  return out
}
function mockReleaseNotes(path: string, top: string): unknown {
  const rows = mockVersions(top)
  const u = new URL(path, 'http://mock.invalid')
  const want = decodeURIComponent(u.pathname.replace(/^\/v1\/release-notes\/?/, ''))
  if (!want) {
    const before = u.searchParams.get('before') || ''
    const limit = Number(u.searchParams.get('limit')) || LATEST
    const from = before ? rows.findIndex((v) => v.version === before) + 1 : 0
    const page = rows.slice(from, from + limit)
    return { versions: page, next_before: from + limit < rows.length ? page[page.length - 1]?.version || '' : '' }
  }
  if (VERSION_RE.test(want)) {
    const v = rows.find((x) => x.version === want)
    if (v) return v
  } else {
    const hits = rows.flatMap((v) => v.notes).filter((n) => n.sha.startsWith(want))
    if (hits.length === 1) return { note: hits[0] }
  }
  throw Object.assign(new Error('not found'), { status: 404 })
}

/* last: the immediate watch runs start() during setup, so everything it
   reaches (the mock's constants too) must be initialised above it */
let started = false
async function start() {
  if (started) return
  started = true
  await loadLatest()
  if (props.initialRef) await openRef(props.initialRef)
}
watch(() => props.open, (o) => { if (o) void start() }, { immediate: true })
watch(() => props.initialRef, (r, old) => {
  if (!r || r === old || !started) return
  note.value = null
  message.value = ''
  void openRef(r)
})
</script>

<style scoped>
.rn { display: flex; flex-direction: column; gap: 0.5rem; min-width: 0; }
.rn__lead { margin: 0; }
.rn__back, .rn__linkbtn { font: inherit; color: var(--color-accent); background: none; border: 0; padding: 0.25rem 0; cursor: pointer; display: inline-flex; align-items: center; gap: 0.25rem; align-self: flex-start; }
.rn__linkbtn { text-decoration: underline; }
.rn__icon { font: inherit; color: var(--color-muted); background: none; border: 0; padding: 0.25rem; cursor: pointer; display: inline-flex; }
.rn-table { width: 100%; border-collapse: collapse; }
.rn-table th, .rn-table td { padding: 0.25rem 0.4rem; text-align: start; vertical-align: baseline; }
.rn-table thead th { font-size: 0.8125rem; color: var(--color-muted); font-weight: 600; border-bottom: 1px solid var(--color-border); }
.rn-table__seq, .rn-table__ver, .rn-table__sha { white-space: nowrap; }
.rn-table td.rn-table__seq { color: var(--color-muted); font-variant-numeric: tabular-nums; text-align: end; }
.rn-table .rn-ver__head { padding-top: 0.75rem; border-bottom: 1px solid var(--color-border); }
.rn-ver__name { font-weight: 600; margin-inline-end: 0.5rem; }
.rn-ver__here, .rn-ver__newer { font-size: 0.8125rem; font-weight: 400; padding: 0 0.4rem; border-radius: var(--radius-pill); border: 1px solid currentColor; }
.rn-ver__here { color: var(--color-ok); }
.rn-ver__newer { color: var(--color-warn); }
.rn-row__title { overflow-wrap: anywhere; min-width: 0; }
.rn-row__title a { color: var(--color-accent); }
.rn-row__badge { margin-inline-start: 0.4rem; }
.rn-row__badge, .rn-note__state { font-size: 0.8125rem; color: var(--color-muted); font-style: italic; }
.rn-row__badge.is-missing, .rn-note__state.is-missing { color: var(--color-warn); font-style: normal; }
.rn-note { display: flex; flex-direction: column; gap: 0.5rem; min-width: 0; }
.rn-note__subject { margin: 0; font-size: 1.0625rem; overflow-wrap: anywhere; }
.rn-note__meta { margin: 0; display: flex; gap: 0.75rem; flex-wrap: wrap; }
.rn-note__state { margin: 0; }
.rn-note__part h4 { margin: 0.5rem 0 0.25rem; font-size: 0.9375rem; }
.rn-note__part dl { margin: 0; display: grid; grid-template-columns: max-content 1fr; gap: 0.25rem 0.75rem; }
.rn-note__part dt { font-weight: 600; }
.rn-note__part dd { margin: 0; overflow-wrap: anywhere; }
.rn-note__sha { margin: 0; display: flex; align-items: center; gap: 0.25rem; min-width: 0; }
.rn-note__sha code { overflow-wrap: anywhere; }
.rn-note__links { margin: 0; display: flex; gap: 1rem; flex-wrap: wrap; align-items: center; }
@media (pointer: coarse) {
  .rn__linkbtn, .rn__back, .rn__icon { min-height: 44px; }
  .rn-row td { padding-block: 0.6rem; }
}
</style>
