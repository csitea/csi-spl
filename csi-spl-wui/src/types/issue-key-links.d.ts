// HUM-10 t1 0f2ed820: issue keys and code-span shas in a message link.
// Kept apart from mjs-shims.d.ts; inlineCommitHref lives in
// utils/commit-links.ts.
declare module '~/utils/issue-link-hook.mjs' {
  export type IssueLinker = { blocks: (blocks: unknown[]) => unknown[], markdown: (src: string) => string, inline: (text: string) => string }
  export function setIssueLinkProvider(fn: (() => IssueLinker | null) | null): void
  export function activeIssueLinker(): IssueLinker | null
}

declare module '~/utils/issue-key-links.mjs' {
  export function issueKeyPrefix(prefix: unknown): string
  export function isIssueKey(prefix: unknown, text: unknown): boolean
  export function issueHref(prefix: unknown, key: unknown, pathFor?: (p: string) => string): string
  export function linkifyIssueText(text: unknown, prefix: unknown, pathFor?: (p: string) => string): { type: string, text: string, href?: string }[]
  export function linkifyIssueMarkdown(src: unknown, prefix: unknown, pathFor?: (p: string) => string): string
  export function inlineIssueHref(prefix: unknown, text: unknown, pathFor?: (p: string) => string): string
  export function linkifyIssueBlocks<T>(blocks: T, prefix: unknown, pathFor?: (p: string) => string): T
  export function issueLinker(prefix: unknown, pathFor?: (p: string) => string): { blocks: (blocks: unknown[]) => unknown[], markdown: (src: string) => string, inline: (text: string) => string } | null
}
