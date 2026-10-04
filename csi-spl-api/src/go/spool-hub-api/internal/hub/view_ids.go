package hub

import (
	"net/http"
	"regexp"
	"slices"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// POST /v1/view/ids (HUM-10, topic cd357c76): the ids quoted in ONE rendered
// body, resolved in one call, so an id the browser tab has not loaded (a DM
// quoting a channel it never opened, an archived topic) still becomes a
// link. The door is a topic read's: the session's tenant, an archived topic
// answers, a DM only to an end of it, a channel topic only to a reader of
// one of its channels. An id the reader may not read reads exactly like an
// unknown one: it is left out.

const (
	viewIDsMax     = 50
	viewIDsMaxBody = 8 << 10
)

var shortIDRe = regexp.MustCompile(`^[0-9a-f]{8}$`)

type viewIDsReq struct {
	IDs []string `json:"ids"`
}

// viewIDHit is one resolved id. id is the token as asked (a full uuid or its
// 8-hex start); task_id is the topic a link opens (a reply's parent topic).
type viewIDHit struct {
	ID       string `json:"id"`
	Kind     string `json:"kind"`
	TaskID   string `json:"task_id"`
	MsgID    string `json:"msg_id,omitempty"`
	Channel  string `json:"channel,omitempty"`
	Peer     string `json:"peer,omitempty"`
	Archived bool   `json:"archived"`
}

type viewIDsBody struct {
	IDs []viewIDHit `json:"ids"`
}

func (s *Server) viewIDsPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "POST")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleViewIDs(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	var req viewIDsReq
	if !readJSONStrict(w, r, &req, viewIDsMaxBody, "invalid JSON body (only ids)") {
		return
	}
	toks, full, short, rf := viewIDTokens(req.IDs)
	if rf != nil {
		writeErr(w, rf.status, rf.token, rf.detail)
		return
	}
	body := viewIDsBody{IDs: []viewIDHit{}}
	lk, ok := s.o.Store.(store.IDLookups)
	if !ok || len(toks) == 0 {
		writeJSON(w, http.StatusOK, body)
		return
	}
	hum, ok := s.readerID(r, t.ID)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "ids unavailable")
		return
	}
	mine, err := s.readerChannels(r.Context(), t.ID, hum)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "ids unavailable")
		return
	}
	facts, err := lk.LookupIDs(r.Context(), t.ID, full, short, s.o.Now(), s.o.LobbyTaskID)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("view ids")
		writeErr(w, http.StatusInternalServerError, "internal", "ids unavailable")
		return
	}
	rd := idReader{hum: hum, mine: mine}
	for _, tok := range toks {
		f, found := pickIDFact(facts, tok)
		if !found {
			continue
		}
		if hit, may := rd.place(f); may {
			hit.ID = tok
			body.IDs = append(body.IDs, hit)
		}
	}
	writeJSON(w, http.StatusOK, body)
}

// viewIDTokens splits the asked ids into full uuids and 8-hex starts, lower
// case, each once, in asked order.
func viewIDTokens(ids []string) (toks, full, short []string, rf *viewRefusal) {
	seen := map[string]bool{}
	for _, raw := range ids {
		id := strings.ToLower(strings.TrimSpace(raw))
		if seen[id] {
			continue
		}
		seen[id] = true
		switch {
		case uuidRe.MatchString(id):
			full = append(full, id)
		case shortIDRe.MatchString(id):
			short = append(short, id)
		default:
			return nil, nil, nil, &viewRefusal{http.StatusBadRequest, "bad_id", "each id is a uuid or its first 8 hex digits"}
		}
		toks = append(toks, id)
	}
	if len(toks) > viewIDsMax {
		return nil, nil, nil, &viewRefusal{http.StatusBadRequest, "too_many", "at most 50 ids per call"}
	}
	return toks, full, short, nil
}

// pickIDFact is the fact tok names. A full uuid: its own fact (a topic wins,
// the store already decided). An 8-hex start: the topic when exactly one
// starts with it; else, when none does, the message when exactly one does.
// The count is over every stored row, readable or not, so it is the same
// for every reader.
func pickIDFact(facts []store.IDFact, tok string) (store.IDFact, bool) {
	if len(tok) != 8 {
		for _, f := range facts {
			if f.ID == tok {
				return f, true
			}
		}
		return store.IDFact{}, false
	}
	var topics, msgs []store.IDFact
	for _, f := range facts {
		if !strings.HasPrefix(f.ID, tok) {
			continue
		}
		if f.Kind == store.IDTopic {
			topics = append(topics, f)
		} else {
			msgs = append(msgs, f)
		}
	}
	switch {
	case len(topics) == 1:
		return topics[0], true
	case len(topics) == 0 && len(msgs) == 1:
		return msgs[0], true
	}
	return store.IDFact{}, false
}

// idReader is one caller's door onto IDFacts: hum "" reads all (door off).
type idReader struct {
	hum  string
	mine []string
}

func (rd idReader) channel(ch string) bool {
	return rd.hum == "" || store.ChannelPublic(ch) || slices.Contains(rd.mine, store.NormalizeChannel(ch))
}

func (rd idReader) party(f store.IDFact) bool {
	return rd.hum == "" || slices.Contains(f.Parties, rd.hum)
}

// place is where a link to f opens for this reader; false = not readable.
// A topic opens in its first channel the reader may read, else as their DM.
func (rd idReader) place(f store.IDFact) (viewIDHit, bool) {
	hit := viewIDHit{Kind: f.Kind, TaskID: f.TaskID, MsgID: f.MsgID, Archived: f.Archived}
	if f.Kind == store.IDMessage {
		if f.Channel != "" {
			hit.Channel = f.Channel
			return hit, rd.channel(f.Channel)
		}
		hit.Peer = rd.peer(f.Ends)
		return hit, rd.party(f)
	}
	if f.Channel != "" && rd.channel(f.Channel) {
		hit.Channel = f.Channel
		return hit, true
	}
	for _, ch := range f.Channels {
		if ch != "" && rd.channel(ch) {
			hit.Channel = ch
			return hit, true
		}
	}
	if slices.Contains(f.Channels, "") && rd.party(f) {
		hit.Peer = rd.peer(f.Ends)
		return hit, true
	}
	return hit, false
}

// peer is the DM end that is not the reader, as the sidebar names it; ""
// when both ends are the reader (or a broadcast).
func (rd idReader) peer(ends []string) string {
	for _, e := range ends {
		id, _, _ := strings.Cut(e, "@")
		if id == "" || id == rd.hum || id == "ALL-0" {
			continue
		}
		return e
	}
	return ""
}
