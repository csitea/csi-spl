// WUI/tests/unit/hours-across.test.mjs
// Spec 118 T005: Unit tests for hours-across.mjs.
// Validates against the shared fixture `overlap_fixture.json`.

import { across } from '../../src/utils/hours-across.mjs';
import { readFileSync } from 'fs';

const overlapFixture = JSON.parse(
  readFileSync('/opt/csi/csi-spl-wt/m-180/csi-spl-api/src/go/spool-hub-api/internal/hours/testdata/overlap_fixture.json', 'utf8')
);

let failed = 0;
const ok = (name, cond, why = '') => {
  if (cond) console.log(`  OK   ${name}`);
  else {
    failed++;
    console.log(`  FAIL ${name} ${why}`);
  }
};

console.log('hours-across');

// Test cases from the shared fixture
overlapFixture.cases.forEach((testCase) => {
  const name = `matches Go output for case: ${testCase.name}`;
  try {
    const now = new Date(testCase.now);
    const zone = testCase.zone;

    // Convert fixture days to WorkspaceDay format
    const days = testCase.days.map((wsDay) => ({
      workspace: wsDay.workspace,
      day: wsDay.day,
      entries: wsDay.entries || [],
      timer: wsDay.timer
    }));

    // Compute personal days
    const personalDays = across(days, zone, now);

    // Compare with fixture's want
    const want = testCase.want[0];
    const personalDay = personalDays.find(day => day.day === want.day);
    if (!personalDay) throw new Error('Personal day not found');

    // Compare reported, open, actual, overlap, unplaced
    ok(`${name} (reported)`, personalDay.reported === want.reported);
    ok(`${name} (open)`, personalDay.open === (want.open || 0));
    ok(`${name} (actual)`, personalDay.actual === want.actual);
    ok(`${name} (overlap)`, personalDay.overlap === want.overlap);
    ok(`${name} (unplaced)`, personalDay.unplaced === (want.unplaced || 0));
    ok(`${name} (approx)`, personalDay.approx === (want.approx || false));
    ok(`${name} (incomplete)`, personalDay.incomplete === (want.incomplete || false));
    ok(`${name} (data_error_minutes)`, personalDay.data_error_minutes === (want.data_error_minutes || 0));

    // Compare overlap intervals
    ok(`${name} (overlap_intervals length)`, personalDay.overlap_intervals.length === want.overlap_intervals.length);
    want.overlap_intervals.forEach((wantInterval, i) => {
      const gotInterval = personalDay.overlap_intervals[i];
      if (!gotInterval) {
        failed++;
        console.log(`  FAIL ${name} (overlap_intervals[${i}] missing)`);
        return;
      }
      ok(`${name} (overlap_intervals[${i}].start)`, gotInterval.start === wantInterval.start);
      ok(`${name} (overlap_intervals[${i}].end)`, gotInterval.end === wantInterval.end);
      ok(`${name} (overlap_intervals[${i}].workspaces)`, JSON.stringify(gotInterval.workspaces) === JSON.stringify(wantInterval.workspaces));
    });

    // Compare workspaces
    Object.entries(want.workspaces).forEach(([workspace, wantData]) => {
      const gotData = personalDay.workspaces[workspace];
      ok(`${name} (workspaces[${workspace}] defined)`, gotData !== undefined);
      if (gotData) {
        ok(`${name} (workspaces[${workspace}].minutes)`, gotData.minutes === wantData.minutes);
        ok(`${name} (workspaces[${workspace}].open)`, gotData.open === (wantData.open || 0));
        ok(`${name} (workspaces[${workspace}].spans length)`, gotData.spans.length === wantData.spans.length);
      }
    });
  } catch (err) {
    failed++;
    console.log(`  FAIL ${name} ${err.message}`);
  }
});

// Edge case: empty input
try {
  const personalDays = across([], 'UTC', new Date());
  ok('returns empty array for empty input', personalDays.length === 0);
} catch (err) {
  failed++;
  console.log(`  FAIL returns empty array for empty input ${err.message}`);
}

if (failed > 0) {
  console.log(`\nhours-across: ${failed} check(s) failed`);
  process.exit(1);
} else {
  console.log('\nhours-across: all checks passed');
}