import { chatKind, sectionExitPath } from '~/utils/section-strip.mjs'

type LastChat = { channel: string, dm: string, chat: string }

/**
 * CLE-77886 (HUM-24, csitea 7930dfbf: "няма изход от прозорец "проблеми"" -
 * there is no exit from the Issues window). A section page (Issues, Event
 * log, People, Help, ...) fills the middle; on a desktop the rail's Channels
 * / Direct messages only swapped the left list, so the page stayed and read
 * as a dead end. The sidebar notes every conversation route (`note`); the
 * rail and the section page's close X go back to it (`target`).
 */
export function useSectionExit() {
  const last = useState<LastChat>('section-exit-last', () => ({ channel: '', dm: '', chat: '' }))
  function note(path: string, fullPath: string) {
    const kind = chatKind(path)
    if (!kind) return
    last.value = { ...last.value, [kind]: fullPath, chat: fullPath }
  }
  /** the route to go back to ('' = none for that rail tab) */
  function target(tab?: string) {
    return sectionExitPath(last.value, tab)
  }
  return { note, target }
}
