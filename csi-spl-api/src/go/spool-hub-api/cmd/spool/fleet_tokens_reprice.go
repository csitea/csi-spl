package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// cmdFleetTokensReprice prices, once, the fleet token minutes stored unpriced
// before their model had a model_prices row (SPL-2405, spec 140 T010), with
// the hub's own pricer, straight on the hub DB like `spool migrate`:
//
//	fleet-tokens-reprice --db <dsn> --models <m1,m2> --from <RFC3339|YYYY-MM-DD> [--write]
//
// Without --write it is a dry run: the same transaction, rolled back. It
// prints store.FleetTokenReprice as JSON. Run by csi-spl-orc
// do_spl_token_burn_reprice through the Cloud SQL proxy.
func cmdFleetTokensReprice(args []string) int {
	fs := flag.NewFlagSet("fleet-tokens-reprice", flag.ContinueOnError)
	dsn := fs.String("db", os.Getenv("SPOOL_HUB_DB_DSN"), "postgres DSN (default $SPOOL_HUB_DB_DSN)")
	models := fs.String("models", "", "the stored model names, comma separated (required)")
	fromS := fs.String("from", "", "the first minute, RFC3339 or a UTC date (required)")
	write := fs.Bool("write", false, "commit (default: a dry run, rolled back)")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if *dsn == "" || *models == "" || *fromS == "" || fs.NArg() != 0 {
		return fail(errors.New("--db / $SPOOL_HUB_DB_DSN, --models and --from are required"))
	}
	from, err := time.Parse(time.RFC3339, *fromS)
	if err != nil {
		if from, err = time.Parse(time.DateOnly, *fromS); err != nil {
			return fail(fmt.Errorf("--from %q is neither RFC3339 nor YYYY-MM-DD", *fromS))
		}
	}
	ctx, stop := interruptible()
	defer stop()
	pg, err := store.OpenPostgres(ctx, *dsn)
	if err != nil {
		return fail(err)
	}
	defer pg.Close()
	res, err := pg.RepriceUnpriced(ctx, strings.Split(*models, ","), from, !*write)
	if err != nil {
		return fail(err)
	}
	if err := json.NewEncoder(os.Stdout).Encode(res); err != nil {
		return fail(err)
	}
	return 0
}
