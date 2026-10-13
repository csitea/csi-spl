// SPDX-License-Identifier: AGPL-3.0-only

package hours

import (
	"errors"
	"fmt"
	"sort"
	"time"
)

type WorkspaceDay struct {
	WorkspaceID string
	Date        string
	Entries     []Entry
	Receipts    []Receipt
	State       string
}

type Entry struct {
	Start    *time.Time
	End      *time.Time
	Minutes  int
	Unplaced int
}

type Receipt struct {
	Minutes  int
	Approver string
}

type PersonalDay struct {
	Date       string
	Reported   int
	Actual     int
	Overlap    int
	Workspaces map[string]WorkspaceDayResult
}

type WorkspaceDayResult struct {
	Reported int
	Actual   int
	Spans    []TimeSpan
}

type TimeSpan struct {
	Start time.Time
	End   time.Time
}

func sortedKeys(m map[string][]WorkspaceDay) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func calculateSpanMinutes(spans []TimeSpan) int {
	total := 0
	for _, span := range spans {
		total += int(span.End.Sub(span.Start).Minutes())
	}
	return total
}

// mergeSpans merges overlapping or adjacent spans into a single list of non-overlapping spans.
func mergeSpans(spans []TimeSpan) []TimeSpan {
	if len(spans) == 0 {
		return []TimeSpan{}
	}

	// Sort spans by start time.
	sort.Slice(spans, func(i, j int) bool {
		return spans[i].Start.Before(spans[j].Start)
	})

	merged := []TimeSpan{spans[0]}
	for _, span := range spans[1:] {
		last := &merged[len(merged)-1]
		if span.Start.Before(last.End) || span.Start.Equal(last.End) {
			// Overlapping or adjacent spans: merge them.
			if span.End.After(last.End) {
				last.End = span.End
			}
		} else {
			// Non-overlapping span: add it to the list.
			merged = append(merged, span)
		}
	}

	return merged
}

func Across(days []WorkspaceDay, zone *time.Location, now time.Time) ([]PersonalDay, error) {
	if zone == nil {
		return nil, errors.New("hours: no time zone")
	}

	// Group workspaces by their personal date in the specified timezone.
	byDate := map[string][]WorkspaceDay{}
	for _, wd := range days {
		wsDate, err := time.ParseInLocation("2006-01-02", wd.Date, time.UTC)
		if err != nil {
			return nil, fmt.Errorf("hours: invalid date %q", wd.Date)
		}
		personalDate := wsDate.In(zone).Format("2006-01-02")
		byDate[personalDate] = append(byDate[personalDate], wd)
	}

	// Collect all spans and group them by personal date.
	allSpansByDate := map[string][]TimeSpan{}
	reportedByDate := map[string]int{}
	unplacedByDate := map[string]int{}
	workspaceResults := map[string]map[string]WorkspaceDayResult{}

	// Initialize all dates with empty results.
	for date := range byDate {
		workspaceResults[date] = make(map[string]WorkspaceDayResult)
		allSpansByDate[date] = []TimeSpan{}
		reportedByDate[date] = 0
		unplacedByDate[date] = 0
	}

	for _, wd := range days {
		wsDate, err := time.ParseInLocation("2006-01-02", wd.Date, time.UTC)
		if err != nil {
			return nil, fmt.Errorf("hours: invalid date %q", wd.Date)
		}
		personalDate := wsDate.In(zone).Format("2006-01-02")

		wsReported := 0
		wsUnplaced := 0
		workspaceSpans := []TimeSpan{}

		if wd.State != "ok" {
			workspaceResults[personalDate][wd.WorkspaceID] = WorkspaceDayResult{
				Reported: 0,
				Actual:   0,
			}
			continue
		}

		for _, e := range wd.Entries {
			wsUnplaced += e.Unplaced
			if e.End != nil {
				wsReported += e.Minutes
				start := e.Start.In(zone)
				end := e.End.In(zone)
				if end.After(start) {
					// Split spans that cross midnight into separate days.
					currentStart := start
					for {
						nextDay := time.Date(currentStart.Year(), currentStart.Month(), currentStart.Day()+1, 0, 0, 0, 0, zone)
						if end.After(nextDay) {
							workspaceSpans = append(workspaceSpans, TimeSpan{Start: currentStart, End: nextDay})
							allSpansByDate[personalDate] = append(allSpansByDate[personalDate], TimeSpan{Start: currentStart.UTC(), End: nextDay.UTC()})
							currentStart = nextDay
							personalDate = currentStart.Format("2006-01-02")
							if _, ok := workspaceResults[personalDate]; !ok {
								workspaceResults[personalDate] = make(map[string]WorkspaceDayResult)
								allSpansByDate[personalDate] = []TimeSpan{}
								reportedByDate[personalDate] = 0
								unplacedByDate[personalDate] = 0
							}
						} else {
							workspaceSpans = append(workspaceSpans, TimeSpan{Start: currentStart, End: end})
							allSpansByDate[personalDate] = append(allSpansByDate[personalDate], TimeSpan{Start: currentStart.UTC(), End: end.UTC()})
							break
						}
					}
				} else if e.Start != nil {
					end := now.In(zone)
					if end.After(*e.Start) {
						start := e.Start.In(zone)
						workspaceSpans = append(workspaceSpans, TimeSpan{Start: start, End: end})
						allSpansByDate[personalDate] = append(allSpansByDate[personalDate], TimeSpan{Start: start.UTC(), End: end.UTC()})
					}
				}
			}

			// Receipts contribute to Reported and Actual, but not to Overlap.
			for _, r := range wd.Receipts {
				wsReported += r.Minutes
			}

			reportedByDate[personalDate] += wsReported + wsUnplaced
			unplacedByDate[personalDate] += wsUnplaced

			workspaceResults[personalDate][wd.WorkspaceID] = WorkspaceDayResult{
				Reported: wsReported + wsUnplaced,
				Actual:   calculateSpanMinutes(workspaceSpans) + wsUnplaced,
				Spans:    workspaceSpans,
			}
		}

		// Build the result.
		result := []PersonalDay{}
		for date := range byDate {
			merged := mergeSpans(allSpansByDate[date])
			actual := calculateSpanMinutes(merged)
			reported := reportedByDate[date]
			unplaced := unplacedByDate[date]

			overlap := reported - (actual + unplaced)
			if overlap < 0 {
				overlap = 0
			}

			personalDay := PersonalDay{
				Date:       date,
				Reported:   reported,
				Actual:     actual + unplaced,
				Overlap:    overlap,
				Workspaces: workspaceResults[date],
			}

			result = append(result, personalDay)
		}

		// Sort the result by date.
		sort.Slice(result, func(i, j int) bool {
			return result[i].Date < result[j].Date
		})

		return result, nil
	}
}
