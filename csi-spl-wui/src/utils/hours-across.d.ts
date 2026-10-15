// Spec 118 T005: the types of hours-across.mjs, the JSON of the hub's
// hours.Across (GET /v1/me/realm/hours `days`, `totals`).

export interface Span {
  start: string // RFC 3339, UTC
  end: string
  provisional?: boolean // the running timer's span: drawn dashed, not entered
}

export interface AcrossEntry {
  target: string
  minutes: number
  state: 'approved' | 'open' | 'rejected'
  spans?: Span[]
}

export interface WorkspaceDay {
  workspace: string
  day: string // YYYY-MM-DD in the workspace's zone
  state?: string
  standard_day?: number
  unavailable?: boolean
  entries?: AcrossEntry[]
  timer?: string // RFC 3339 start of the workspace's running timer
}

export interface Totals {
  reported: number
  open: number
  actual: number
  overlap: number
  unplaced: number
  data_error_minutes: number
}

export interface OverlapInterval {
  start: string
  end: string
  workspaces: string[]
}

export interface WorkspaceShare {
  minutes: number
  open: number
  state?: string
  standard_day?: number
  spans: Span[]
}

export interface PersonalDay extends Totals {
  day: string // YYYY-MM-DD in the person's zone
  approx: boolean
  incomplete: boolean
  unavailable: string[]
  overlap_intervals: OverlapInterval[]
  workspaces: Record<string, WorkspaceShare>
}

export const HOURS_ENTRY_APPROVED: 'approved'
export const HOURS_ENTRY_OPEN: 'open'
export const HOURS_ENTRY_REJECTED: 'rejected'
export function hoursDayIn(ms: number, zone: string): string
export function hoursAcross(days: WorkspaceDay[], zone: string, now: Date | string | number): PersonalDay[]
export function hoursSum(days: PersonalDay[]): Totals
export function hoursWithTimers(day: PersonalDay, timers: Record<string, string>, zone: string, now: Date | string | number): PersonalDay
export function hoursLimitInEffect<L extends { valid_from: string }>(limits: L[], day: string): L | null
export function hoursLimitLevel(actual: number, limit: number | null | undefined): 'none' | 'amber' | 'red'
