// WUI/utils/hours-across.mjs
// Spec 118 T005: Client-side overlap computation for today's running timer.
// Matches Go `Across` function output for the shared fixture `overlap_fixture.json`.
// Input: Array of WorkspaceDay objects, personal timezone, and current time.
// Output: Array of PersonalDay objects, matching Go's `Across` output.

/**
 * @typedef {import('./hours-across').Span} Span
 * @typedef {import('./hours-across').WorkspaceDay} WorkspaceDay
 * @typedef {import('./hours-across').PersonalDay} PersonalDay
 */

/**
 * Compute overlap intervals using a sweep line algorithm.
 * @param {Span[]} spans - Array of spans (UTC instants)
 * @returns {Array<{start: string, end: string, workspaces: string[]}>} Overlap intervals
 */
function computeOverlapIntervals(spans) {
  const events = [];

  // Create events: {time, type, workspace}
  spans.forEach(span => {
    events.push({ time: span.start, type: 'start', workspace: span.workspace });
    events.push({ time: span.end, type: 'end', workspace: span.workspace });
  });

  // Sort events: time ascending, end before start at the same time
  events.sort((a, b) => {
    if (a.time !== b.time) return a.time < b.time ? -1 : 1;
    return a.type === 'end' ? -1 : 1;
  });

  const overlapIntervals = [];
  const activeWorkspaces = new Set();
  let currentStart = null;

  events.forEach(event => {
    if (event.type === 'start') {
      activeWorkspaces.add(event.workspace);
      if (activeWorkspaces.size >= 2 && currentStart === null) {
        currentStart = event.time;
      }
    } else {
      if (activeWorkspaces.size >= 2 && currentStart !== null) {
        overlapIntervals.push({
          start: currentStart,
          end: event.time,
          workspaces: Array.from(activeWorkspaces).sort()
        });
      }
      activeWorkspaces.delete(event.workspace);
      currentStart = activeWorkspaces.size >= 2 ? event.time : null;
    }
  });

  return overlapIntervals;
}

/**
 * Clip spans to a day in the personal timezone.
 * @param {Span[]} spans - Array of spans (UTC instants)
 * @param {Date} dayStart - Start of day in personal timezone (UTC)
 * @param {Date} dayEnd - End of day in personal timezone (UTC)
 * @returns {Span[]} Clipped spans
 */
function clipSpansToDay(spans, dayStart, dayEnd) {
  return spans
    .map(span => {
      const start = new Date(span.start);
      const end = new Date(span.end);
      const clippedStart = start < dayStart ? dayStart : start;
      const clippedEnd = end > dayEnd ? dayEnd : end;
      if (clippedStart >= clippedEnd) return null;
      return { ...span, start: clippedStart.toISOString(), end: clippedEnd.toISOString() };
    })
    .filter(Boolean);
}

/**
 * Compute personal day from workspace days.
 * @param {WorkspaceDay[]} days - Array of WorkspaceDay objects
 * @param {string} zone - IANA timezone (e.g., 'UTC')
 * @param {Date} now - Current time (UTC)
 * @returns {PersonalDay[]} Array of PersonalDay objects
 */
export function across(days, zone, now) {
  // Group entries by day in the personal timezone
  const personalDays = {};

  days.forEach(workspaceDay => {
    const dayDate = new Date(`${workspaceDay.day}T00:00:00Z`);
    const dayKey = dayDate.toISOString().split('T')[0];

    if (!personalDays[dayKey]) {
      personalDays[dayKey] = {
        day: dayKey,
        reported: 0,
        open: 0,
        actual: 0,
        overlap: 0,
        unplaced: 0,
        approx: false,
        incomplete: false,
        data_error_minutes: 0,
        overlap_intervals: [],
        workspaces: {}
      };
    }

    const personalDay = personalDays[dayKey];
    const workspace = workspaceDay.workspace;
    let workspaceMinutes = 0;
    let workspaceOpen = 0;
    const workspaceSpans = [];

    workspaceDay.entries.forEach(entry => {
      const entryMinutes = entry.minutes || 0;
      workspaceMinutes += entryMinutes;
      if (entry.state === 'open') workspaceOpen += entryMinutes;

      if (entry.spans && entry.spans.length > 0) {
        entry.spans.forEach(span => {
          workspaceSpans.push({ ...span, workspace });
        });
      } else {
        personalDay.unplaced += entryMinutes;
      }
    });

    // Add provisional timer span if running (not counted in reported or open)
    if (workspaceDay.timer) {
      const timerStart = workspaceDay.timer;
      const timerEnd = now.toISOString();
      workspaceSpans.push({
        start: timerStart,
        end: timerEnd,
        provisional: true,
        workspace
      });
    }

    personalDay.reported += workspaceMinutes;
    personalDay.open += workspaceOpen;
    // Provisional timer spans are not counted in reported or open, only in actual
    personalDay.workspaces[workspace] = {
      minutes: workspaceMinutes,
      open: workspaceOpen,
      spans: workspaceSpans
    };
  });

  // Process each personal day
  return Object.values(personalDays).map(personalDay => {
    const dayStart = new Date(`${personalDay.day}T00:00:00Z`);
    const dayEnd = new Date(dayStart);
    dayEnd.setUTCDate(dayEnd.getUTCDate() + 1);

    // Clip spans to the personal day
    const allSpans = [];
    Object.entries(personalDay.workspaces).forEach(([workspace, data]) => {
      const clippedSpans = clipSpansToDay(data.spans, dayStart, dayEnd);
      clippedSpans.forEach(span => allSpans.push({ ...span, workspace }));
    });

    // Compute overlap intervals
    const overlapIntervals = computeOverlapIntervals(allSpans);
    personalDay.overlap_intervals = overlapIntervals.map(interval => ({
      start: interval.start.replace(/\.000Z$/, "Z"),
      end: interval.end.replace(/\.000Z$/, "Z"),
      workspaces: interval.workspaces
    }));

    // Compute actual minutes (union of spans + unplaced)
    const spanUnion = new Set();
    allSpans.forEach(span => {
      const start = new Date(span.start).getTime();
      const end = new Date(span.end).getTime();
      for (let t = start; t < end; t += 60000) {
        spanUnion.add(t);
      }
    });
    personalDay.actual = spanUnion.size + personalDay.unplaced;
    
    // Compute overlap only for non-provisional spans
    const nonProvisionalSpans = allSpans.filter(span => !span.provisional);
    const nonProvisionalUnion = new Set();
    nonProvisionalSpans.forEach(span => {
      const start = new Date(span.start).getTime();
      const end = new Date(span.end).getTime();
      for (let t = start; t < end; t += 60000) {
        nonProvisionalUnion.add(t);
      }
    });
    const nonProvisionalActual = nonProvisionalUnion.size + personalDay.unplaced;
    personalDay.overlap = personalDay.reported - nonProvisionalActual;
    personalDay.approx = personalDay.unplaced > 0;

    return personalDay;
  });
}