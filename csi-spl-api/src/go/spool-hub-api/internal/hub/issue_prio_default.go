package hub

import (
	"context"
	"slices"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A new issue's priority when its create names none (SPL-4725, spec 039).
// Owner HUM-10, t1 3aac280f msg b364e9d5: "the issues should inherit the prio
// attributes of their parent discussions"; t1 6c9aa54b msgs c1a3ab4b ("All of
// the bugs should get prio 1 by default") and 9e0911ed (alerts, prio 1); t1
// 3aac280f msg 1ee85284 ("All of the refactoring issues should be always of
// prio 2 by default"). The one rule, in this order:
//  1. a priority the create names wins (the WUI always names one);
//  2. else the highest (lowest number) priority SET on a linked discussion:
//     a stored topic_priorities row, a set 3 too; an unset topic, which reads
//     3 everywhere else (spec 150 v1.1), does not count;
//  3. else the class, read from the issue's labels: bug or alert 1,
//     refactor 2 (the placer labels a lane issue from its brief's Class:);
//  4. else store.IssuePriorityDefault (5), as before.
// It applies at create only: an existing issue is never re-prioritised.

// issueClassPriority is step 3: label id -> default priority.
var issueClassPriority = map[string]int{"bug": 1, "alert": 1, "refactor": 2}

// defaultIssuePriority answers steps 2..3 for a create that named no
// priority; 0 = none applies, the store's default stands.
func (s *Server) defaultIssuePriority(ctx context.Context, tenant string, discussions, labels []string) (int, error) {
	if p, err := s.setDiscussionPriority(ctx, tenant, discussions); err != nil || p > 0 {
		return p, err
	}
	return classPriority(labels), nil
}

// setDiscussionPriority is the highest priority set on one of discussions,
// 0 when none is set (or this store keeps no topic priorities).
func (s *Server) setDiscussionPriority(ctx context.Context, tenant string, discussions []string) (int, error) {
	ps, ok := s.o.Store.(store.TopicPriorityStore)
	if !ok || len(discussions) == 0 {
		return 0, nil
	}
	set, err := ps.SetTopicPriorities(ctx, tenant, discussions)
	if err != nil {
		return 0, err
	}
	best := 0
	for _, p := range set {
		if best == 0 || p < best {
			best = p
		}
	}
	return best, nil
}

// classPriority is the highest class default among labels, 0 for none.
func classPriority(labels []string) int {
	best := 0
	for l, p := range issueClassPriority {
		if slices.Contains(labels, l) && (best == 0 || p < best) {
			best = p
		}
	}
	return best
}
