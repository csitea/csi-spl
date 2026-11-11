// Spec 155 2.10 (SPL-5255): a note's menu (utils/note-menu.mjs).
// Kept apart from mjs-shims.d.ts, as add-to-note.d.ts is.
declare module '~/utils/note-menu.mjs' {
  import type { PointMenuItem } from '~/components/UiPointMenu.vue'
  type NoteLike = { archived?: boolean, title?: string, body?: string, snippet?: string, items?: unknown[], items_total?: number } | null | undefined
  export const NOTE_MENU_ARCHIVE: 'archive'
  export const NOTE_MENU_UNARCHIVE: 'unarchive'
  export const NOTE_MENU_DISCUSS: 'discuss'
  export const NOTE_MENU_DELETE: 'delete'
  export const NOTE_DISCUSSION_CHANNEL: string
  export function noteHasText(n: NoteLike): boolean
  export function noteMenuItems(n: NoteLike): PointMenuItem[]
  export function noteDiscussionBody(n: { title?: string, body?: string, items?: { text?: string, done?: boolean }[] } | null | undefined): string
}
