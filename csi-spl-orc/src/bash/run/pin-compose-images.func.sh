#!/bin/bash
#------------------------------------------------------------------------------
# @description Pin the root docker-compose.yml to a stable release's images BY
# @description DIGEST (SPL-2153, owner security scan action 10: "Pin production
# @description images to sha256 digests instead of the floating
# @description stable-YYYY-MM-DD tag"). Workflow 56 writes spool-images.txt,
# @description one <repo>/spool-{hub,web}:<tag>@sha256:<digest> line per image,
# @description and attaches it to the stable release; this action reads it and
# @description rewrites the defaults:
# @description   docker-compose.yml  spool-hub / spool-web :${SPOOL_IMAGE_TAG:-<tag>@sha256:<digest>}
# @description   .env.example        # SPOOL_IMAGE_TAG=<tag>
# @description A digest no tag move can change; setting SPOOL_IMAGE_TAG replaces
# @description tag and digest together, so a chosen tag never pulls a stale digest.
# @description Dry run unless DRY_RUN=0: prints the new lines, writes nothing.
# @description It never commits: commit the two files like any change.
# @param PIN_IMAGES_FILE (optional) - a local spool-images.txt; default: gh release download of PIN_TAG
# @param PIN_TAG (optional) - the stable release, default the newest stable-* tag of the checkout
# @param PIN_TREE (optional) - the checkout, default $APP_PATH
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_pin_compose_images
# @example PIN_TAG=stable-2026-10-12 DRY_RUN=0 ./run -a do_pin_compose_images
#------------------------------------------------------------------------------
do_pin_compose_images() {
  local dry=1 tree="${PIN_TREE:-$APP_PATH}" tag="${PIN_TAG:-}" file="${PIN_IMAGES_FILE:-}" tmp="" rc=0
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ -f "$tree/docker-compose.yml" && -f "$tree/.env.example" ]] ||
    { do_log "FATAL no docker-compose.yml + .env.example in $tree"; return 1; }
  if [[ -z "$file" ]]; then
    [[ -n "$tag" ]] || tag="$(git -C "$tree" tag -l 'stable-*' --sort=-v:refname | sed -n 1p)"
    [[ -n "$tag" ]] || { do_log "FATAL no stable-* tag in $tree: set PIN_TAG or PIN_IMAGES_FILE"; return 1; }
    do_require_bin gh || return 1
    tmp="$(mktemp -d)"; file="$tmp/spool-images.txt"
    (cd "$tree" && gh release download "$tag" -p spool-images.txt -D "$tmp") >/dev/null 2>&1 ||
      { rm -rf "$tmp"; do_log "FATAL release $tag has no spool-images.txt (wf 56 writes it once the images are pushed)"; return 1; }
  fi
  python3 - "$file" "$tree" "$dry" "$tag" <<'PY' || rc=$?
import re, sys
path, tree, dry, want_tag = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4]
line_re = re.compile(r"^(\S+)/(spool-hub|spool-web):([A-Za-z0-9_][A-Za-z0-9_.-]{0,127})@(sha256:[0-9a-f]{64})$")
pins = {}
for raw in open(path):
    raw = raw.strip()
    if not raw:
        continue
    m = line_re.match(raw)
    if not m:
        sys.exit(f"FATAL {path}: not <repo>/spool-{{hub,web}}:<tag>@sha256:<64 hex>: {raw}")
    pins[m.group(2)] = (m.group(3), m.group(4))
if set(pins) != {"spool-hub", "spool-web"}:
    sys.exit(f"FATAL {path}: want one spool-hub and one spool-web line, got {sorted(pins)}")
tags = {t for t, _ in pins.values()}
if len(tags) != 1 or (want_tag and want_tag not in tags):
    sys.exit(f"FATAL {path}: the two images name different tags or not {want_tag}: {sorted(tags)}")
tag = tags.pop()
compose = f"{tree}/docker-compose.yml"
s = open(compose).read()
for img, (_, digest) in pins.items():
    s, n = re.subn(r"(/" + img + r":\$\{SPOOL_IMAGE_TAG:-)[^}]*(\})", r"\g<1>" + f"{tag}@{digest}" + r"\g<2>", s)
    if n == 0:
        sys.exit(f"FATAL {compose}: no {img}:${{SPOOL_IMAGE_TAG:-...}} image line to pin")
    print(f"{img}: {tag}@{digest} ({n} line{'s' if n > 1 else ''})")
env = f"{tree}/.env.example"
e, n = re.subn(r"(?m)^# SPOOL_IMAGE_TAG=.*$", f"# SPOOL_IMAGE_TAG={tag}", open(env).read())
if n != 1:
    sys.exit(f"FATAL {env}: want one '# SPOOL_IMAGE_TAG=' line, found {n}")
if not dry:
    open(compose, "w").write(s)
    open(env, "w").write(e)
print(("would write" if dry else "wrote") + " docker-compose.yml and .env.example")
PY
  [[ -n "$tmp" ]] && rm -rf "$tmp"
  ((rc == 0)) || { do_log "FATAL pin-compose-images failed (exit $rc)"; return 1; }
  if ((dry)); then
    do_log "INFO dry run: nothing written; DRY_RUN=0 writes the two files"
  else
    do_log "INFO pinned: review and commit docker-compose.yml + .env.example"
  fi
}
