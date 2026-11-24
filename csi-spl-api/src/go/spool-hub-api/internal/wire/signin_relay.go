package wire

// The web-UI sign-in relay to a CLI's terminal login on a private
// workspace's VM (spec 181 row B11, gap G11; owner Q-5, Q-14 A; spec 159
// 4.3). The hub writes a signin_relay frame on the VM's role=box socket,
// MsgID = the relay id, Lane = one SigninRelayLane; the box answers with
// signin_relay_out frames, MsgID the same relay id, Lane = one
// SigninRelayOutLane. Only a socket whose hello carried FeatureSigninRelay
// is ever written one.
//
// The person's input (the code they paste back) never travels in the
// clear past the hub's request handler: Sealed is age-encrypted to the
// box's desk recipient (the pin's X25519 key, rdb 0235), so no NOTIFY
// payload, frame or table holds it, and no log line names it.

// TSigninRelay is the hub asking the box to start, feed or end one sign-in.
const TSigninRelay = "signin_relay"

// TSigninRelayOut is the box's report on one sign-in: the vendor URL to show
// the person, and how far it got.
const TSigninRelayOut = "signin_relay_out"

// FeatureSigninRelay is the hello feature of a box client that runs
// signin_relay frames (a private VM's sidecar with SPOOL_SIGNIN_RELAY_CMD).
const FeatureSigninRelay = "signin_relay"

// The ops of a SigninRelayLane.
const (
	SigninOpStart = "start" // start the CLI's own terminal login for Kind
	SigninOpInput = "input" // type the sealed input into it, then Enter
	SigninOpEnd   = "end"   // end the login session (cancel)
)

// The states a SigninRelayOutLane may report.
const (
	SigninStateURL       = "url"       // the login printed its vendor URL (URL set)
	SigninStateDelivered = "delivered" // the input was typed into the login
	SigninStateSignedIn  = "signed_in" // the CLI holds a sign-in now
	SigninStateFailed    = "failed"    // the login refused or died (Reason set)
	SigninStateEnded     = "ended"     // the login session is gone
)

// SigninRelayStates are the states a box may report.
var SigninRelayStates = []string{SigninStateURL, SigninStateDelivered, SigninStateSignedIn, SigninStateFailed, SigninStateEnded}

// SigninRelayLane is the Lane of a TSigninRelay frame. ID is unique per
// frame, so a box that gets one frame twice (a socket roll, two hub
// instances) runs it once.
type SigninRelayLane struct {
	ID     string `json:"id"`
	Op     string `json:"op"`
	Kind   string `json:"kind"`
	Sealed string `json:"sealed,omitempty"` // input only: base64 age ciphertext of SigninRelaySealed
}

// SigninRelaySealed is the plaintext inside SigninRelayLane.Sealed: the
// relay id binds it to one sign-in, so a box never types it into another.
type SigninRelaySealed struct {
	Relay string `json:"relay"`
	Input string `json:"input"`
}

// SigninRelayOutLane is the Lane of a TSigninRelayOut frame. Reason is a
// short machine word, never the CLI's own output.
type SigninRelayOutLane struct {
	State  string `json:"state"`
	URL    string `json:"url,omitempty"`
	Reason string `json:"reason,omitempty"`
}
