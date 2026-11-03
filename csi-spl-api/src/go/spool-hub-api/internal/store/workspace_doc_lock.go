package store

import "context"

// The per-person document lock (spec 125 row B8, section 5.3; rdb 0256;
// owner HUM-10 C7, C8, C9): workspace_doc.restricted_to_human holds the one
// human who may read the document. rdb 0256's human_lock policies hide the
// document, its items and its rev log from every statement whose
// app.doc_human_id is not that human: another member, any admin role, an agent
// token, an act-as clone, the operator scope. The store sets app.doc_human_id
// only from WithHuman (humanScope), so a reader the hub did not mark sees a
// locked document as gone, a 404, and in no list, tree or search.
//
// Who may set it: the context's human only, and only to themselves; the
// policy's WITH CHECK refuses any other value. Who may lift it: the same
// human, the only one who can see the row. DocCreateRestricted creates a
// document locked from its first statement.

// DocLock locks doc to the context's human (on) or lifts the lock (off), as a
// structural op: the doc lock, rev precondition (0 = none), one doc rev and
// its rev-log entry. ErrNoPerson when ctx carries no human (WithHuman); 404
// when the doc is gone, another tenant's or another human's.
func (s *Postgres) DocLock(ctx context.Context, tenant, doc string, rev int64, on bool, actor string) (DocOpResult, error) {
	hum := HumanOf(ctx)
	if hum == "" {
		return DocOpResult{}, ErrNoPerson
	}
	var to any
	if on {
		to = hum
	}
	var res DocOpResult
	err := s.inDoc(ctx, tenant, doc, func(d *wsDocTx) error {
		if err := d.lock(ctx, rev); err != nil {
			return err
		}
		tag, err := d.tx.Exec(ctx, `UPDATE workspace_doc SET restricted_to_human = $2 WHERE id = $1`, d.doc, to)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return ErrDocNotFound
		}
		res.Rev, err = d.bump(ctx, actor, map[string]any{"kind": "lock", "on": on})
		return err
	})
	return res, err
}
