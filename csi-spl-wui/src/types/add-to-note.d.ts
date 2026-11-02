// Spec 155 B8 (SPL-4578): "Add to note" on an object (utils/add-to-note.mjs).
// Kept apart from mjs-shims.d.ts, as note-links.d.ts is.
declare module '~/utils/add-to-note.mjs' {
  import type { NoteLinkIn } from '~/stores/notes'
  export const NOTE_LABEL_MAX: number
  export const NOTE_MSG_LABEL: number
  export const ADD_TO_NOTE_ID: 'add-to-note'
  export function msgNoteLink(msg: { msg_id?: string, task_id?: string, body?: string } | null | undefined, opts?: { topic?: boolean, workspace?: string }): NoteLinkIn | null
  export function issueNoteLink(issue: { key?: string, title?: string } | null | undefined, workspace: string): NoteLinkIn | null
  export function eventNoteLink(ev: { id?: string, title?: string, source?: string } | null | undefined, workspace: string, day: string): NoteLinkIn | null
  export function channelNoteLink(channel: { id?: string, name?: string } | null | undefined, workspace: string): NoteLinkIn | null
  export function pickerNotes<T extends { title?: string, snippet?: string, archived?: boolean, updated_at?: string }>(list: readonly T[], query: string): T[]
  export function withNoteItem<T extends { id: string }>(items: readonly T[], on: boolean, item: T): T[]
}
