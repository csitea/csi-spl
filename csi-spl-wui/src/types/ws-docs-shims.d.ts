// spec 075 T010: types of the workspace docs .mjs modules (kept out of
// mjs-shims.d.ts, which another lane holds).
declare module '~/utils/ws-docs.mjs' {
  export const WS_PREFIX: string
  export const DOCS_WRITE: string
  export function wsDocsRoute(path: string): string
  export function wsPathOf(docsPath: string): string
  export function newDocPath(raw: unknown): string
  export function newDocBody(path: string): string
  export function wsTreeFiles(body: unknown): { path: string, title: string }[]
  export function canWriteDocs(me: { humanId?: string | null, permissions?: string[] | null } | null): boolean
}

declare module '~/utils/ws-docs-mock.mjs' {
  export function createMockWsDocs(seed?: Record<string, string>): {
    get(path: string): string | null
    put(path: string, body: string): boolean
    del(path: string): boolean
    history: { path: string, body: string }[]
  }
}
