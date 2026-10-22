// r17-10: the release log's list read and its paging, moved out of
// ReleaseNotesDialog.vue.
//
// The refs stay declared in the dialog: its /releases/<ref> read, the list
// return and the version keys also read or write them. hubGet is returned
// too, for that /releases/<ref> read.
import { computed, type ComputedRef, type Ref } from 'vue'
import { mergeReleasePages, nextReleaseCursor, releaseNoteCount, releaseNotesRead } from '~/utils/release-notes-api.mjs'
import type { useSpoolApi } from '~/composables/useSpoolApi'

export interface ReleaseNote {
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
export interface ReleaseVersion { version: string, display?: string, notes: ReleaseNote[] }

interface ReleaseNotesPagesOpts {
  api: ReturnType<typeof useSpoolApi>
  running: ComputedRef<string>
  t: (key: string) => string
  /** the changes one page carries */
  LATEST: number
  versions: Ref<ReleaseVersion[]>
  loading: Ref<boolean>
  message: Ref<string>
  shown: Ref<number>
  nextBefore: Ref<string>
  paged: Ref<boolean>
  loadingOlder: Ref<boolean>
  olderFailed: Ref<boolean>
}

export function useReleaseNotesPages(o: ReleaseNotesPagesOpts) {
  const { api, running, t, LATEST, versions, loading, message } = o
  const { shown, nextBefore, paged, loadingOlder, olderFailed } = o

  /* the newest `shown` changes, still grouped under their versions */
  const latest = computed(() => {
    const out: ReleaseVersion[] = []
    let left = shown.value
    for (const v of versions.value) {
      if (left <= 0) break
      const notes = v.notes.slice(0, left)
      left -= notes.length
      if (notes.length) out.push({ ...v, notes })
    }
    return out
  })

  const shownCount = computed(() => releaseNoteCount(latest.value))
  const loadedCount = computed(() => releaseNoteCount(versions.value))
  const hasOlder = computed(() => paged.value && (loadedCount.value > shown.value || nextBefore.value !== ''))

  function hubGet(path: string): Promise<unknown> {
    return releaseNotesRead(api, path, running.value)
  }

  async function loadLatest() {
    if (loading.value) return
    loading.value = true
    try {
      const body = await hubGet(`/v1/release-notes?limit=${LATEST}`) as { off?: boolean, versions?: ReleaseVersion[] }
      if (body?.off) message.value = t('release_notes.off')
      versions.value = body?.versions || []
      nextBefore.value = nextReleaseCursor(body, '')
      paged.value = !body?.off
    } catch {
      message.value = t('release_notes.error')
    } finally {
      loading.value = false
    }
  }

  /* the next older page, all of it shown; true when the list grew */
  async function loadOlder(): Promise<boolean> {
    if (loadingOlder.value || !hasOlder.value) return false
    loadingOlder.value = true
    olderFailed.value = false
    const had = shownCount.value
    try {
      const at = nextBefore.value
      if (at) {
        const body = await hubGet(`/v1/release-notes?limit=${LATEST}&before=${encodeURIComponent(at)}`) as { versions?: ReleaseVersion[], next_before?: string }
        versions.value = mergeReleasePages(versions.value, body?.versions || [])
        nextBefore.value = nextReleaseCursor(body, at)
      }
      shown.value = Math.max(shown.value, loadedCount.value)
    } catch {
      olderFailed.value = true
    } finally {
      loadingOlder.value = false
    }
    return shownCount.value > had
  }

  return { latest, shownCount, loadedCount, hasOlder, hubGet, loadLatest, loadOlder }
}
