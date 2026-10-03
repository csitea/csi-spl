package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// cmdLifecycle is the box harness's door to the agent context lifecycle
// (spec 063 sections 11 and 12), over the authenticated hello like `spool
// lane`:
//
//	lifecycle config                       the config in force, KEY=VALUE lines
//	lifecycle event --json <file|-> [--fleet <f>]   append one event
//
// The harness caches the config and spools a failed event locally (spec 063
// 11, 12); this verb is the one round trip and nothing more.
func cmdLifecycle(cfg *config.Config, args []string) int {
	if len(args) == 0 {
		return fail(errors.New("usage: spool lifecycle config | spool lifecycle event --json <file|-> [--fleet <f>]"))
	}
	if cfg.HubURL == "" {
		return fail(errors.New("the lifecycle config needs hub mode ($SPOOL_HUB_URL is not set)"))
	}
	switch args[0] {
	case "config":
		return lifecycleConfig(cfg, args[1:])
	case "event":
		return lifecycleEvent(cfg, args[1:])
	}
	return fail(fmt.Errorf("lifecycle: unknown sub-verb %q (config | event)", args[0]))
}

func lifecycleConfig(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("lifecycle config", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return 1
	}
	ctx, stop := interruptible()
	defer stop()
	raw, err := hubclient.New(cfg).Lane(ctx, "lifecycle_config", "", nil)
	if err != nil {
		return fail(err)
	}
	var body struct {
		Config map[string]json.RawMessage `json:"config"` // a number, or an enum string
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		return fail(fmt.Errorf("lifecycle config: the hub's answer does not parse: %w", err))
	}
	// The key table's order, so the output is stable; a key this build does
	// not know yet still prints, after them.
	seen := map[string]bool{}
	for _, k := range store.LifecycleKeys {
		if v, ok := body.Config[k.Key]; ok {
			fmt.Printf("%s=%s\n", strings.ToUpper(k.Key), lifecycleValue(v))
			seen[k.Key] = true
		}
	}
	for k, v := range body.Config {
		if !seen[k] {
			fmt.Printf("%s=%s\n", strings.ToUpper(k), lifecycleValue(v))
		}
	}
	return 0
}

// lifecycleValue is a config value as a shell word: a number as is, an enum
// string unquoted (its values are [a-z] words).
func lifecycleValue(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	return string(raw)
}

func lifecycleEvent(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("lifecycle event", flag.ContinueOnError)
	src := fs.String("json", "", "the event object: a file, or - for stdin")
	fleet := fs.String("fleet", "", "the fleet, when the event does not name one")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if *src == "" {
		return fail(errors.New("lifecycle event: --json <file|-> is required"))
	}
	var raw []byte
	var err error
	if *src == "-" {
		raw, err = io.ReadAll(io.LimitReader(os.Stdin, 64<<10))
	} else {
		raw, err = os.ReadFile(*src)
	}
	if err != nil {
		return fail(err)
	}
	var e store.LifecycleEvent
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&e); err != nil {
		return fail(fmt.Errorf("lifecycle event: not one event object: %w", err))
	}
	if why := store.CheckLifecycleEvent(e); why != "" {
		return fail(fmt.Errorf("lifecycle event: %s", why))
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := hubclient.New(cfg).Lane(ctx, "lifecycle_event", *fleet, json.RawMessage(raw))
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
