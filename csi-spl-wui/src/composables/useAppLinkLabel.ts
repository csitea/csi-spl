// The short label for a URL of this app (app-link-label.mjs). The module
// is its own chunk: MessageRuns and MarkdownBlock are on the first paint,
// and the initial JS is at its ceiling, so the label arrives a moment
// after the address and then replaces it. One load per tab.
import { shallowRef, type ShallowRef } from 'vue'

type AppLinkMod = typeof import('~/utils/app-link-label.mjs')

const mod: ShallowRef<AppLinkMod | null> = shallowRef(null)
let started = false

export function useAppLinkLabel() {
  if (import.meta.client && !started) {
    started = true
    void import('~/utils/app-link-label.mjs').then((m) => {
      mod.value = m
    }).catch(() => { /* the address stays the address */ })
  }
  return mod
}

/* t1 9dec05c3: a calendar event link reads as a chip, `event: <title> ·
   <day>`. The title comes from the reader's own calendar, in its own lazy
   chunk, loaded the first time a body shows such a link; until then (and
   for an event the reader may not see) the chip is `event: <day>`. */
type TitlesMod = typeof import('~/utils/event-link-titles')
type AppLinkLabel = NonNullable<ReturnType<AppLinkMod['appLinkLabel']>>
const titlesMod: ShallowRef<TitlesMod | null> = shallowRef(null)
let titlesStarted = false

export function appLinkText(m: AppLinkMod, label: AppLinkLabel): string {
  const ev = m.labelEvent(label)
  if (!ev) return label.text
  if (import.meta.client && !titlesStarted) {
    titlesStarted = true
    void import('~/utils/event-link-titles').then((t) => {
      titlesMod.value = t
    }).catch(() => { /* the chip keeps its day */ })
  }
  const t = titlesMod.value
  return m.eventChipText(label, t ? t.eventTitle(ev.id, ev.day) : '')
}
