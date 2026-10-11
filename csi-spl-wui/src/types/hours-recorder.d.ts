// Tab-minute recorder types (spec 107 T012). Kept apart from mjs-shims.d.ts.
declare module '~/utils/hours-recorder.mjs' {
  export type HoursMinuteBatch = { tz: string, minutes: { at: string, target: string }[] }
  export type HoursRecorder = {
    sample(): void
    flush(keepalive?: boolean): Promise<void>
    tick(): void
    pending(): { at: string, target: string }[]
    stop(): void
  }
  export const MINUTE_MS: number
  export const INPUT_WINDOW_MS: number
  export const FLUSH_MS: number
  export const TICK_MS: number
  export const BATCH_MAX: number
  export const BUFFER_MAX: number
  export const INPUT_EVENTS: readonly string[]
  export const HOURS_MINUTES_MOCK_LOG: string
  export function hoursTargetOf(path: string, search?: string): string
  export function createHoursRecorder(env: {
    win: Pick<Window, 'addEventListener' | 'removeEventListener'>
    doc: Pick<Document, 'visibilityState' | 'hasFocus' | 'addEventListener' | 'removeEventListener'>
    now?: () => number
    target: () => string
    enabled: () => boolean
    tz: () => string
    send: (body: HoursMinuteBatch, opts: { keepalive: boolean }) => Promise<unknown>
    setTimer?: (fn: () => void, ms: number) => unknown
    clearTimer?: (id: unknown) => void
  }): HoursRecorder
  export function mockSendHoursMinutes(
    storage: Pick<Storage, 'getItem' | 'setItem'>,
    body: HoursMinuteBatch,
  ): { stored: number }
}
