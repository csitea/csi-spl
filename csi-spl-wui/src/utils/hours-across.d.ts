// Type definitions for hours-across.mjs
// Spec 118 T005: Client-side overlap computation for today's running timer.

export type Span = {
  start: string; // RFC 3339 UTC instant
  end: string;   // RFC 3339 UTC instant
  workspace: string;
  provisional?: boolean;
};

export type WorkspaceDay = {
  workspace: string;
  day: string; // YYYY-MM-DD
  entries: Array<{
    target: string;
    minutes?: number;
    state: 'approved' | 'open' | 'suggested';
    spans?: Span[];
  }>;
  timer?: string; // RFC 3339 UTC instant (start of running timer)
};

export type PersonalDay = {
  day: string; // YYYY-MM-DD
  reported: number; // sum of entries' minutes (approved + open suggestions)
  open: number;     // sum of open suggestions' minutes
  actual: number;    // |union of spans| + unplaced minutes
  overlap: number;   // reported - actual, never negative
  unplaced: number;  // minutes without times (typed rows)
  approx: boolean;   // true if unplaced > 0
  incomplete: boolean; // true if any workspace unavailable
  data_error_minutes: number;
  overlap_intervals: Array<{
    start: string; // RFC 3339 UTC instant
    end: string;   // RFC 3339 UTC instant
    workspaces: string[];
  }>;
  workspaces: Record<string, {
    minutes: number;
    open: number;
    spans: Span[];
  }>;
};

export function across(
  days: WorkspaceDay[],
  zone: string, // IANA timezone
  now: Date
): PersonalDay[];
