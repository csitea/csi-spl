// WUI/utils/hours-across.d.ts
// TypeScript declarations for hours-across.mjs

export interface Span {
  start: string; // RFC 3339 UTC timestamp
  end: string; // RFC 3339 UTC timestamp
  provisional?: boolean; // True if span is provisional (e.g., running timer)
  workspace?: string; // Workspace ID (added for internal use)
}

export interface WorkspaceDay {
  workspace: string; // Workspace ID
  day: string; // Date in YYYY-MM-DD format
  entries: Array<{
    target: string;
    minutes: number;
    state: string;
    spans: Span[];
  }>;
  timer?: string; // RFC 3339 UTC timestamp if timer is running
}

export interface PersonalDay {
  day: string; // Date in YYYY-MM-DD format
  reported: number; // Total reported minutes (approved + open suggestions)
  open: number; // Open minutes (suggestions)
  actual: number; // Actual minutes (union of spans + unplaced)
  overlap: number; // Overlap minutes (reported - actual)
  unplaced: number; // Unplaced minutes (no spans)
  approx: boolean; // True if unplaced minutes exist (no times)
  incomplete: boolean; // True if a workspace was unavailable
  data_error_minutes: number; // Minutes with data errors
  overlap_intervals: Array<{
    start: string;
    end: string;
    workspaces: string[];
  }>; // Overlap intervals
  workspaces: Record<string, {
    minutes: number;
    open: number;
    spans: Span[];
  }>; // Per-workspace details
}