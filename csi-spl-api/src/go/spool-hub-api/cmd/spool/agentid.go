package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// Spec 061, the `spool` flag edge: an agent id flag is normalised once here
// (C-004 -> c-004), a legacy id becomes its new id through the box's alias
// table, and after agentid.LegacyUntil a legacy id is refused (FR-003).

// AliasFile is the alias table under the spool root (spec 061 section 5):
// old<TAB>new<TAB>kind<TAB>box<TAB>mapped-utc, keyed (old, box), written
// once by do_spl_agent_id_map. A bare legacy id resolves only when it has
// one row; <id>@<box> picks the row of that box.
const AliasFile = "agent-id-aliases.tsv"

func init() {
	// SPOOL_NOW pins the deadline clock (RFC 3339), so a proof can show the
	// refusal before the deadline arrives (FR-004).
	if v := os.Getenv("SPOOL_NOW"); v != "" {
		if t, err := time.Parse(time.RFC3339, v); err == nil {
			agentid.Now = func() time.Time { return t }
		}
	}
}

// aliasTable reads the first alias file found under the fleet root, then the
// spool root. No file is an empty table.
func aliasTable(cfg *config.Config) agentid.Table {
	m := agentid.Table{}
	for _, root := range []string{cfg.FleetRoot, cfg.SpoolRoot} {
		if root == "" {
			continue
		}
		f, err := os.Open(filepath.Join(root, AliasFile))
		if err != nil {
			continue
		}
		defer f.Close() //nolint:errcheck
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			cols := strings.Split(sc.Text(), "\t")
			if len(cols) >= 4 && agentid.IsLegacy(cols[0]) && agentid.IsNew(cols[1]) {
				m[[2]string{cols[0], cols[3]}] = cols[1]
			}
		}
		return m
	}
	return m
}

// edgeIDs resolves every non-empty agent id flag in place; the first refusal
// names its flag.
func edgeIDs(cfg *config.Config, flags map[string]*string) error {
	var table agentid.Table
	lookup := func(old, box string) (string, bool) {
		if table == nil {
			table = aliasTable(cfg)
		}
		return table.Lookup(old, box)
	}
	for name, p := range flags {
		if p == nil || *p == "" {
			continue
		}
		got, err := agentid.Resolve(*p, lookup)
		if err != nil {
			return fmt.Errorf("--%s: %w", name, err)
		}
		*p = got
	}
	return nil
}
