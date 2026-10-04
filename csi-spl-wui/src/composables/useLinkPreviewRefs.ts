// Topic e1f8f797: the links of one body that name a topic or a message of
// this workspace, when the reader's own "Link previews" setting is on (never
// picked = on). [] otherwise, and before the client renders. The cards
// themselves (LinkPreviews.vue) load lazily, only for a body that has such
// a link: LinkPreviewsLazy.
import { parseLinkPreviews, previewRefs } from '~/utils/link-preview.mjs'
import { useSessionStore } from '~/stores/session'

export const LinkPreviewsLazy = defineAsyncComponent(() => import('~/components/LinkPreviews.vue'))

export function useLinkPreviewRefs(body: () => string) {
  const session = useSessionStore()
  return computed(() => (
    import.meta.client && parseLinkPreviews(session.claims?.link_previews) === 'on'
      ? previewRefs(body(), window.location.origin)
      : []
  ))
}
