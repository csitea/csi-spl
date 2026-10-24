package pollform

import (
	"encoding/json"
	"os"
	"reflect"
	"regexp"
	"strings"
	"testing"
)

// fixture is testdata/poll-form-cases.json, the cases shared with the WUI's
// pollProblems (csi-spl-wui/src/utils/poll.mjs): its problems are the JS's
// own lines, so the hub refuses exactly the fences the WUI shows as code.
type fixture struct {
	Cases []struct {
		Name     string   `json:"name"`
		Body     string   `json:"body"`
		Problems []string `json:"problems"`
	} `json:"cases"`
}

func loadCases(t *testing.T) fixture {
	t.Helper()
	raw, err := os.ReadFile("testdata/poll-form-cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var f fixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	if len(f.Cases) < 20 {
		t.Fatalf("fixture holds %d cases, want >= 20", len(f.Cases))
	}
	return f
}

func TestProblemsMatchesWUIFixture(t *testing.T) {
	for _, c := range loadCases(t).Cases {
		got := Problems(c.Body)
		if len(got) == 0 && len(c.Problems) == 0 {
			continue
		}
		if !reflect.DeepEqual(got, c.Problems) {
			t.Errorf("%s:\n got  %q\n want %q", c.Name, got, c.Problems)
		}
	}
}

// The owner's form of 10-24 (t1 8f476aa8, msg 64f8633b): keys of 4
// characters are options, a key of 9 is none, and the old 1-3 rule (red
// control) would have refused the owner's form.
func TestKeyLengthOneToEight(t *testing.T) {
	form := "```poll\nWhich plan?\n(S90) Small 90\n(S180) Small 180\n(K365) Kit 365\n```"
	if p := Problems(form); len(p) != 0 {
		t.Fatalf("owner's S180 form refused: %q", p)
	}
	if p := Problems("```poll\nWhich?\n(ABCDEFGH) eight\n```"); len(p) != 0 {
		t.Fatalf("8-character key refused: %q", p)
	}
	if p := Problems("```poll\nWhich?\n(ABCDEFGHI) nine\n```"); len(p) != 1 {
		t.Fatalf("9-character key taken as an option: %q", p)
	}
	old := strings.Replace(optionRE.String(), "{1,8}", "{1,3}", 1)
	if old == optionRE.String() {
		t.Fatal("control: optionRE no longer carries the {1,8} key rule")
	}
	saved := optionRE
	defer func() { optionRE = saved }()
	optionRE = mustCompile(t, old)
	if p := Problems(form); len(p) != 1 || !strings.Contains(p[0], "has no option line") {
		t.Fatalf("red control: the 1-3 key rule must refuse the S180 form, got %q", p)
	}
}

func TestNoFenceNoProblem(t *testing.T) {
	for _, body := range []string{"", "plain", "```go\nfmt.Println()\n```", "text ```poll inline"} {
		if p := Problems(body); p != nil {
			t.Errorf("%q: %q", body, p)
		}
	}
}

func mustCompile(t *testing.T, re string) *regexp.Regexp {
	t.Helper()
	r, err := regexp.Compile(re)
	if err != nil {
		t.Fatal(err)
	}
	return r
}
