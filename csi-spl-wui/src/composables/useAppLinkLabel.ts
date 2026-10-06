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
