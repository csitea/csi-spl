// SPDX-License-Identifier: AGPL-3.0-only

package wire

import "testing"

// The contract of the refusal a box client parses (spec 169 T7b). CONTROLS: the
// other details a refusal carries do not read as a destination.
func TestMovedDetailRoundTrip(t *testing.T) {
	tenant, link, ok := ParseMovedDetail(MovedDetail("t2", "https://t2.example.com/t/u"))
	if !ok || tenant != "t2" || link != "https://t2.example.com/t/u" {
		t.Fatalf("round trip: %q %q %v", tenant, link, ok)
	}
	for _, d := range []string{"", "this topic is gone from this workspace", "topic moved: tenant=t2", "topic moved: tenant= link=x", "topic moved: tenant=t2 link="} {
		if _, _, ok := ParseMovedDetail(d); ok {
			t.Errorf("%q read as a destination", d)
		}
	}
}
