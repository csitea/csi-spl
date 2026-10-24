// r20-03: the release log's version keys (j / k, Enter, h / l, Escape),
// moved out of ReleaseNotesDialog.vue.
//
// `opened` and `cursor` stay refs declared in the dialog: its props.open
// watch resets them and its template reads the cursor.
import { nextTick, onBeforeUnmount, onMounted, type ComputedRef, type Ref } from 'vue'
import { releaseKeyFor } from '~/utils/release-notes-api.mjs'
import type { ReleaseNote, ReleaseVersion } from '~/composables/useReleaseNotesPages'

interface ReleaseVersionKeysOpts {
  open: () => boolean
  rootEl: Ref<HTMLElement | null>
  scrollBody: () => HTMLElement | null
  note: Ref<ReleaseNote | null>
  /** the opened version, '' = the list */
  opened: Ref<string>
  /** the version row the keys are on, -1 = none yet */
  cursor: Ref<number>
  latest: ComputedRef<ReleaseVersion[]>
  keysOn: ComputedRef<boolean>
  loadOlder: () => Promise<boolean>
}

export function useReleaseVersionKeys(o: ReleaseVersionKeysOpts) {
  const { open, rootEl, scrollBody, note, opened, cursor, latest, keysOn, loadOlder } = o

  function focusVersion(i: number) {
    const th = rootEl.value?.querySelectorAll<HTMLElement>('[data-test=release-version-head] th')[i]
    if (!th) return
    th.focus({ preventScroll: true })
    th.scrollIntoView({ block: 'nearest' })
  }
  async function stepCursor(step: number) {
    let i = cursor.value < 0 ? 0 : cursor.value + step
    if (i >= latest.value.length && !(await loadOlder())) return
    i = Math.max(0, Math.min(i, latest.value.length - 1))
    cursor.value = i
    await nextTick()
    focusVersion(i)
  }
  /* one dialog = one call: the list's scroll when a version was opened */
  let versionTop = 0
  async function openVersion(key: string) {
    versionTop = scrollBody()?.scrollTop || 0
    opened.value = key
    await nextTick()
    const b = scrollBody()
    if (b) b.scrollTop = 0
    focusVersion(0)
  }
  /* h / l: the older / newer version, loading older past the last */
  async function turnVersion(step: number) {
    let i = latest.value.findIndex((v) => v.version === opened.value) + step
    if (i >= latest.value.length && !(await loadOlder())) return
    if (i < 0 || i >= latest.value.length) return
    opened.value = latest.value[i]!.version
    cursor.value = i
    await nextTick()
    const b = scrollBody()
    if (b) b.scrollTop = 0
    focusVersion(0)
  }
  async function closeVersion() {
    const key = opened.value
    opened.value = ''
    await nextTick()
    const b = scrollBody()
    if (b) b.scrollTop = versionTop
    cursor.value = latest.value.findIndex((v) => v.version === key)
    if (cursor.value >= 0) focusVersion(cursor.value)
  }
  /* the dialog's own: only while it is the top one; ahead of UiDialog's Escape
     (window, capture) so Escape in an opened version goes back to the list */
  function onKeys(ev: KeyboardEvent) {
    const root = rootEl.value
    if (!open() || !root) return
    const backdrops = document.querySelectorAll('.ui-dialog-backdrop')
    if (!backdrops[backdrops.length - 1]?.contains(root)) return
    const active = document.activeElement as HTMLElement | null
    const onVersion = Boolean(active && root.contains(active) && active.closest('[data-test=release-version-head]'))
    const view = note.value ? 'note' : opened.value ? 'version' : 'list'
    const hit = releaseKeyFor(ev, { enabled: keysOn.value, view, onVersion })
    if (!hit) return
    ev.preventDefault()
    ev.stopPropagation()
    if (hit.type === 'back') void closeVersion()
    else if (hit.type === 'open') { const v = latest.value[cursor.value]; if (v) void openVersion(v.version) }
    else if (hit.type === 'turn' || opened.value) void turnVersion(hit.step)
    else void stepCursor(hit.step)
  }
  onMounted(() => window.addEventListener('keydown', onKeys, true))
  onBeforeUnmount(() => window.removeEventListener('keydown', onKeys, true))

  return { closeVersion }
}
