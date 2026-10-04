#!/usr/bin/env bash
# spl_warm_go_mod_cache <module dir> (spec 072 A66)
#
# The api tests run offline (GOPROXY=off), which on a fresh clone fails at the
# first import: the module cache is cold. This fills it once, then returns so
# the caller can go offline as before. A warm cache costs one offline
# `go mod download` and downloads nothing.
#
# The download honours the caller's GOPROXY / GOSUMDB (go's own defaults when
# unset). A caller that exported GOPROXY=off asked for no network: a cold
# cache then fails here, naming the cause, instead of at the first import.
# Returns non-zero when the cache stays cold.
spl_warm_go_mod_cache() {
  local mod="$1"
  if (cd "$mod" && GOPROXY=off GOFLAGS=-mod=mod go mod download) >/dev/null 2>&1; then
    return 0
  fi
  if [ "${GOPROXY:-}" = off ]; then
    echo "go module cache is cold and GOPROXY=off: unset GOPROXY once to download the modules" >&2
    return 1
  fi
  echo "== go module cache cold: go mod download (once; the tests then run offline) =="
  (cd "$mod" && GOFLAGS=-mod=mod go mod download)
}
