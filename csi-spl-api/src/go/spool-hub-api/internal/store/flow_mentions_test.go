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

// TestMentionedIDsMistral: m- (spec 110) is an agent letter; an unknown
// letter is not. Kept out of mentionFixture, which the node parity test also
// runs through the WUI, until T010 moves the WUI grammar.
func TestMentionedIDsMistral(t *testing.T) {
	for body, want := range map[string][]string{
		"@m-004 look":       {"m-004"},
		"@m-004@box-a done": {"m-004"},
		"@x-004 @m-0041":    nil,
		"@m-000":            {"m-000"},
	} {
		if got := MentionedIDs(body); !reflect.DeepEqual(got, want) {
			t.Errorf("MentionedIDs(%q) = %v, want %v", body, got, want)
		}
	}
}

// wuiUtils is csi-spl-wui/src/utils from this package.
var wuiUtils = filepath.Join("..", "..", "..", "..", "..", "..", "csi-spl-wui", "src", "utils")

// grammarContract is csi-spl-wui/src/utils/mention-grammar.json, the one
// mention grammar both sides read (SPL-3435 I8): agent-id.mjs builds its id
// regexes from it, and the hand scan in flow_mentions.go was written against
// these sources.
var grammarContract = filepath.Join(wuiUtils, "mention-grammar.json")

// TestMentionGrammarContract pins the Go scan to the shared contract, not to
// WUI source text: a grammar change fails here until flow_mentions.go
// follows; renaming or unexporting a WUI const does not.
func TestMentionGrammarContract(t *testing.T) {
	b, err := os.ReadFile(grammarContract)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]string
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("%s: %v", grammarContract, err)
	}
	for key, want := range map[string]string{
		"agent_id_src":  "[acgmq]-[0-9]{3}(?![0-9])", // agentIDAt
		"legacy_id_src": "[A-Z]{2,4}-[0-9]+",         // legacyIDAt
		"box_id_src":    "[a-z0-9][a-z0-9-]{0,31}",   // boxEnd
	} {
		if got[key] != want {
			t.Errorf("mention-grammar.json %s = %q, the Go scan implements %q: port the change to flow_mentions.go, then update this pin", key, got[key], want)
		}
	}
}

// TestMentionParityWithNode runs the fixture through the WUI's own
// mentionedIds when node is on PATH (the WUI unit job has it; a Go-only
// runner skips and relies on the fixture and the grammar contract above).
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

// TestPokeBodyParityWithNode: the DM the WUI's mention-poke.mjs writes is
// one PokeTask reads its task back from (node on PATH, as above).
func TestPokeBodyParityWithNode(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node not on PATH")
	}
	abs, err := filepath.Abs(filepath.Join(wuiUtils, "mention-poke.mjs"))
	if err != nil {
		t.Fatal(err)
	}
	const task = "6b1f8f9e-2a59-4d0e-9a51-0b8c3f3a2d10"
	script := `import(process.argv[1]).then((m) => process.stdout.write(m.pokeBody({
		author: 'HUM-10@box-a', link: m.cardLink('https://example.com//', process.argv[2]),
		text: 'look  at\n this',
	})))`
	out, err := exec.Command(node, "-e", script, "file://"+abs, task).Output()
	if err != nil {
		t.Skipf("node could not load mention-poke.mjs: %v", err)
	}
	body := string(out)
	if want := `HUM-10 needs you in https://example.com/t/` + task + `: "look at this"`; body != want {
		t.Errorf("pokeBody = %q, want %q", body, want)
	}
	if got := PokeTask(body); got != task {
		t.Errorf("PokeTask(%q) = %q, want %q", body, got, task)
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
