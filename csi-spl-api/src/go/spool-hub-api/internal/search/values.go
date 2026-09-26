package search

import (
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Operator values (search-v1 §2.3, §2.4, §3.2). Every check here answers a
// *Error pointing at the term; nothing reaches a store unvalidated.

var (
	// sender / recipient: an agent id, HUM-n, legacy ids, or a box id.
	idValRe  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
	boxValRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)
	chanRe   = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)
	uuidRe   = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	extRe    = regexp.MustCompile(`^[a-z0-9]{1,16}$`)
	ageRe    = regexp.MustCompile(`^([0-9]{1,4})([hdw])$`)
	sizeRe   = regexp.MustCompile(`^([0-9]{1,15})([kmg]?)$`)
)

// Channel aliases, as store.NormalizeChannel (channels-v1 C3).
const (
	channelGeneralAlias = "general"
	channelLobby        = "lobby"
)

func (p *parser) operator(t *token, name, val string, phrase, neg bool) (*Node, error) {
	o := opByName[name]
	term := &Term{Op: o.Name, Value: val, Phrase: phrase, Pos: t.pos, Raw: t.raw}
	bad := func(detail string) (*Node, error) {
		return nil, &Error{Pos: t.pos, Token: t.raw, Detail: detail}
	}
	v := strings.TrimSpace(val)
	if v == "" {
		return bad(o.Name + ": needs a value")
	}
	lv := strings.ToLower(v)
	switch o.Name {
	case OpType:
		if neg {
			return bad("type: cannot be negated")
		}
		seen := map[Type]bool{}
		for _, part := range strings.Split(lv, ",") {
			ty, ok := typeAliases[strings.TrimSpace(part)]
			if !ok {
				return bad("type: must be message, topic, file, robot, user, channel, box, tenant, event or issue")
			}
			if !seen[ty] {
				seen[ty] = true
				term.Types = append(term.Types, ty)
			}
		}
	case OpFrom, OpTo:
		id, box, at := strings.Cut(v, "@")
		switch {
		case at && idValRe.MatchString(id) && boxValRe.MatchString(box):
			term.ID, term.Box = id, box
		case !at && idValRe.MatchString(v):
			term.ID = v
		default:
			return bad(o.Name + ": must be an agent id, <agent>@<box>, HUM-<n> or a box id")
		}
	case OpBox:
		if !boxValRe.MatchString(lv) {
			return bad("box: must be a box id")
		}
		term.Box = lv
	case OpIn:
		c := strings.TrimPrefix(lv, "#")
		switch {
		case c == "dm":
			term.DM = true
		case chanRe.MatchString(c):
			if c == channelGeneralAlias {
				c = channelLobby
			}
			term.Channel = c
		default:
			return bad("in: must be a channel (#name) or dm")
		}
	case OpIs, OpHas:
		if _, ok := o.Enum[lv]; !ok {
			return bad(o.Name + ": must be one of " + enumList(o))
		}
		term.Enum = lv
		if lv == "attachment" {
			term.Enum = "file"
		}
	case OpTopic:
		if !uuidRe.MatchString(lv) {
			return bad("topic: must be a task id (UUID)")
		}
		term.Value = lv
	case OpBefore, OpAfter, OpOn:
		if err := p.date(term, o.Name, lv); err != "" {
			return bad(err)
		}
	case OpTitle:
		if !phrase {
			v, term.Prefix = prefixWord(v)
			term.Value = v
		}
		term.Lexemes = Words(v)
		if len(term.Lexemes) == 0 {
			return bad("title: needs a letter or digit")
		}
	case OpName, OpFilename:
		term.Value = v
	case OpExt:
		e := strings.TrimPrefix(lv, ".")
		if !extRe.MatchString(e) {
			return bad("ext: must be 1-16 letters or digits")
		}
		term.Value = e
	case OpStatus:
		if IssueStatusNormalize != nil {
			lv = IssueStatusNormalize(lv)
		}
		ok := false
		for _, s := range IssueStatuses {
			ok = ok || s == lv
		}
		if !ok {
			return bad("status: must be one of " + strings.Join(IssueStatuses, ", "))
		}
		term.Enum = lv
	case OpPriority:
		n, err := strconv.Atoi(lv)
		if err != nil || n < IssuePriorityMin || n > IssuePriorityMax {
			return bad("prio: must be a number " + strconv.Itoa(IssuePriorityMin) + ".." + strconv.Itoa(IssuePriorityMax))
		}
		term.Size = int64(n)
	case OpAssignee:
		switch {
		case lv == "me" || lv == "none":
			term.Enum = lv
		case idValRe.MatchString(v):
			term.ID = v
		default:
			return bad("assignee: must be a member or agent id, me or none")
		}
	case OpLabel:
		term.Value = lv
	case OpLarger, OpSmaller:
		m := sizeRe.FindStringSubmatch(lv)
		if m == nil {
			return bad(o.Name + ": must be bytes or <n>K, <n>M, <n>G")
		}
		n, _ := strconv.ParseInt(m[1], 10, 64)
		mult := map[string]int64{"": 1, "k": 1 << 10, "m": 1 << 20, "g": 1 << 30}[m[2]]
		if n > (1<<62)/mult {
			return bad(o.Name + ": too large")
		}
		n *= mult
		term.Size = n
	}
	return p.leaf(term, neg)
}

// date fills From / Until for before / after / on (search-v1 §2.3).
func (p *parser) date(t *Term, op, v string) string {
	var at time.Time
	if m := ageRe.FindStringSubmatch(v); m != nil {
		if op == OpOn {
			return "on: takes a day (YYYY-MM-DD), not an age"
		}
		n, _ := strconv.Atoi(m[1])
		if n < 1 || n > 3650 {
			return op + ": age must be 1 to 3650"
		}
		unit := map[string]time.Duration{"h": time.Hour, "d": 24 * time.Hour, "w": 7 * 24 * time.Hour}[m[2]]
		at = p.now.Add(-time.Duration(n) * unit)
	} else {
		d, err := time.Parse("2006-01-02", v)
		if err != nil {
			return op + ": must be YYYY-MM-DD or an age like 24h, 7d, 2w"
		}
		at = d
	}
	switch op {
	case OpAfter:
		t.From = at
	case OpBefore:
		t.Until = at
	case OpOn:
		t.From, t.Until = at, at.Add(24*time.Hour)
	}
	return ""
}

func enumList(o *Operator) string {
	var vs []string
	for _, k := range sortedKeys(o.Enum) {
		vs = append(vs, k)
	}
	return strings.Join(vs, ", ")
}
