// spec 089 T006: types of the calendar reminder .mjs modules (kept out of
// mjs-shims.d.ts, which another lane holds).
type CalendarReminder = { id: string, title: string, starts_at: string, ends_at: string, all_day: boolean, remind_at: string }

declare module '~/utils/calendar-reminders.mjs' {
  export const REMINDER_AHEAD_MS: number
  export const REMINDER_BEHIND_MS: number
  export const REMINDER_REFRESH_MS: number
  export const REMINDER_FOCUS_GAP_MS: number
  export const REMINDER_DISMISSED_KEY: string
  export const CALENDAR_CHANGED_EVENT: string
  export function reminderKey(ev: { id: string, remind_at: string }): string
  export function reminderWindow(now: number): { from: string, to: string }
  export function readReminders(body: unknown): CalendarReminder[]
  export function parseDismissed(raw: unknown, now: number): Record<string, number>
  export function withDismissed(dismissed: Record<string, number>, ev: { id: string, remind_at: string }): Record<string, number>
  export function dueReminders(list: CalendarReminder[], now: number, dismissed: Record<string, number>): { show: CalendarReminder[], next: number }
}

declare module '~/utils/calendar-reminders-mock.mjs' {
  export const MOCK_REMINDERS_SEED_KEY: string
  export function createMockReminders(seed?: Record<string, unknown>[]): {
    reminders(from: string, to: string): { from: string, to: string, reminders: Record<string, unknown>[] }
  }
  export function sharedMockReminders(): ReturnType<typeof createMockReminders>
}
