// spec 075 repo-edit T11: types of the repo-edit .mjs modules (kept out of
// mjs-shims.d.ts, which another lane holds; ambient declarations merge).
declare module '~/utils/repo-edit.mjs' {
  export type RepoEditFile = { editable: boolean, blob: string, overlay: boolean }
  export type RepoEditIdentity = { git_name: string, git_email: string, author_source: string }
  export function repoEditFiles(files: unknown): Map<string, RepoEditFile>
  export function ifMatchOf(base: unknown): string
  export function noticeIdentity(body: unknown): RepoEditIdentity | null
  export function saveErrorOf(status: number, body: unknown): { key: string, params: Record<string, string | number> }
}

declare module '~/utils/docs-mock.mjs' {
  export const MOCK_AUTHOR: { git_name: string, git_email: string, author_source: string }
  export const MOCK_REJECT: string
  export function mockDocBase(path: string): string
  export function mockRepoSave(path: string, text: string, ifMatch: string): { status: number, body: unknown }
  export function mockAuthorNotice(body: unknown): { status: number, body: unknown }
  export function mockRepoReset(): void
}
