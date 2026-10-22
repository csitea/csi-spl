/*
 * The doc view's '#' permalink (r16-08, out of WorkspaceDocView; spec 138 G2):
 * a click follows it, a long press copies the section's link (a touch has no
 * hover menu); the menu's Copy link copies the same link.
 */
import type { Router } from 'vue-router'
import type { DocItem, DocSession } from '~/components/workspace-docs/-doctree-api'
import { docLink } from '~/components/workspace-docs/-doc-anchor'
import { writeClipboard } from '~/utils/clipboard.mjs'

/* a press on the '#' this long copies the section's link instead of following it */
const LONG_PRESS_MS = 500

type PermalinkView = {
  props: { session: DocSession }
  router: Router
  say: (text: string, transient?: boolean) => void
  goTo: (id: string) => void
}

export function useDocPermalink({ props, router, say, goTo }: PermalinkView) {
  const { t } = useI18n({ useScope: 'global' })
  let pressTimer: ReturnType<typeof setTimeout> | undefined
  let pressed = false

  /** the section's link on the clipboard: the stable id form, the file tree's docHref */
  async function copyLink(it: DocItem) {
    const href = docLink((to) => router.resolve(to), location.origin, props.session.doc, it.id)
    say(t(await writeClipboard(href) ? 'ws_doctree.doc_menu.link_copied' : 'common.copy_failed'))
  }

  function pressStart(it: DocItem) {
    pressed = false
    clearTimeout(pressTimer)
    pressTimer = setTimeout(() => {
      pressed = true
      void copyLink(it)
    }, LONG_PRESS_MS)
  }
  function pressEnd() {
    clearTimeout(pressTimer)
  }
  function permaClick(it: DocItem) {
    if (pressed) {
      pressed = false
      return
    }
    goTo(it.id)
  }

  return { copyLink, pressStart, pressEnd, permaClick }
}
