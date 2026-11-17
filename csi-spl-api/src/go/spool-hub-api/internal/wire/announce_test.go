package wire

import "testing"

// SPL-5735: which frames refuse an announce rather than answer a request.
func TestIsAnnounceRefusal(t *testing.T) {
	cases := []struct {
		name string
		f    Frame
		want bool
	}{
		{"announce_error frame", Frame{Type: TAnnounceError, Error: "quota"}, true},
		{"old hub seat cap", Frame{Type: TError, Error: "quota", Detail: DetailAnnounceSeatCap}, true},
		{"old hub duplicate", Frame{Type: TError, Error: TokenRosterDuplicate}, true},
		{"old hub roster not stored", Frame{Type: TError, Error: "internal", Detail: DetailAnnounceRosterNotStored}, true},
		{"old hub subscriptions not stored", Frame{Type: TError, Error: "internal", Detail: DetailAnnounceSubsNotStored}, true},
		{"old hub not a box", Frame{Type: TError, Error: "bad_frame", Detail: DetailAnnounceNotBox}, true},
		// controls: a request's answer
		{"keyed error naming a roster", Frame{Type: TError, MsgID: "m1", Error: TokenRosterDuplicate, Detail: DetailAnnounceSeatCap}, false},
		{"unkeyed send refusal", Frame{Type: TError, Error: "bad_json", Detail: "envelope does not parse"}, false},
		{"unkeyed tail error", Frame{Type: TError, Error: "internal", Detail: "tail read failed"}, false},
		{"sent frame", Frame{Type: TSent, Detail: DetailAnnounceSeatCap}, false},
	}
	for _, tc := range cases {
		if got := IsAnnounceRefusal(tc.f); got != tc.want {
			t.Errorf("%s: IsAnnounceRefusal = %v, want %v", tc.name, got, tc.want)
		}
	}
}
