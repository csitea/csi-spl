// Spec 074 T008 (owner HUM-10, t1 aa35699c): the operator console, a section
// of the right-most pane. A Pinia store because the rail button that opens it
// (ChannelSidebar), the layout that renders the one right-pane section
// (utils/topic-pane.mjs) and the pane itself read the SAME state.
//
// visible: the console shows only to an admin of the operator workspace. The
// WUI cannot read `operator` anywhere but the operator list itself, so the
// probe is that list. It is skipped for a reader whose role here is known and
// is not admin (no /v1/view/me answer fails open, as stores/access does), and
// the section shows only when it answered and named the operator
// workspace (`operator: true`). A 403 operator.workspaces, or any failure,
// hides it; the hub's 403 is the real gate on every call.
import { defineStore } from 'pinia'
import { ref } from 'vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { normalizeOperatorWorkspaces, operatorConsoleVisible } from '~/utils/operator-console.mjs'
import type { OperatorWorkspace } from '~/utils/operator-console.mjs'

type OperatorApi = { listOperatorWorkspaces: () => Promise<unknown> }

export const useOperatorPane = defineStore('operator-pane', () => {
  const open = ref(false)
  const visible = ref(false)
  const rows = ref<OperatorWorkspace[]>([])
  let seq = 0

  /** Read the list; true when it answered. role is the reader's role here (null = unknown). */
  async function probe(role: string | null) {
    const mine = ++seq
    if (role && role !== 'admin') {
      visible.value = false
      open.value = false
      return false
    }
    try {
      const api = useSpoolApi() as unknown as OperatorApi
      const list = normalizeOperatorWorkspaces(await api.listOperatorWorkspaces()) as OperatorWorkspace[]
      if (mine !== seq) return false
      rows.value = list
      visible.value = operatorConsoleVisible(list)
    } catch {
      if (mine !== seq) return false
      visible.value = false
    }
    if (!visible.value) open.value = false
    return visible.value
  }

  function show() {
    if (visible.value) open.value = true
  }
  function close() {
    open.value = false
  }
  function toggle() {
    if (open.value) close()
    else show()
  }

  return { open, visible, rows, probe, show, close, toggle }
})
