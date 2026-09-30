import { ref } from 'vue'

/**
 * SPL-1226: one issue context menu at a time, shared by the Issues table/cards
 * and the Epics & Features sidebar (a module-level singleton, the shape
 * useMessageMenu uses). The page renders the one <IssueRowMenu> and owns the
 * actions; the sidebar only opens it. A right-click on another row replaces it.
 */
export type IssueMenuTarget = {
  key: string
  kind: string
  level: number
  title: string
  /** true for a level-1 row (epic or feature) */
  top: boolean
}

const target = ref<IssueMenuTarget | null>(null)
const point = ref({ x: 0, y: 0 })
/**
 * CLE-77816 (owner, topic 4365c545): "there is no edit epic/feature on the
 * issues interface … it should be in the right-click menu". The Epics sidebar
 * only opens the menu, so a double-click there (or the menu's Edit item)
 * hands the target to the page, which owns the issue dialog. A bumped seq
 * re-fires even when the same epic is asked for twice in a row.
 */
const editRequest = ref<{ target: IssueMenuTarget, seq: number } | null>(null)
let editSeq = 0

export function useIssueMenu() {
  function openAt(t: IssueMenuTarget, x: number, y: number) {
    target.value = t
    point.value = { x, y }
  }
  function close() {
    target.value = null
  }
  /* ask the Issues page to open the shared dialog on this epic / feature */
  function requestEdit(t: IssueMenuTarget) {
    editSeq += 1
    editRequest.value = { target: t, seq: editSeq }
  }
  return { target, point, openAt, close, editRequest, requestEdit }
}
