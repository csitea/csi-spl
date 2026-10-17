// r13-03: the MessageComposer props its useComposer* composables read. They
// get the component's reactive props object itself, so a read stays reactive
// and reads the same as it did in the component.
import type { SearchOperator } from '~/utils/search.mjs'

export type DockTarget = { reply: boolean, target: string, comment?: boolean, dm?: boolean } | null

export interface ComposerProps {
  /** withDefaults gives it true */
  dock: boolean
  omnibox?: boolean
  global?: boolean
  sendBlocked?: boolean
  operators?: SearchOperator[]
  dockTarget?: DockTarget
  bottom?: boolean
}
