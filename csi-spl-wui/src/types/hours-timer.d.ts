// Header timer types (spec 107 Q7 = B, T019). Kept apart from mjs-shims.d.ts.
declare module '~/utils/hours-timer.mjs' {
  export type HoursTimerRow = { target: string, label: string, start: string, stopped: string }
  export type HoursTimerPiece = { day: string, minutes: number }
  export const HOURS_TIMER_KEY: string
  export const HOURS_TIMER_MOCK_LOG: string
  export const HOURS_TIMER_MOCK_FROZEN: string
  export function hoursTimerOwner(tenant: string, hum: string): string
  export function hoursTimerRead(storage: Storage, owner: string): HoursTimerRow | null
  export function hoursTimerWrite(storage: Storage, owner: string, row: HoursTimerRow | null): void
  export function hoursTimerClock(ms: number): string
  export function hoursTimerMinutes(m: number): string
  export function hoursTimerRefusalKey(err: unknown): string
  export function postHoursTimer(
    api: { mock: boolean, base: string, token: string, credentials: 'include' | 'omit' },
    body: { target: string, start: string, end: string },
  ): Promise<{ written: HoursTimerPiece[] }>
}
