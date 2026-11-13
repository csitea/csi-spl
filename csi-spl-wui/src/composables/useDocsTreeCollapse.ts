/* SPL-5410 (owner HUM-10, t1 e791b8a2): the Docs explorer is a vertical
   panel, so it gets the spec 050 bottom-corner triangle the channels panel
   has (PaneCollapseToggle): it collapses the tree to a thin strip and expands
   it back. The same rules, reused from utils/pane-collapse.mjs: the corner
   follows the Win/Mac close_buttons claim (collapseSide), and the triangle
   points the way the panel moves; the tree is the left-most panel, as the
   channels one is, so it docks to inline-start (arrowPointsEnd 'channels').
   The flag is kept on this device under its own key, beside the shell's
   spool.pane-collapsed, which this does not touch. */
import { arrowPointsEnd, collapseSide } from '~/utils/pane-collapse.mjs'
import { storageGetJson, storageSetJson } from '~/utils/prefs.mjs'
import { useSessionStore } from '~/stores/session'

const DOCS_TREE_COLLAPSED_KEY = 'spool.docs-tree-collapsed'

export function useDocsTreeCollapse() {
  const collapsed = ref(false)
  const session = useSessionStore()
  const side = computed(() => collapseSide(session.claims?.close_buttons))
  const pointsEnd = computed(() => arrowPointsEnd(collapsed.value, 'channels'))

  function toggle() {
    collapsed.value = !collapsed.value
    storageSetJson(DOCS_TREE_COLLAPSED_KEY, collapsed.value)
  }

  onMounted(() => { collapsed.value = storageGetJson(DOCS_TREE_COLLAPSED_KEY, false) === true })

  return { collapsed, side, pointsEnd, toggle }
}
