package action

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
)

// Pins of SendCtx taken before it was split into check / attachments / hub
// steps (SPL-1029 round 2): every argument refusal, word for word, and the
// attachment order of a local send.

func TestSendArgRefusals(t *testing.T) {
	const hub = "http://127.0.0.1:1" // never dialled: every case is refused first
	cases := []struct {
		hub  string
		in   SendArgs
		want string
	}{
		{"", SendArgs{From: "CLE-1", To: "CLE-2", ToBox: "box-b"}, "--to-box / to_box needs hub mode ($SPOOL_HUB_URL)"},
		{"", SendArgs{From: "CLE-1", Channel: "ops"}, "--channel needs hub mode ($SPOOL_HUB_URL)"},
		{hub, SendArgs{From: "CLE-1", Channel: "-bad"}, `--channel must match ^[a-z0-9][a-z0-9-]{0,63}$, got "-bad"`},
		{hub, SendArgs{From: "CLE-1", Channel: "#Ops", ToBox: "box-b"}, "--channel posts to every member of the channel: drop --to-box"},
		{hub, SendArgs{From: "CLE-1", Channel: "ops", To: "CLE-2"}, `--channel posts to every member of the channel: --to must be empty or ALL-0, got "CLE-2"`},
		{"", SendArgs{From: "CLE-1", To: "CLE-2", TypedBy: "HUM-1"}, "--typed-by needs hub mode ($SPOOL_HUB_URL)"},
		{hub, SendArgs{From: "CLE-1", To: "CLE-2", TypedBy: "CLE-9"}, `--typed-by must be a HUM-<n> id, got "CLE-9"`},
		{"", SendArgs{From: "CLE-1", To: "CLE-2", PutFiles: []string{"/nonexistent/x"}}, "stat /nonexistent/x: no such file or directory"},
		// spec 061 3.3.1: --to <ID>@<box>
		{"", SendArgs{From: "CLE-1", To: "c-004@sat"}, `--to "c-004@sat" names box sat; local mode reaches only this machine (no $SPOOL_HUB_URL)`},
		{hub, SendArgs{From: "CLE-1", To: "c-004@Sat"}, `--to "c-004@Sat" is not <agent id>@<box id>`},
		{hub, SendArgs{From: "CLE-1", To: "c-004@sat", ToBox: "box-desk"}, `--to "c-004@sat" and --to-box "box-desk" name different boxes`},
		// spec 130 section 4: --accept accepts a result, by its msg_id
		{"", SendArgs{From: "CLE-1", To: "CLE-2", Kind: "note", Body: "x", Accepts: acceptedID}, `--accept accepts a result: it needs --kind result, got "note"`},
		{"", SendArgs{From: "CLE-1", To: "CLE-2", Kind: "result", Body: "x", Accepts: "nope"}, `--accept must be the msg_id (a uuid) of the accepted result, got "nope"`},
	}
	for _, c := range cases {
		cfg := testkit.NewConfig(t)
		cfg.HubURL = c.hub
		if _, err := Send(cfg, c.in); err == nil || err.Error() != c.want {
			t.Errorf("%+v: got %v, want %q", c.in, err, c.want)
		}
	}
}

const acceptedID = "0e1f2a3b-4c5d-4e6f-8a7b-9c0d1e2f3a4b"

// Spec 130 section 4, lane L3: a local --accept writes the v:1 key accepts
// into the recipient's inbox copy and the sender's outbox copy alike.
func TestSendLocalAccepts(t *testing.T) {
	cfg := testkit.NewConfig(t)
	testkit.Agents(t, cfg, "CLE-1", "CLE-2")
	out, err := Send(cfg, SendArgs{From: "CLE-1", To: "CLE-2", Kind: "result", Body: "ACCEPTED", Accepts: acceptedID})
	if err != nil || out.Delivery != "local" {
		t.Fatalf("local accept: %+v %v", out, err)
	}
	got, err := Recv(cfg, "CLE-2", false)
	if err != nil || len(got) != 1 || got[0].Accepts != acceptedID || got[0].MsgID != out.MsgID {
		t.Fatalf("inbox = %+v %v, want one line accepting %s", got, err, acceptedID)
	}
	obs, _ := filepath.Glob(filepath.Join(cfg.SpoolRoot, "CLE-1", "outbox", "*"))
	if len(obs) != 1 {
		t.Fatalf("outbox copies %v, want one", obs)
	}
	ob, err := os.ReadFile(obs[0])
	if err != nil || !strings.Contains(string(ob), `"accepts":"`+acceptedID+`"`) {
		t.Fatalf("outbox copy %s %v, want the accepts key", ob, err)
	}
}

func TestSendLocalAttachmentOrder(t *testing.T) {
	cfg := testkit.NewConfig(t)
	testkit.Agents(t, cfg, "CLE-2")
	dir := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	blob, err := Put(cfg, write("blob.txt", "blob"), false)
	if err != nil {
		t.Fatal(err)
	}
	sub := filepath.Join(dir, "sub")
	if err := os.Mkdir(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	write("sub/a.txt", "a")
	res, err := Send(cfg, SendArgs{From: "CLE-1", To: "CLE-2", Kind: "note", Body: "hi",
		FileIDs: []string{blob.FileID}, PutFiles: []string{write("put.txt", "put"), write("shot.png", "png")}, DirBlobs: []string{sub},
		FileRefs: []string{write("ref.txt", "ref")}, DirRefs: []string{sub}})
	if err != nil {
		t.Fatal(err)
	}
	if res.Delivery != "local" || res.MsgID == "" || res.TaskID == "" {
		t.Fatalf("result %+v", res)
	}
	msgs, err := Recv(cfg, "CLE-2", false)
	if err != nil || len(msgs) != 1 {
		t.Fatalf("recv: %v %d", err, len(msgs))
	}
	var got []string
	for _, a := range msgs[0].Files {
		got = append(got, a.Mode+"/"+a.Kind+"/"+a.Name)
	}
	want := []string{"blob/file/" + blob.FileID, // a referenced blob is named by its id
		"blob/file/put.txt", "blob/file/shot.png", "blob/dir/sub", "path/file/ref.txt", "path/dir/sub"}
	if len(got) != len(want) {
		t.Fatalf("attachments %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("attachments %v, want %v", got, want)
		}
	}
}

// spec 061 3.3.1: --to c-004@<box> is the agent c-004 on that box. Hub mode
// signs the box as to_box; local mode accepts only its own box.
func TestSplitToBox(t *testing.T) {
	cfg := testkit.NewConfig(t)
	cfg.HubURL = "http://127.0.0.1:1"
	in := SendArgs{To: "c-004@box-desk"}
	if err := splitToBox(cfg, &in); err != nil || in.To != "c-004" || in.ToBox != "box-desk" {
		t.Fatalf("hub: %+v %v", in, err)
	}
	in = SendArgs{To: "c-004@sat", ToBox: "sat"}
	if err := splitToBox(cfg, &in); err != nil || in.To != "c-004" || in.ToBox != "sat" {
		t.Fatalf("hub, same --to-box: %+v %v", in, err)
	}
	in = SendArgs{To: "CLE-2"}
	if err := splitToBox(cfg, &in); err != nil || in.To != "CLE-2" || in.ToBox != "" {
		t.Fatalf("bare id untouched: %+v %v", in, err)
	}
	cfg.HubURL, cfg.DeskBox = "", "box-desk"
	in = SendArgs{To: "c-004@box-desk"}
	if err := splitToBox(cfg, &in); err != nil || in.To != "c-004" || in.ToBox != "" {
		t.Fatalf("local, own box: %+v %v", in, err)
	}
}
