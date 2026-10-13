// Blocker -> issue setting and the Issues rail count. Kept apart from mjs-shims.d.ts.
declare module '~/utils/blocker-settings.mjs' {
  export const BLOCKER_KEY_MINUTES: string
  export const BLOCKER_MINUTES_RANGE: { min: number, max: number }
  export const BLOCKER_MINUTES_DEFAULT: number
  export function blockerMinutesValid(v: unknown): boolean
  export function blockerMinutesOf(settings: unknown): number
  export function blockerMinutesPatch(stored: number, form: number | string): Record<string, number>
}
declare module '~/utils/my-issues-count.mjs' {
  export const OPEN_ISSUE_STATUSES: readonly string[]
  export function openIssueCount(issues: unknown): number
  export function newIssueCount(issues: unknown): number
  export function isNewIssue(issue: unknown): boolean
  export const ISSUE_OPENED_EVENT: string
  export function startMyIssuesCount(opts: {
    api: { listIssues: (opts?: { filter?: Record<string, unknown> }) => Promise<unknown> },
    live?: { onIssue?: (fn: () => void) => unknown, onReconnected?: (fn: () => void) => unknown },
    count: { value: number },
    delay?: number,
  }): () => void
}
