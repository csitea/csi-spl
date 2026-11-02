// Spec 170 row B1: the task rules of the To-do view and the morning card. Kept apart from mjs-shims.d.ts.
declare module '~/utils/day-tasks.mjs' {
  export function isTask(issue: unknown): boolean
  export function dayBounds(day: string, zone?: string): { start: string, end: string } | null
  export function groupByDay<T = unknown>(
    issues: unknown,
    range: { from: string, to: string } | null | undefined,
    zone?: string,
  ): { day: string, tasks: T[] }[]
  export function overdue<T = unknown>(issues: unknown, now: Date | number, zone?: string): T[]
  export function dueTodayCounts(issues: unknown, now: Date | number, zone?: string): { today: number, overdue: number }
}
