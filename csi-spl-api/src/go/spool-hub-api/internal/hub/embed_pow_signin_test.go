package hub_test

import (
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// TestEmbedSignedInSkipsProof (specs/121, owner msg 62a2aac3): a signed-in
// customer's user (T205) posts its first message with no proof of work, and
// still none once its address has hits; the challenge route says not
// required. Its filled honeypot is still 403. CONTROLS: an anonymous
// visitor of the same embed gets 428 on its first post, and 428 again on a
// later post once the address has a hit, so the gate is live in this env.
func TestEmbedSignedInSkipsProof(t *testing.T) {
	e, pg := abuseEnv(t, hub.EmbedLimits{PowBits: 8, ChallengeAfterHits: 1, BanAfterHits: 50}, nil)
	k := newEmbedKey(t, "k-pow")
	tid, embed := keyedEmbed(t, e, k)
	in := accepted(t, e, tid, embed, signJWT(t, k, es256(k.Kid), claimsFor(embed, "user-1", time.Now())), "sign-in")
	anon, _ := mint(t, e, tid, embed)
	base := "/v1/embed/" + embed + "/messages"

	if code, raw := embedCall(t, e, tid, http.MethodPost, base, anon, `{"body":"hi"}`); code != http.StatusPreconditionRequired {
		t.Fatalf("CONTROL: anonymous first post, no proof: %d %s, want 428", code, raw)
	}
	if code, raw := embedCall(t, e, tid, http.MethodPost, base, in.Token, `{"body":"hi","website":"http://spam.example"}`); code != http.StatusForbidden {
		t.Errorf("signed-in honeypot: %d %s, want 403", code, raw)
	}
	if c := getChallenge(t, e, tid, embed, in.Token); c.Required {
		t.Errorf("signed-in challenge: %+v, want not required", c)
	}
	if code, raw := embedCall(t, e, tid, http.MethodPost, base, in.Token, `{"body":"hi"}`); code != http.StatusCreated {
		t.Fatalf("signed-in first post, no proof, address with a hit: %d %s, want 201", code, raw)
	}
	if code, raw := embedCall(t, e, tid, http.MethodPost, base, anon, solvedPost(t, e, tid, embed, anon, "hi")); code != http.StatusCreated {
		t.Fatalf("CONTROL: anonymous post with a proof: %d %s", code, raw)
	}
	if code, raw := embedCall(t, e, tid, http.MethodPost, base, anon, `{"body":"again"}`); code != http.StatusPreconditionRequired {
		t.Errorf("CONTROL: anonymous later post, address with a hit: %d %s, want 428", code, raw)
	}
	if _, m := embedCounts(t, pg, tid, embed); m != 2 {
		t.Errorf("messages = %d, want 2", m)
	}
}
