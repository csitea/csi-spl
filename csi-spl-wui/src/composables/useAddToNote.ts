/*
 * Spec 155 2.3 (B8, SPL-4578): "Add to note" from anywhere. Every menu that
 * offers the item (MessageMenu, IssueRowMenu, IssueDetailActions,
 * SidebarRowMenu, CalendarEventDialog) calls this:
 *
 *   offered  false once the hub answered 404 `notes_off` (section 6): the
 *            items hide. Unknown until the first read, and then offered.
 *   probe()  that read, once, when a menu with the item opens; never at boot,
 *            so the first screen pays nothing for it (ci_initial_gzip_kb).
 *   open(l)  the note picker (AddToNotePicker.vue) for link `l`; its chunk is
 *            fetched on the first open and mounted once, into its own node
 *            with the app's context (the calendar reminder pop-up's way).
 *   workspace()  the page's workspace, the one a new link belongs to.
 *
 * The notes store is imported here only on demand, never statically.
 */
import { h, render } from 'vue'
import type { NoteLinkIn } from '~/stores/notes'
import { hostTenant, useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'

type Picker = { show(link: NoteLinkIn): void }
type NotesState = 'unknown' | 'on' | 'off'

const notesState = ref<NotesState>('unknown')
let probing = false
let picker: Promise<Picker> | null = null

/** The store's state as the items read it: off on `notes_off`, on once a list came back. */
export function noteNotesState(state: string) {
  if (state === 'off') notesState.value = 'off'
  else if (state === 'ready') notesState.value = 'on'
}

export function useAddToNote() {
  const nuxt = useNuxtApp()
  const api = useSpoolApi() as unknown as { tenant?: string }
  const session = useSessionStore()
  const offered = computed(() => notesState.value !== 'off')

  function workspace(): string {
    return hostTenant() || String(api.tenant || '') || String(session.claims?.t || '')
  }

  function probe() {
    if (!import.meta.client || probing || notesState.value !== 'unknown') return
    probing = true
    void import('~/stores/notes')
      .then(async (m) => {
        const store = await nuxt.runWithContext(() => m.useNotesStore())
        if (store.state === 'idle' || store.state === 'failed') await store.load()
        noteNotesState(store.state)
      })
      .catch(() => { /* unknown: the next menu asks again */ })
      .finally(() => { probing = false })
  }

  function open(link: NoteLinkIn | null) {
    if (!import.meta.client || !link) return
    picker ||= import('~/components/AddToNotePicker.vue').then((m) => {
      const host = document.createElement('div')
      document.body.appendChild(host)
      const vnode = h(m.default)
      vnode.appContext = nuxt.vueApp._context
      render(vnode, host)
      return vnode.component!.exposed as unknown as Picker
    })
    void picker.then((p) => p.show(link)).catch(() => { picker = null })
  }

  return { offered, probe, open, workspace }
}
