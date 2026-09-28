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

// operator parses one op:value term; a bad value answers a *Error pointing
// at the term.
func (p *parser) operator(t *token, name, val string, phrase, neg bool) (*Node, error) {
	o := opByName[name]
	term := &Term{Op: o.Name, Value: val, Phrase: phrase, Pos: t.pos, Raw: t.raw}
	if detail := p.value(term, o, strings.TrimSpace(val), neg); detail != "" {
		return nil, &Error{Pos: t.pos, Token: t.raw, Detail: detail}
	}
	return p.leaf(term, neg)
}

// value checks the trimmed value v of operator o and fills term; it answers
// the error detail, or "" when the value is good.
func (p *parser) value(term *Term, o *Operator, v string, neg bool) string {
	if v == "" {
		return o.Name + ": needs a value"
	}
	lv := strings.ToLower(v)
	switch o.Name {
	case OpType:
		return typeValue(term, lv, neg)
	case OpFrom, OpTo:
		return idValue(term, o.Name, v)
	case OpBox:
		if !boxValRe.MatchString(lv) {
			return "box: must be a box id"
		}
		term.Box = lv
	case OpIn:
		return channelValue(term, lv)
	case OpIs, OpHas:
		return enumValue(term, o, lv)
	case OpTopic:
		if !uuidRe.MatchString(lv) {
			return "topic: must be a task id (UUID)"
		}
		term.Value = lv
	case OpBefore, OpAfter, OpOn:
		return p.date(term, o.Name, lv)
	case OpTitle:
		return titleValue(term, v)
	case OpName, OpFilename:
		term.Value = v
	case OpExt:
		return extValue(term, lv)
	case OpStatus:
		return statusValue(term, lv)
	case OpPriority:
		return priorityValue(term, lv)
	case OpAssignee:
		return assigneeValue(term, v, lv)
	case OpLabel:
		term.Value = lv
	case OpLarger, OpSmaller:
		return sizeValue(term, o.Name, lv)
	}
	return ""
}

// typeValue: type: takes a comma list of section names, each kept once.
func typeValue(term *Term, lv string, neg bool) string {
	if neg {
		return "type: cannot be negated"
	}
	seen := map[Type]bool{}
	for _, part := range strings.Split(lv, ",") {
		ty, ok := typeAliases[strings.TrimSpace(part)]
		if !ok {
			return "type: must be message, topic, file, robot, user, channel, box, tenant, event or issue"
		}
		if !seen[ty] {
			seen[ty] = true
			term.Types = append(term.Types, ty)
		}
	}
	return ""
}

// idValue: from: / to: take <id>, <id>@<box> or a box id.
func idValue(term *Term, op, v string) string {
	id, box, at := strings.Cut(v, "@")
	switch {
	case at && idValRe.MatchString(id) && boxValRe.MatchString(box):
		term.ID, term.Box = id, box
	case !at && idValRe.MatchString(v):
		term.ID = v
	default:
		return op + ": must be an agent id, <agent>@<box>, HUM-<n> or a box id"
	}
	return ""
}

// channelValue: in: takes #name, name (general is the lobby) or dm.
func channelValue(term *Term, lv string) string {
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
		return "in: must be a channel (#name) or dm"
	}
	return ""
}

// enumValue: is: / has: take one of the operator's enum values
// (attachment is file).
func enumValue(term *Term, o *Operator, lv string) string {
	if _, ok := o.Enum[lv]; !ok {
		return o.Name + ": must be one of " + enumList(o)
	}
	term.Enum = lv
	if lv == "attachment" {
		term.Enum = "file"
	}
	return ""
}

// titleValue: title: words; an unquoted trailing '*' makes the last one a
// prefix.
func titleValue(term *Term, v string) string {
	if !term.Phrase {
		v, term.Prefix = prefixWord(v)
		term.Value = v
	}
	term.Lexemes = Words(v)
	if len(term.Lexemes) == 0 {
		return "title: needs a letter or digit"
	}
	return ""
}

// extValue: ext: takes an extension, with or without its dot.
func extValue(term *Term, lv string) string {
	e := strings.TrimPrefix(lv, ".")
	if !extRe.MatchString(e) {
		return "ext: must be 1-16 letters or digits"
	}
	term.Value = e
	return ""
}

// statusValue: status: takes one of the workflow's names (older names
// normalized first).
func statusValue(term *Term, lv string) string {
	if IssueStatusNormalize != nil {
		lv = IssueStatusNormalize(lv)
	}
	ok := false
	for _, s := range IssueStatuses {
		ok = ok || s == lv
	}
	if !ok {
		return "status: must be one of " + strings.Join(IssueStatuses, ", ")
	}
	term.Enum = lv
	return ""
}

// priorityValue: prio: takes a number in the workflow's range.
func priorityValue(term *Term, lv string) string {
	n, err := strconv.Atoi(lv)
	if err != nil || n < IssuePriorityMin || n > IssuePriorityMax {
		return "prio: must be a number " + strconv.Itoa(IssuePriorityMin) + ".." + strconv.Itoa(IssuePriorityMax)
	}
	term.Size = int64(n)
	return ""
}

// assigneeValue: assignee: takes me, none or a member / agent id.
func assigneeValue(term *Term, v, lv string) string {
	switch {
	case lv == "me" || lv == "none":
		term.Enum = lv
	case idValRe.MatchString(v):
		term.ID = v
	default:
		return "assignee: must be a member or agent id, me or none"
	}
	return ""
}

// sizeValue: larger: / smaller: take bytes or <n>K, <n>M, <n>G.
func sizeValue(term *Term, op, lv string) string {
	m := sizeRe.FindStringSubmatch(lv)
	if m == nil {
		return op + ": must be bytes or <n>K, <n>M, <n>G"
	}
	n, _ := strconv.ParseInt(m[1], 10, 64)
	mult := map[string]int64{"": 1, "k": 1 << 10, "m": 1 << 20, "g": 1 << 30}[m[2]]
	if n > (1<<62)/mult {
		return op + ": too large"
	}
	term.Size = n * mult
	return ""
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
