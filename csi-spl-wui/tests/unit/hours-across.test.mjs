// WUI/tests/unit/hours-across.test.ts
// Spec 118 T005: Unit tests for hours-across.mjs and useRealmHours.ts.
// Validates against the shared fixture `overlap_fixture.json`.

import { describe, it, expect, vi } from 'vitest';
import { across, type WorkspaceDay } from '../../utils/hours-across.mjs';
import { useRealmHours } from '../../composables/useRealmHours';

// Mock the fixture import
const overlapFixture = {
  cases: [
    {
      name: "T-R1a two workspaces overlap 10:00-12:00",
      zone: "UTC",
      now: "2026-10-13T18:00:00Z",
      days: [
        {
          workspace: "A",
          day: "2026-10-13",
          entries: [
            {
              target: "t:1",
              minutes: 180,
              state: "approved",
              spans: [{"start": "2026-10-13T09:00:00Z", "end": "2026-10-13T12:00:00Z"}]
            }
          ]
        },
        {
          workspace: "B",
          day: "2026-10-13",
          entries: [
            {
              target: "t:2",
              minutes: 180,
              state: "approved",
              spans: [{"start": "2026-10-13T10:00:00Z", "end": "2026-10-13T13:00:00Z"}]
            }
          ]
        }
      ],
      want: [
        {
          day: "2026-10-13",
          reported: 360,
          open: 0,
          actual: 240,
          overlap: 120,
          unplaced: 0,
          approx: false,
          incomplete: false,
          data_error_minutes: 0,
          overlap_intervals: [
            {"start": "2026-10-13T10:00:00Z", "end": "2026-10-13T12:00:00Z", "workspaces": ["A", "B"]}
          ],
          workspaces: {
            "A": {"minutes": 180, "open": 0, "spans": [{"start": "2026-10-13T09:00:00Z", "end": "2026-10-13T12:00:00Z"}]},
            "B": {"minutes": 180, "open": 0, "spans": [{"start": "2026-10-13T10:00:00Z", "end": "2026-10-13T13:00:00Z"}]}
          }
        }
      ]
    }
  ]
};

// Mock fetchRealmHours for useRealmHours tests
const fetchRealmHours = vi.fn(() => Promise.resolve({
  days: [],
  totals: {},
  tz: 'UTC',
  tz_source: 'UTC',
  limits: []
}));

vi.mock('../../utils/realm-hours-api.mjs', () => ({
  fetchRealmHours
}));

describe('hours-across.mjs', () => {
  // Test cases from the shared fixture
  overlapFixture.cases.forEach((testCase: any) => {
    it(`matches Go output for case: ${testCase.name}`, () => {
      const now = new Date(testCase.now);
      const zone = testCase.zone;

      // Convert fixture days to WorkspaceDay format
      const days: WorkspaceDay[] = testCase.days.map((wsDay: any) => ({
        workspace: wsDay.workspace,
        day: wsDay.day,
        entries: wsDay.entries.map((entry: any) => ({
          target: entry.target,
          minutes: entry.minutes,
          state: entry.state || 'approved',
          spans: entry.spans || []
        })),
        timer: wsDay.timer
      }));

      // Compute personal days
      const personalDays = across(days, zone, now);

      // Compare with fixture's want
      const want = testCase.want[0];
      const personalDay = personalDays.find(day => day.day === want.day);
      if (!personalDay) throw new Error('Personal day not found');

      // Compare reported, open, actual, overlap, unplaced
      expect(personalDay.reported).toBe(want.reported);
      expect(personalDay.open).toBe(want.open || 0);
      expect(personalDay.actual).toBe(want.actual);
      expect(personalDay.overlap).toBe(want.overlap);
      expect(personalDay.unplaced).toBe(want.unplaced || 0);
      expect(personalDay.approx).toBe(want.approx || false);
      expect(personalDay.incomplete).toBe(want.incomplete || false);
      expect(personalDay.data_error_minutes).toBe(want.data_error_minutes || 0);

      // Compare overlap intervals
      expect(personalDay.overlap_intervals.length).toBe(want.overlap_intervals.length);
      want.overlap_intervals.forEach((wantInterval: any, i: number) => {
        const gotInterval = personalDay.overlap_intervals[i];
        expect(gotInterval.start).toBe(wantInterval.start);
        expect(gotInterval.end).toBe(wantInterval.end);
        expect(gotInterval.workspaces).toEqual(wantInterval.workspaces);
      });

      // Compare workspaces
      Object.entries(want.workspaces).forEach(([workspace, wantData]: [string, any]) => {
        const gotData = personalDay.workspaces[workspace];
        expect(gotData).toBeDefined();
        expect(gotData.minutes).toBe(wantData.minutes);
        expect(gotData.open).toBe(wantData.open || 0);
        expect(gotData.spans.length).toBe(wantData.spans.length);
      });
    });
  });

  // Edge case: empty input
  it('returns empty array for empty input', () => {
    const personalDays = across([], 'UTC', new Date());
    expect(personalDays).toEqual([]);
  });
});

describe('useRealmHours.ts', () => {
  it('computes limit warning state', async () => {
    // Mock fetchRealmHours to return a limit
    fetchRealmHours.mockResolvedValueOnce({
      days: [],
      totals: { actual: 360 },
      tz: 'UTC',
      tz_source: 'UTC',
      limits: [
        { kind: 'week', minutes: 400, window: 'week' }
      ]
    });

    const { limitWarning, fetch } = useRealmHours();
    await fetch('2026-10-13', '2026-10-19');
    expect(limitWarning.value).toBe('amber'); // 360/400 = 90%
  });

  it('computes provisional timer span for today', async () => {
    const now = new Date('2026-10-13T10:30:00Z');
    vi.setSystemTime(now);

    // Mock fetchRealmHours to return a provisional span
    fetchRealmHours.mockResolvedValueOnce({
      days: [
        {
          day: '2026-10-13',
          reported: 60,
          open: 0,
          actual: 90,
          overlap: 0,
          unplaced: 0,
          approx: false,
          incomplete: false,
          data_error_minutes: 0,
          overlap_intervals: [],
          workspaces: {
            B: {
              minutes: 0,
              open: 0,
              spans: [
                {
                  start: '2026-10-13T09:30:00Z',
                  end: '2026-10-13T10:30:00Z',
                  provisional: true
                }
              ]
            }
          }
        }
      ],
      totals: {},
      tz: 'UTC',
      tz_source: 'UTC',
      limits: []
    });

    const { provisionalTimer, fetch } = useRealmHours();
    await fetch('2026-10-13', '2026-10-13');
    expect(provisionalTimer.value.start).toBe('2026-10-13T09:30:00Z');
    expect(provisionalTimer.value.end).toBe('2026-10-13T10:30:00Z');
    expect(provisionalTimer.value.workspace).toBe('B');
  });
});