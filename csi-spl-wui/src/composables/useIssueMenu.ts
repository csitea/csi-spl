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

export function useIssueMenu() {
  function openAt(t: IssueMenuTarget, x: number, y: number) {
    target.value = t
    point.value = { x, y }
  }
  function close() {
    target.value = null
  }
  return { target, point, openAt, close }
}
