package hub_test

import (
	"bytes"
	"encoding/json"
	"slices"
	"testing"

	"github.com/coder/websocket"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// TestBoxSampleHelloFeature (spec 071 7.8 "wire feature", row T1): a box
// whose hello carries box_sample gives a session whose features hold it; a
// box whose hello lacks it (an old binary) gives one without it. The
// box_sample_put sample is the box_stats_put object: it decodes into
// store.BoxStat with unknown keys refused.
// RED CONTROL: drop FeatureBoxSample from the hello's features: the session
// lacks it and the test fails.
func TestBoxSampleHelloFeature(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	nb := e.box(tid, "box-new", "CLE-07")
	ob := e.box(tid, "box-old", "CLE-08")
	e.pin(tid, nb)
	e.pin(tid, ob)

	cn := e.kindsHello(tid, nb, "CLE-07", []string{wire.FeatureCommit, wire.FeatureBoxSample})
	defer cn.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	co := e.kindsHello(tid, ob, "CLE-08", []string{wire.FeatureCommit})
	defer co.Close(websocket.StatusNormalClosure, "") //nolint:errcheck

	if got, ok := e.srv.BoxFeatures(tid, "box-new"); !ok || !slices.Contains(got, wire.FeatureBoxSample) {
		t.Errorf("box-new hello with %q: session features %v (live %v), want it held", wire.FeatureBoxSample, got, ok)
	}
	if got, ok := e.srv.BoxFeatures(tid, "box-old"); !ok || slices.Contains(got, wire.FeatureBoxSample) {
		t.Errorf("box-old hello without %q: session features %v (live %v), want it absent", wire.FeatureBoxSample, got, ok)
	}

	f := wire.Frame{Type: wire.TBoxSamplePut, MsgID: "33333333-3333-4333-8333-333333333333",
		Lane: json.RawMessage(`{"box":"box-new","load1":0.5,"load5":0.4,"load15":0.3,"cpus":8,"mem_total_kb":16000000,` +
			`"mem_avail_kb":9000000,"swap_used_kb":0,"agents_live":3,"disks":[{"mount":"/","total_kb":100,"avail_kb":40,"used_kb":55}]}`)}
	raw, err := json.Marshal(f)
	if err != nil {
		t.Fatal(err)
	}
	var back wire.Frame
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&back); err != nil || back.Type != wire.TBoxSamplePut || back.MsgID != f.MsgID {
		t.Fatalf("box_sample_put strict round trip: %+v (%v)", back, err)
	}
	var b store.BoxStat
	dec = json.NewDecoder(bytes.NewReader(back.Lane))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&b); err != nil {
		t.Fatalf("box_sample_put lane is not one box_stats_put object: %v", err)
	}
	if b.Box != "box-new" || b.MemTotalKB != 16000000 || len(b.Disks) != 1 || b.Disks[0].UsedKB != 55 {
		t.Errorf("box_sample_put sample decoded to %+v", b)
	}
	if why := store.CheckBoxStat(b); why != "" {
		t.Errorf("box_sample_put sample refused by CheckBoxStat: %s", why)
	}
}
