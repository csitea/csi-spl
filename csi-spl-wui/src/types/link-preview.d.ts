// Topic e1f8f797: internal link previews. Kept apart from mjs-shims.d.ts.
declare module '~/utils/link-preview.mjs' {
  export const PREVIEWS_PER_BODY: number
  export const LINK_PREVIEWS: readonly ['on', 'off']
  export const RELEASE_ID_PREFIX: 'release:'
  export function parseLinkPreviews(raw: unknown): 'on' | 'off'
  export function previewTarget(href: string, pageOrigin: string): string | null
  export function previewRefs(body: unknown, pageOrigin: string, max?: number): { id: string, href: string }[]
  export function previewRefsOfBlocks(blocks: unknown, pageOrigin: string, max?: number): { id: string, href: string }[]
  export function bodyPreviewRefs(blocks: unknown, body: unknown, pageOrigin: string, opts?: { skip?: Iterable<string>, max?: number }): { id: string, href: string }[]
}

declare module '~/utils/link-preview-lookup.mjs' {
  export const PREVIEW_ASK_MAX: number
  export const PREVIEW_TTL_MS: number
  export function createPreviewLookup(opts: {
    fetchPreviews: (ids: string[]) => Promise<unknown>
    onChange: () => void
    schedule?: (fn: () => void) => void
    now?: () => number
    max?: number
  }): { want(ids: Iterable<string>): void, get(id: string): unknown }
  export function previewText(body: unknown): { title: string, excerpt: string }
  export function mockPreviews(rows: unknown[], ids: string[]): { previews: unknown[] }
}

// Owner t1 a1bce52e: a release-note link is internal and has a preview card.
declare module '~/utils/release-notes-api.mjs' {
  export const RELEASE_NOTES_LATEST: number
  export function releaseNotesGet(api: unknown, path: string, running: string): Promise<unknown>
  export function releasePreviews(ids: string[], get: (path: string) => Promise<unknown>): Promise<{ previews: unknown[] }>
  export function mockReleaseNotes(path: string, top: string): unknown
}
