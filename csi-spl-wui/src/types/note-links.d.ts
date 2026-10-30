// Spec 155 B7 (SPL-4330): a note's links. Kept apart from mjs-shims.d.ts;
// the id-links block merges with its '~/utils/id-links.mjs' module.
declare module '~/utils/id-links.mjs' {
  export function activeIdIndex(): IdIndex
  export function resolveTyped(type: string, id: string, index: IdIndex): { href: string } | null
}

declare module '~/utils/note-links.mjs' {
  export type NoteLinkCtx = { tenant?: string, siteUrl?: string, apexTenant?: string, pageOrigin?: string, issuePrefix?: string }
  export type NoteLinkRef = { kind: string, workspace_id?: string, ref: string, day?: string, label?: string, left?: boolean }
  export type NoteLinkOpen = NoteLinkCtx & { pathFor?: (p: string) => string, typed?: (kind: string, ref: string) => { href: string } | null }
  export const NOTE_LINK_REF_MAX: number
  export const NOTE_LINK_KINDS: readonly string[]
  export function parseNoteLink(text: unknown, ctx?: NoteLinkCtx): { link: NoteLinkRef } | { error: string }
  export function noteLinkPath(link: NoteLinkRef): string
  export function noteLinkHref(link: NoteLinkRef, ctx?: NoteLinkOpen): { href: string, external: boolean, here: boolean, path: string }
  export function noteLinkAnchor(link: NoteLinkRef, ctx?: NoteLinkOpen): { href: string, target?: string, rel?: string } | null
  export function noteLinkText(link: NoteLinkRef): string
}
