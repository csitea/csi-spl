<!-- Spec 065 L6 (owner, t1 4a31aa83, Q7 + Q10 yes): the release notes, ONE
     modal for every way in - the "Release notes" button on the version card
     (desktop footer, ChannelSidebar; phone strip, MobileStatusStrip) and the
     stable link /releases/<ref> (pages/releases/[ref].vue).

     One table, already expanded (owner, t1 55b6de46): the 30 latest changes,
     newest first, columns # / version / short sha / committed / title. # is the hub's
     rolling `seq`, 1 = the oldest change of all, so the newest row shows n
     and a row keeps its number across loads. A version is a level-2 row
     inside the table carrying only the version ("you are here" on the
     running one), above the changes released under it. The title links to
     /releases/<sha>; a plain click shows that note in place: the plain-words
     What / How / Why first, the technical three below, the full sha with a
     copy button and the link.

     The look (owner, t1 3385cecb: "proper table, proper aligning, proper x,
     proper flow from click"): the table and the note are bordered cards in
     the theme tokens, the columns sized from the header row so every cell
     lines up under it, the version band spanning the row; on a phone the
     version column folds into its band. The X is UiDialog's. Back to the
     list returns to the row that was clicked.

     The time (owner, t1 3385cecb: "add also the push time"): the row's
     committed_at, YYYY-MM-DD HH:MM in the viewer's zone (date-iso.mjs), to
     the second with the zone on hover. The hub keeps no push time; the
     committer time is the push's within minutes, because every lane
     rebases onto trunk right before it pushes (n=60 pushes, 2026-10-07:
     median 20 s, max 237 s before the push's CI run), so the column says
     "Committed", not "Pushed". On a phone it is a line under the title.

     Reads (spec 065 L4, every signed-in member, Q11):
       GET /v1/release-notes?limit=30
           -> { off?, versions: [{ version, display, notes: [note + seq] }], next_before }
           (30 versions carry at least 30 changes; the newest 30 are shown)
       GET /v1/release-notes/<sha | 7+ prefix>  -> { note }
       GET /v1/release-notes/v<X.Y.Z>[-c<N>]    -> { version, display, notes }
     A version is keyed by its release key, the full tag (after 9.9.9 the
     mint starts over at 1.0.1 as v1.0.1-c2, owner t1 1c5b6d53), and shown
     plain (`display`, v1.0.1: "version is just a number", t1 e82eea7c).
     The mock tenant answers from a generated list (release-notes-api.mjs). -->
<template>
  <UiDialog :open="open" :title="t('release_notes.title')" size="xl" @update:open="onOpen">
    <div ref="rootEl" class="rn" data-test="release-notes">
      <template v-if="note">
        <button type="button" class="rn__back" data-test="release-note-back" @click="showList">
          <UiIcon name="chevron-left" :size="16" /> {{ t('release_notes.back') }}
        </button>
        <article class="rn-note rn-card" data-test="release-note" :data-state="note.state" :data-sha="note.sha">
          <header class="rn-note__head">
            <h3 class="rn-note__subject">{{ note.subject || shortSha(note.sha) }}</h3>
            <p v-if="note.version || note.kind || note.area || note.committed_at" class="rn-note__meta">
              <span v-if="note.version" class="rn-chip rn-chip--ver" data-test="release-note-version">{{ displayVersion(plainVersion(note.version)) }}</span>
              <span v-if="note.kind" class="rn-chip">{{ note.kind }}</span>
              <span v-if="note.area" class="rn-chip">{{ note.area }}</span>
              <time v-if="note.committed_at" class="rn-note__time" :datetime="note.committed_at" :title="fullTime(note.committed_at)" data-test="release-note-time">{{ t('release_notes.col_time') }} {{ isoDateTime(note.committed_at) }}</time>
            </p>
            <p v-if="stateText(note.state)" class="rn-note__state" :class="'is-' + note.state" data-test="release-note-state">{{ stateText(note.state) }}</p>
          </header>
          <!-- plain words first, technical beside it (below it on a narrow screen) -->
          <div v-if="sidesOf(note).length" class="rn-note__parts">
            <section v-for="side in sidesOf(note)" :key="side" class="rn-note__part" :data-test="'release-note-' + side">
              <h4>{{ t('release_notes.' + side) }}</h4>
              <dl>
                <template v-for="k in PARTS" :key="side + k">
                  <template v-if="note[side + '_' + k]">
                    <dt>{{ t('release_notes.' + k) }}</dt>
                    <dd>{{ note[side + '_' + k] }}</dd>
                  </template>
                </template>
              </dl>
            </section>
          </div>
          <footer class="rn-note__foot">
            <div class="rn-note__sha">
              <span class="rn-note__label">{{ t('release_notes.col_commit') }}</span>
              <code dir="ltr" data-test="release-note-full-sha">{{ note.sha }}</code>
              <button
                type="button"
                class="rn__icon"
                data-test="release-note-copy"
                :title="copied === 'sha' ? t('code.copied') : t('code.copy')"
                :aria-label="copied === 'sha' ? t('code.copied') : t('code.copy')"
                @click="copy(note.sha, 'sha')"
              >
                <UiIcon :name="copied === 'sha' ? 'check' : 'copy'" :size="16" />
              </button>
            </div>
            <div class="rn-note__links">
              <a v-if="note.link" :href="note.link" class="btn ghost rn__action" target="_blank" rel="noopener" data-test="release-note-link"><UiIcon name="open" :size="16" /> {{ t('release_notes.open_commit') }}</a>
              <button type="button" class="btn ghost rn__action" data-test="release-note-copy-link" @click="copy(noteUrl(note.sha), 'link')">
                <UiIcon :name="copied === 'link' ? 'check' : 'copy'" :size="16" />
                {{ copied === 'link' ? t('code.copied') : t('release_notes.copy_link') }}
              </button>
            </div>
          </footer>
        </article>
      </template>
      <template v-else>
        <p class="rn__lead muted" data-test="release-notes-lead">{{ t('release_notes.latest', { n: LATEST }) }}</p>
        <p v-if="message" class="rn__msg muted" role="status" data-test="release-notes-message">{{ message }}</p>
        <p v-else-if="loading && !versions.length" class="rn__msg muted">{{ t('common.loading') }}</p>
        <p v-else-if="!versions.length" class="rn__msg muted" data-test="release-notes-empty">{{ t('release_notes.empty') }}</p>
        <div v-else class="rn-card rn-table-wrap">
          <table class="rn-table" data-test="release-table">
            <thead>
              <tr>
                <th scope="col" class="rn-table__seq">{{ t('release_notes.col_seq') }}</th>
                <th v-if="!narrow" scope="col" class="rn-table__ver">{{ t('release_notes.col_version') }}</th>
                <th scope="col" class="rn-table__sha">{{ t('release_notes.col_commit') }}</th>
                <th v-if="!narrow" scope="col" class="rn-table__time">{{ t('release_notes.col_time') }}</th>
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
                <th :colspan="narrow ? 3 : 5" scope="rowgroup" class="rn-ver__head">
                  <span class="rn-ver__name" role="heading" aria-level="2">{{ shownVersion(v) || t('release_notes.unversioned') }}</span>
                  <span v-if="v.version === currentKey" class="rn-ver__here" data-test="release-version-here">{{ t('release_notes.you_are_here') }}</span>
                  <span v-else-if="liveIn(v)" class="rn-ver__newer" data-test="release-version-newer">{{ t('release_notes.newer_live') }}</span>
                </th>
              </tr>
              <tr v-for="n in v.notes" :key="n.sha" class="rn-row" data-test="release-row" :data-state="n.state" :data-seq="n.seq || undefined">
                <td class="rn-table__seq" data-test="release-row-seq">{{ n.seq || '' }}</td>
                <td v-if="!narrow" class="rn-table__ver">{{ shownVersion(v) }}</td>
                <td class="rn-table__sha"><code dir="ltr" data-test="release-row-sha">{{ shortSha(n.sha) }}</code></td>
                <td v-if="!narrow" class="rn-table__time">
                  <time v-if="n.committed_at" :datetime="n.committed_at" :title="fullTime(n.committed_at)" data-test="release-row-time">{{ isoDateTime(n.committed_at) }}</time>
                </td>
                <td class="rn-row__title">
                  <a
                    :href="localePath('/releases/' + n.sha)"
                    data-test="release-row-title"
                    :data-sha="n.sha"
                    @click="onTitle($event, n)"
                  >{{ n.subject || shortSha(n.sha) }}</a>
                  <span v-if="badge(n.state)" class="rn-row__badge" :class="'is-' + n.state" data-test="release-row-badge">{{ badge(n.state) }}</span>
                  <time v-if="narrow && n.committed_at" class="rn-row__time" :datetime="n.committed_at" :title="fullTime(n.committed_at)" data-test="release-row-time">{{ isoDateTime(n.committed_at) }}</time>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </template>
    </div>
  </UiDialog>
</template>

<script setup lang="ts">
import { useCopyText } from '~/composables/useCopyText'
import { useBuildWatch } from '~/composables/useBuildWatch'
import { isNewer } from '~/utils/build-watch.mjs'
import { displayVersion } from '~/utils/display-version.mjs'
import { browserTimeZone, isoDateTime, isoDateTimeSec, viewerTimeZone } from '~/utils/date-iso.mjs'
import { releaseNotesGet } from '~/utils/release-notes-api.mjs'

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
/* the one-panel shell (<= 820 px): the version is the band above its rows,
   so the column goes - in the DOM, a hidden cell would still span a column */
const narrow = useMobileStack().isMobile

/* the changes shown; one page of this many versions carries at least as many */
const LATEST = 30
const PARTS = ['what', 'how', 'why'] as const
const SIDES = ['lay', 'tech'] as const
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
/* the hover: to the second, with the zone it is printed in */
const fullTime = (at: string) => [isoDateTimeSec(at), viewerTimeZone() || browserTimeZone()].filter(Boolean).join(' ')
const hasAny = (n: ReleaseNote, side: 'lay' | 'tech') => PARTS.some((k) => n[`${side}_${k}`])
const sidesOf = (n: ReleaseNote) => SIDES.filter((side) => hasAny(n, side))
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

function hubGet(path: string): Promise<unknown> {
  return releaseNotesGet(api, path, running.value)
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

/* "proper flow from click": the list comes back where it was left - the
   dialog body's scroll and the focus on the title that was clicked */
const rootEl = ref<HTMLElement | null>(null)
const scrollBody = () => rootEl.value?.closest<HTMLElement>('[data-testid=ui-dialog-body]') || null
let listAt: { top: number, sha: string } | null = null
function openNote(n: ReleaseNote) {
  listAt = { top: scrollBody()?.scrollTop || 0, sha: n.sha }
  note.value = n
  void nextTick(() => { const b = scrollBody(); if (b) b.scrollTop = 0 })
}
async function showList() {
  note.value = null
  const at = listAt
  listAt = null
  await nextTick()
  const b = scrollBody()
  if (b) b.scrollTop = at?.top || 0
  if (at) rootEl.value?.querySelector<HTMLElement>(`[data-test=release-row-title][data-sha="${at.sha}"]`)?.focus({ preventScroll: true })
}
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

/* last: the immediate watch runs start() during setup, so everything it
   reaches must be initialised above it */
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
/* The look of the app's other panels (owner, t1 3385cecb: "proper table,
   proper aligning"): theme tokens only, rem font sizes, the body inset like
   a feed, the table and the note each one bordered card. */
.rn { display: flex; flex-direction: column; gap: var(--spacing-sm); min-width: 0; padding: 0.75rem 1.5rem 1.5rem; }
.rn__lead, .rn__msg { margin: 0; }
.rn-card { background: var(--color-surface); border: 1px solid var(--color-border); border-radius: var(--radius-md); min-width: 0; }
.rn__back { font: inherit; font-weight: 600; color: var(--color-accent); background: none; border: 1px solid transparent; border-radius: var(--radius-sm); padding: 0.25rem 0.5rem 0.25rem 0.25rem; cursor: pointer; display: inline-flex; align-items: center; gap: 0.25rem; align-self: flex-start; }
.rn__back:hover { border-color: var(--color-border); }
.rn__back:dir(rtl) .ui-icon { transform: scaleX(-1); }
.rn__icon { font: inherit; color: var(--color-muted); background: none; border: 1px solid transparent; border-radius: var(--radius-sm); padding: 0.25rem; cursor: pointer; display: inline-flex; flex: none; }
.rn__icon:hover { color: var(--color-fg); border-color: var(--color-border); }
.rn__action { display: inline-flex; align-items: center; gap: 0.4rem; font-size: 0.875rem; text-decoration: none; }

/* the table: a header band, fixed narrow columns, the change takes the rest */
.rn-table-wrap { overflow: clip; }
.rn-table { width: 100%; border-collapse: collapse; table-layout: fixed; font-size: 0.9375rem; }
/* fixed layout sizes the columns from the header row */
.rn-table thead .rn-table__seq { width: 4.5rem; }
.rn-table thead .rn-table__ver { width: 7rem; }
.rn-table thead .rn-table__sha { width: 6.5rem; }
.rn-table thead .rn-table__time { width: 10rem; }
.rn-table th, .rn-table td { padding: 0.5rem 0.75rem; text-align: start; vertical-align: top; }
.rn-table thead th {
  position: sticky; top: 0; z-index: 1;
  font-size: 0.8125rem; font-weight: 600; color: var(--color-muted);
  text-transform: uppercase; letter-spacing: 0.04em;
  background: var(--color-bg-2); border-bottom: 1px solid var(--color-border-strong);
}
.rn-table__seq, .rn-table__ver, .rn-table__sha, .rn-table__time { white-space: nowrap; }
.rn-table .rn-table__seq { text-align: end; font-variant-numeric: tabular-nums; }
.rn-table td.rn-table__seq, .rn-table td.rn-table__ver { color: var(--color-muted); }
.rn-table td.rn-table__ver, .rn-table td.rn-table__time { font-variant-numeric: tabular-nums; }
.rn-table td.rn-table__time { color: var(--color-muted); font-size: 0.875rem; }
.rn-row__time { display: block; margin-top: 0.125rem; font-size: 0.8125rem; color: var(--color-muted); font-variant-numeric: tabular-nums; }
.rn-note__time { font-size: 0.8125rem; color: var(--color-muted); font-variant-numeric: tabular-nums; align-self: center; }
.rn-table__sha code { font-family: var(--font-mono); font-size: 0.8125rem; padding: 0.0625rem 0.375rem; border-radius: var(--radius-sm); background: var(--color-bg-2); border: 1px solid var(--color-border); color: var(--color-fg); }
.rn-table .rn-ver__head { padding-block: 0.625rem 0.5rem; background: var(--color-bg-2); border-top: 1px solid var(--color-border); border-bottom: 1px solid var(--color-border); }
.rn-table tbody:first-of-type .rn-ver__head { border-top: 0; }
.rn-ver__name { font-weight: 600; color: var(--color-heading); margin-inline-end: 0.5rem; font-variant-numeric: tabular-nums; }
.rn-ver__here, .rn-ver__newer { font-size: 0.75rem; font-weight: 600; padding: 0.0625rem 0.5rem; border-radius: var(--radius-pill); border: 1px solid currentColor; vertical-align: 0.0625rem; }
.rn-ver__here { color: var(--color-ok); }
.rn-ver__newer { color: var(--color-warn); }
.rn-row td { border-bottom: 1px solid var(--color-border); }
.rn-row:last-child td { border-bottom: 0; }
.rn-row:hover td { background: var(--color-surface-hover); }
.rn-row__title { overflow-wrap: anywhere; min-width: 0; }
.rn-row__title a { color: var(--color-accent); text-decoration: none; }
.rn-row__title a:hover { text-decoration: underline; }
.rn-row__badge { margin-inline-start: 0.5rem; white-space: nowrap; }
.rn-row__badge, .rn-note__state { font-size: 0.8125rem; color: var(--color-muted); font-style: italic; }
.rn-row__badge.is-missing, .rn-note__state.is-missing { color: var(--color-warn); font-style: normal; }

/* the note: a card with a head, the two halves, a foot */
.rn-note { display: flex; flex-direction: column; overflow: clip; }
.rn-note__head { display: flex; flex-direction: column; gap: 0.5rem; padding: 1rem 1.25rem; border-bottom: 1px solid var(--color-border); }
.rn-note__subject { margin: 0; font-size: 1.125rem; line-height: 1.35; color: var(--color-heading); overflow-wrap: anywhere; }
.rn-note__meta { margin: 0; display: flex; gap: 0.4rem; flex-wrap: wrap; }
.rn-chip { font-size: 0.75rem; font-weight: 600; padding: 0.0625rem 0.5rem; border-radius: var(--radius-pill); border: 1px solid var(--color-border-strong); color: var(--color-muted); }
.rn-chip--ver { color: var(--color-accent); border-color: currentColor; font-variant-numeric: tabular-nums; }
.rn-note__state { margin: 0; }
.rn-note__parts { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 20rem), 1fr)); }
.rn-note__part { padding: 1rem 1.25rem; min-width: 0; }
.rn-note__part + .rn-note__part { border-inline-start: 1px solid var(--color-border); }
.rn-note__part h4 { margin: 0 0 0.5rem; font-size: 0.8125rem; font-weight: 600; color: var(--color-muted); text-transform: uppercase; letter-spacing: 0.04em; }
.rn-note__part dl { margin: 0; display: grid; grid-template-columns: max-content 1fr; gap: 0.5rem 1rem; }
.rn-note__part dt { font-weight: 600; color: var(--color-heading); }
.rn-note__part dd { margin: 0; overflow-wrap: anywhere; }
.rn-note__foot { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 0.75rem 1rem; padding: 0.75rem 1.25rem; border-top: 1px solid var(--color-border); background: var(--color-bg-2); }
.rn-note__sha { display: flex; align-items: center; gap: 0.5rem; min-width: 0; }
.rn-note__label { font-size: 0.8125rem; font-weight: 600; color: var(--color-muted); text-transform: uppercase; letter-spacing: 0.04em; flex: none; }
.rn-note__sha code { font-family: var(--font-mono); font-size: 0.8125rem; overflow-wrap: anywhere; min-width: 0; }
.rn-note__links { display: flex; gap: 0.5rem; flex-wrap: wrap; align-items: center; }

/* a phone: the rows keep #, commit and change in line, the note's halves stack */
@media (max-width: 600px) {
  .rn { padding: 0.5rem 0.75rem 1rem; }
  .rn-table thead .rn-table__seq { width: 3rem; }
  .rn-table thead .rn-table__sha { width: 5.75rem; }
  .rn-table th, .rn-table td { padding: 0.5rem; }
  .rn-note__head, .rn-note__part, .rn-note__foot { padding-inline: 1rem; }
  .rn-note__part + .rn-note__part { border-inline-start: 0; border-top: 1px solid var(--color-border); }
  .rn-note__part dl { grid-template-columns: 1fr; gap: 0.125rem; }
  .rn-note__part dd + dt { margin-top: 0.5rem; }
}
@media (pointer: coarse) {
  .rn__back, .rn__icon, .rn__action { min-height: var(--tap, 44px); }
  .rn__icon { min-width: var(--tap, 44px); justify-content: center; }
}
</style>
