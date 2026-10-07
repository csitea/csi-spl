// spec 075 repo-edit T11: types of the repo-edit .mjs modules (kept out of
// mjs-shims.d.ts, which another lane holds; ambient declarations merge).
declare module '~/utils/repo-edit.mjs' {
  export type RepoEditFile = { editable: boolean, blob: string, overlay: boolean }
  export type RepoEditIdentity = { git_name: string, git_email: string, author_source: string }
  export function repoEditFiles(files: unknown): Map<string, RepoEditFile>
  export function ifMatchOf(base: unknown): string
  export function noticeIdentity(body: unknown): RepoEditIdentity | null
  export function saveErrorOf(status: number, body: unknown): { key: string, params: Record<string, string | number> }
  export type RepoEditView = { edit_id: string, path: string, status: string, human_id: string, actor_kind: 'member' | 'agent', agent_id: string, commit_sha: string, merged_with: string, last_error: string, created_at: string }
  export type RepoEditChip = { status: string, key: string, sha7: string, merged7: string, action: '' | 'resolve' | 'retry' }
  export type RepoEditConflict = { edit_id: string, path: string, base: string, theirs: string, mine: string, head_blob: string, head_commit: string, reason: string }
  export const EDIT_STATUSES: string[]
  export function editOf(v: unknown): RepoEditView | null
  export function editsOf(body: unknown): RepoEditView[]
  export function chipOf(edit: { status: string, commit_sha?: string, merged_with?: string } | null | undefined): RepoEditChip | null
  export function isPending(edit: { status: string } | null | undefined): boolean
  export function headerEdit(rows: RepoEditView[] | undefined, path: string, me: string, last?: { edit_id: string, path: string, status: string } | null): RepoEditView | null
  export function conflictOf(body: unknown): RepoEditConflict | null
  export function editActionErrorOf(status: number, body: unknown): { key: string, params: Record<string, string | number> }
}

declare module '~/utils/docs-mock.mjs' {
  export const MOCK_AUTHOR: { git_name: string, git_email: string, author_source: string }
  export const MOCK_REJECT: string
  export function mockDocBase(path: string): string
  export function mockRepoSave(path: string, text: string, ifMatch: string): { status: number, body: unknown }
  export function mockAuthorNotice(body: unknown): { status: number, body: unknown }
  export const MOCK_CONFLICT: string
  export const MOCK_FAIL: string
  export const MOCK_AGENT_EDIT: string
  export function mockRepoEdits(q: { mine?: boolean, path?: string }): { status: number, body: unknown }
  export function mockRepoRetry(id: string): { status: number, body: unknown }
  export function mockRepoConflict(id: string): { status: number, body: unknown }
  export function mockRepoReset(): void
}
