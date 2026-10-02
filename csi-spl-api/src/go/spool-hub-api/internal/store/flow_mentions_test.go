package store

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// mentionFixture is the shared parity fixture (spec 062 FR-014): each body
// with the ids the WUI's mentionedIds returns for it.
var mentionFixture = []struct {
	body string
	want []string
}{
	{"hi @HUM-10 there", []string{"HUM-10"}},
	{"@HUM-10", []string{"HUM-10"}},
	{"@HUM-10, @GST-3.", []string{"HUM-10", "GST-3"}},
	{"@c-001@sat ok", []string{"c-001"}},
	{"@c-001@c-002", []string{"c-001"}}, // the second id is eaten as a box
	{"@c-001 @c-002", []string{"c-001", "c-002"}},
	{"@HUM-1@HUM-2", []string{"HUM-1", "HUM-2"}}, // an upper-case box is no box
	{"@c-0012", nil},
	{"@c-001x", nil},
	{"@HUM-1x", nil},
	{"@HUM-1_", nil},
	{"@HUMAN-1", nil},
	{"@ABCDE-1", nil},
	{"@H-1", nil},
	{"@CLE-77952 and @QWN-9", []string{"CLE-77952", "QWN-9"}},
	{"mail x@GST-4 here", []string{"GST-4"}}, // no lookbehind in MENTION_RE
	{"@@HUM-5", []string{"HUM-5"}},
	{"@HUM-5@box-", []string{"HUM-5"}},
	{"@HUM-5@box-a-b, next", []string{"HUM-5"}},
	{"@HUM-5@" + strings.Repeat("a", 40) + " @HUM-6", []string{"HUM-5", "HUM-6"}},
	{"@HUM-5@" + strings.Repeat("a", 32) + "@HUM-6", []string{"HUM-5", "HUM-6"}},
	{"`@HUM-7` (@q-123)", []string{"HUM-7", "q-123"}},
	{"@b-001 @c-000", []string{"c-000"}},
	{"ünï @HUM-8ü", []string{"HUM-8"}},
	{"no mention at all", nil},
	{"@HUM-9\n@HUM-9", []string{"HUM-9", "HUM-9"}},
}

func TestMentionedIDsFixture(t *testing.T) {
	for _, c := range mentionFixture {
		if got := MentionedIDs(c.body); !reflect.DeepEqual(got, c.want) {
			t.Errorf("MentionedIDs(%q) = %v, want %v", c.body, got, c.want)
		}
	}
}

// wuiUtils is csi-spl-wui/src/utils from this package.
var wuiUtils = filepath.Join("..", "..", "..", "..", "..", "..", "csi-spl-wui", "src", "utils")

// TestMentionGrammarPinnedToWUI: the JS sources the port was written
// against. A change on either side fails here until the other follows.
func TestMentionGrammarPinnedToWUI(t *testing.T) {
	pins := map[string][]string{
		"agent-id.mjs": {
			"export const AGENT_ID_SRC = '[acgq]-[0-9]{3}(?![0-9])'",
			"export const LEGACY_ID_SRC = '[A-Z]{2,4}-[0-9]+'",
			"export const PARTICIPANT_ID_SRC = `(?:${AGENT_ID_SRC}|${LEGACY_ID_SRC})`",
			"export const BOX_ID_SRC = '[a-z0-9][a-z0-9-]{0,31}'",
		},
		"notify.mjs": {
			"export const MENTION_RE = new RegExp(String.raw`@(${PARTICIPANT_ID_SRC})(?:@${BOX_ID_SRC})?\\b`, 'g')",
		},
		"mention-poke.mjs": {
			"return `${String(author || '').split('@')[0]} needs you in ${link}: \"${pokeExcerpt(text)}\"`",
			"return `${String(origin || '').replace(/\\/+$/, '')}/t/${encodeURIComponent(String(taskId || ''))}`",
		},
	}
	for file, lines := range pins {
		b, err := os.ReadFile(filepath.Join(wuiUtils, file))
		if err != nil {
			t.Fatal(err)
		}
		for _, l := range lines {
			if !strings.Contains(string(b), l) {
				t.Errorf("%s no longer holds %q: port the change to flow_mentions.go, then update this pin", file, l)
			}
		}
	}
}

// TestMentionParityWithNode runs the fixture through the WUI's own
// mentionedIds when node is on PATH (the WUI unit job has it; a Go-only
// runner skips and relies on the fixture and the source pins above).
func TestMentionParityWithNode(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node not on PATH")
	}
	abs, err := filepath.Abs(filepath.Join(wuiUtils, "notify.mjs"))
	if err != nil {
		t.Fatal(err)
	}
	bodies := make([]string, len(mentionFixture))
	for i, c := range mentionFixture {
		bodies[i] = c.body
	}
	in, _ := json.Marshal(bodies)
	script := `import(process.argv[1]).then((m) => {
		const bodies = JSON.parse(require('fs').readFileSync(0, 'utf8'))
		process.stdout.write(JSON.stringify(bodies.map((b) => m.mentionedIds(b))))
	})`
	cmd := exec.Command(node, "-e", script, "file://"+abs)
	cmd.Stdin = strings.NewReader(string(in))
	out, err := cmd.Output()
	if err != nil {
		t.Skipf("node could not load notify.mjs: %v", err)
	}
	var js [][]string
	if err := json.Unmarshal(out, &js); err != nil {
		t.Fatal(err)
	}
	for i, c := range mentionFixture {
		got := MentionedIDs(c.body)
		if len(got) == 0 && len(js[i]) == 0 {
			continue
		}
		if !reflect.DeepEqual(got, js[i]) {
			t.Errorf("%q: Go %v, WUI %v", c.body, got, js[i])
		}
	}
}

func TestPokeTask(t *testing.T) {
	const task = "6b1f8f9e-2a59-4d0e-9a51-0b8c3f3a2d10"
	for body, want := range map[string]string{
		`HUM-10 needs you in https://<<run-time>>.csitea.net/t/` + task + `: "look"`: task,
		`c-004 needs you in /t/` + strings.ToUpper(task) + `: ""`:                    task,
		`HUM-10 needs you in https://x/t/` + task + ` "look"`:                        "",
		`please: HUM-10 needs you in https://x/t/` + task + `: "x"`:                  "",
		`HUM-10 needs you in https://x/t/not-a-task: "x"`:                            "",
	} {
		if got := PokeTask(body); got != want {
			t.Errorf("PokeTask(%q) = %q, want %q", body, got, want)
		}
	}
}

func TestFlowMentions(t *testing.T) {
	got := flowMentions("@HUM-1 @c-001 @HUM-2 @HUM-1 @GST-3 @HUM-9", "HUM-9")
	if want := []string{"HUM-1", "HUM-2", "GST-3"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("flowMentions = %v, want %v", got, want)
	}
}
