// Topic e1f8f797: the links of one body that name a topic or a message of
// this workspace - URL links AND the ids id-links.mjs turned into links -
// when the reader's own "Link previews" setting is on (never picked = on).
// [] otherwise, and before the client renders. The cards themselves
// (LinkPreviews.vue) load lazily, only for a body that has such a link:
// LinkPreviewsLazy. `skip` leaves out the card's own message and topic (an
// agent post quoting the topic it is in gets no card of itself).
import { bodyPreviewRefs, parseLinkPreviews } from '~/utils/link-preview.mjs'
import { parseBody } from '~/utils/code-blocks.mjs'
import { useSessionStore } from '~/stores/session'

export const LinkPreviewsLazy = defineAsyncComponent(() => import('~/components/LinkPreviews.vue'))

export function useLinkPreviewRefs(body: () => string, opts: { blocks?: () => unknown, skip?: () => string[] } = {}) {
  const session = useSessionStore()
  return computed(() => {
    if (!import.meta.client || parseLinkPreviews(session.claims?.link_previews) !== 'on') return []
    const text = body()
    /* parseBody reads the id catalog (idLinkEpoch), so a late id lookup re-runs this */
    const blocks = opts.blocks ? opts.blocks() : parseBody(text)
    return bodyPreviewRefs(blocks, text, window.location.origin, { skip: opts.skip ? opts.skip() : [] })
  })
}
