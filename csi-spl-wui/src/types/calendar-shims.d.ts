/* spec 089 T007 / T008: the Calendar section's pure utils (year strip, mock, event form + writes). */
declare module '~/utils/calendar-year.mjs' {
  export type CalMonth = { key: string, year: number, month0: number, lead: number, days: { iso: string, d: number }[] }
  export type CalMarks = { days: Map<string, { count: number, kinds: string[] }>, official: Map<string, string> }
  export function calIsoDay(date: Date | number | string): string
  export function calDayMs(iso: string): number
  export function calAddDays(iso: string, n: number): string
  export function calWeekStart(iso: string): string
  export function calWeekday(iso: string): number
  export function calWeekDays(iso: string): string[]
  export function calStripYears(todayIso: string): number[]
  export function calMonth(year: number, month0: number): CalMonth
  export function calStripMonths(years: number[]): CalMonth[]
  export function calMarksQuery(years: number[]): string
  export function calMarks(body: unknown): CalMarks
}

declare module '~/utils/calendar-mock.mjs' {
  export type CalendarItem = {
    id: string, source: 'event' | 'issue' | 'official_day', title: string, description: string, kind: string,
    starts_at: string, ends_at: string, all_day: boolean, audience: 'public' | 'internal' | 'private', mentions: string[],
    creator_type: 'human' | 'agent' | 'system', creator_id: string, remind_at: string, topic_id: string,
    release_version: string, issue_key: string, created_at: string, updated_at: string,
    /** 097 4.1; absent on an 089 hub */
    time_zone?: string, location?: string, color?: string, reminders?: { amount: number, unit: string, method?: string }[],
  }
  export function mockCalendarItems(todayIso: string): CalendarItem[]
  export function mockCalendarCreate(body?: { title?: string, description?: string, starts_at?: string, ends_at?: string, all_day?: boolean, audience?: string, topic_id?: string, time_zone?: string, location?: string, color?: string, reminders?: unknown[] }): CalendarItem
  export function mockCalendarUpdate(id: string, patch: Record<string, unknown>, todayIso: string): CalendarItem
  export function mockCalendarDelete(id: string, todayIso: string): CalendarItem
  export function mockCalendarRestore(id: string): CalendarItem
  export function mockCalendarTrash(nowMs?: number): (CalendarItem & { deleted_at: string })[]
  export function mockCalendarEvents(start: string, end: string, todayIso: string): { start: string, end: string, events: CalendarItem[] }
  export function mockCalendarMarks(startYear: number, endYear: number, todayIso: string): {
    start_year: number, end_year: number,
    days: { day: string, count: number, kinds: string[] }[],
    official_days: { day: string, title: string }[],
  }
}

/* spec 097 T014: an instant's wall time in a given zone (calendar chunk only) */
declare module '~/utils/date-iso-zone.mjs' {
  export function isoDateTimeIn(value: unknown, zone: string): string
}

/* spec 089 T008 v1: the event dialog's form and its three writes */
declare module '~/utils/calendar-event-form.mjs' {
  /** 097 T014: a reminder row as typed (the amount stays a string of digits) */
  export type CalReminderRow = { amount: string, unit: string }
  export type CalForm = {
    title: string, date: string, start: string, end: string, allDay: boolean, endDays: number,
    timeZone: string, zoneWas: string, location: string, reminders: CalReminderRow[], color: string,
    private: boolean, description: string,
  }
  type Item = import('~/utils/calendar-mock.mjs').CalendarItem
  export const CAL_TITLE_MAX: number
  export const CAL_DESCRIPTION_MAX: number
  export const CAL_LOCATION_MAX: number
  export const CAL_REMINDERS_MAX: number
  export const CAL_COLORS: string[]
  export const CAL_REMINDER_UNITS: Record<string, number>
  export function calDefaultZone(): string
  export function calReminderAmount(raw: unknown): string
  export function calReminderError(row: CalReminderRow): string
  export function calNewReminder(rows: CalReminderRow[]): CalReminderRow | null
  export function calEditable(ev: Item | null | undefined): boolean
  export function calCanSetPrivate(ev: Item | null | undefined, viewerId: string): boolean
  export function calWallToUtc(date: string, hhmm: string, zone?: string): string
  export function calFormFromEvent(ev: Item | null, day: string): CalForm
  export function calFormBody(form: CalForm, ev?: Item | null): { body: Record<string, unknown> | null, error?: undefined } | { error: string, body?: undefined }
  export function calHourAfter(hhmm: string): string
}

declare module '~/utils/calendar-events-api.mjs' {
  type Item = import('~/utils/calendar-mock.mjs').CalendarItem
  type Api = { mock?: boolean, base?: string, token?: string, credentials?: RequestCredentials }
  export function calendarCreate(api: Api, body: Record<string, unknown>): Promise<Item>
  export function calendarUpdate(api: Api, id: string, patch: Record<string, unknown>, todayIso: string, ifMatch?: string): Promise<Item>
  export function calendarDelete(api: Api, id: string, todayIso: string): Promise<Item>
  export function calendarRestore(api: Api, id: string, todayIso: string): Promise<Item>
  export function calendarTrash(api: Api): Promise<Item[]>
}

/* spec 097 T013: drag to move / resize / create on the main view */
declare module '~/utils/calendar-drag.mjs' {
  export const CAL_SNAP_MIN: number
  export const CAL_DAY_MIN: number
  export const CAL_HOLD_MS: number
  export const CAL_DRAG_PX: number
  export const CAL_TOUCH_SLOP_PX: number
  export type CalTimes = { starts_at: string, ends_at: string }
  type Timed = { id: string, starts_at: string, ends_at: string }
  export function calHhmm(min: number): string
  export function calMinuteOf(value: string): number
  export function calSnap(min: number, lo?: number, hi?: number): number
  export function calEventDay(ev: { starts_at: string, all_day?: boolean }): string
  export function calMoveTo(ev: Timed & { all_day?: boolean }, day: string, startMin?: number | null): CalTimes | null
  export function calResizeTo(ev: Timed & { all_day?: boolean }, endMin: number): CalTimes | null
  export function calCreateSlot(a: number, b: number): { start: string, end: string }
  export function calSameTimes(ev: CalTimes, next: CalTimes): boolean
  export function calDragErrorKey(e: { status?: number, token?: string } | null | undefined): string
  export function calDayLayout<T extends Timed>(events: T[]): { ev: T, top: number, len: number, col: number, cols: number }[]
}
