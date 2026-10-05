/* spec 089 T007: the Calendar section's pure utils (year strip + mock). */
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
  }
  export function mockCalendarItems(todayIso: string): CalendarItem[]
  export function mockCalendarEvents(start: string, end: string, todayIso: string): { start: string, end: string, events: CalendarItem[] }
  export function mockCalendarMarks(startYear: number, endYear: number, todayIso: string): {
    start_year: number, end_year: number,
    days: { day: string, count: number, kinds: string[] }[],
    official_days: { day: string, title: string }[],
  }
}
