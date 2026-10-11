// Owner t1 da98036e (msg 8bfe3812): a full-hash link reads <8>... and the
// release log links its commits. Kept apart from mjs-shims.d.ts; the
// commit-links block merges with its '~/utils/commit-links.mjs' module.
declare module '~/utils/hash-label.mjs' {
  export function shortHash(hash: unknown): string
  export function shortHashLabel(text: unknown): { text: string, title: string } | null
}

declare module '~/utils/commit-links.mjs' {
  export function shaHref(prefix: string, sha: unknown): string
}

declare module '~/utils/source-repo.mjs' {
  export const SOURCE_REPO_URL: string
}

declare module '~/utils/app-link-label.mjs' {
  export function shortHashLabel(text: unknown): { text: string, title: string } | null
}
