package store

import (
	"strings"
	"testing"
)

// TestSearchFileLinesSQLMatchesTheStoredEntry (spec 160 row B7, 5.7): a
// text term of in:file-streams matches the line's stored entry
// l.search_tsv, and the statement never computes to_tsvector over a line;
// that took ~15.6 s over 500 000 lines on dev, past the 7 s search budget.
// Red control: the old leaf `to_tsvector('spool_search', l.text) @@ ...`
// fails both checks for every query below.
func TestSearchFileLinesSQLMatchesTheStoredEntry(t *testing.T) {
	for _, q := range []string{
		`in:file-streams deploy`,
		`in:file-streams "token burn"`,
		`in:file-streams deplo*`,
		`in:file-streams deploy -failed box:sat`,
	} {
		sql, _ := searchFileLinesSQL("t1", SearchQuery{Q: mustParse(t, q), Limit: 20})
		if !strings.Contains(sql, "l.search_tsv @@ ") {
			t.Errorf("%s: the match is not on l.search_tsv:\n%s", q, sql)
		}
		if strings.Contains(sql, "to_tsvector(") {
			t.Errorf("%s: the statement computes to_tsvector:\n%s", q, sql)
		}
	}
}
