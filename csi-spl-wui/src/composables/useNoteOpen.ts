import type { ComputedRef } from 'vue'
import type { Router, RouteLocationNormalizedLoaded } from 'vue-router'
import { useMobileStack } from '~/composables/useMobileStack'

function urlQuery(note: string): Record<string, string> {
  const query: Record<string, string> = {}
  new URL(window.location.href).searchParams.forEach((v, k) => { query[k] = v })
  if (note) query.note = note
  else delete query.note
  return query
}

function writeInPlace(note: string) {
  const url = new URL(window.location.href)
  if (note) url.searchParams.set('note', note)
  else url.searchParams.delete('note')
  window.history.replaceState(window.history.state, '', url.pathname + url.search + url.hash)
}

/**
 * Spec 155 2.6 (B6, SPL-4186): which note is open, and its ?note=<id> entry,
 * so a bookmark and a reload open it again (C20). The issues page's model
 * (composables/useIssueOpen): above 820 px opening a note is a history entry,
 * so browser Back closes the modal; a phone writes the query in place and
 * useMobileStack owns the level-3 entry (Back, the chevron, a swipe right).
 * On a phone the query is written AFTER the stack pushed that entry: written
 * before, the entry below kept ?note=, and Back landed on it, the router read
 * the note again and it reopened (the 390 px e2e, SPL-4186). For the same
 * reason a phone opens from the query only on the first load (a deep link).
 */
export function useNoteOpen(o: { route: RouteLocationNormalizedLoaded, router: Router, phone: ComputedRef<boolean> }) {
  const stack = useMobileStack()
  const openId = ref('')
  let pushed = false
  /* SPL-5005: a close's router.back() is still under way, and it would cancel a
     push started now and close the note just opened; that open waits for it, and
     whichever note is up when the Back lands (openId) is the one to write */
  let backing = false

  const queryNote = () => {
    const q = o.route.query.note
    const raw = Array.isArray(q) ? q[0] : q
    return typeof raw === 'string' ? raw.trim() : ''
  }

  function open(id: string) {
    if (!id || openId.value === id) return
    const wasOpen = Boolean(openId.value)
    openId.value = id
    if (o.phone.value) {
      /* the level watch (flush post) has pushed the level-3 entry by then */
      void nextTick(() => { if (openId.value === id) writeInPlace(id) })
      return
    }
    if (backing) return
    if (wasOpen || queryNote() === id) { void o.router.replace({ query: urlQuery(id) }); return }
    pushNote(id)
  }

  function pushNote(id: string) {
    pushed = true
    void o.router.push({ query: urlQuery(id) })
  }

  function close() {
    if (!openId.value) return
    openId.value = ''
    if (o.phone.value) { writeInPlace(''); return }
    if (backing) return
    if (pushed && queryNote()) { pushed = false; backing = true; o.router.back(); return }
    /* SPL-4893: pushed with no ?note= yet is a push still under way, and when
       it commits the watch below opens the note again: a newer navigation
       cancels it, even one to where the page already is */
    const inFlight = pushed
    pushed = false
    if (inFlight || queryNote()) void o.router.replace({ query: urlQuery('') })
  }

  /* a deep link, browser Back / Forward over a ?note= entry */
  let first = true
  watch(queryNote, (id) => {
    const deepLink = first
    first = false
    if (!id) pushed = false
    /* cleared at any width: the window can narrow to a phone during the Back */
    const next = backing ? openId.value : ''
    backing = false
    if (o.phone.value && !deepLink) {
      /* the stack reads that popstate as a Back off level 3: a note queued
         then is dropped with it, so the page and the url agree */
      if (next) close()
      return
    }
    openId.value = next || id
    if (next) pushNote(next)
  }, { immediate: true })
  stack.rightPanel(() => o.phone.value && Boolean(openId.value), close)

  return { openId, open, close }
}
