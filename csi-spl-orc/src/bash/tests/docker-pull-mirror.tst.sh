#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: scripts/docker-pull-mirror.sh, offline: docker is a stub whose
#          "images" are files in $T/img and whose registries answer per
#          FAKE_MIRROR_OK / FAKE_HUB_OK.
#   1. no argument / no tag: exit 2, no docker call
#   2. a cached image: no pull at all
#   3. absent: pulled from mirror.gcr.io and tagged to the canonical name,
#      no Docker Hub pull (library and org images alike)
#   4. the mirror down: Docker Hub once, exit 0
#   5. both down: exit 1, a FAIL line naming the image
#   6. the workflows that pull Docker Hub images on the runners go through it
#   7. CONTROL: the stub records a pull it is given
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
S="$PROJ_ROOT/src/bash/scripts/docker-pull-mirror.sh"
WF="$APP_ROOT/.github/workflows"

mkdir -p "$T/stub" "$T/img"
cat >"$T/stub/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"$FAKE_LOG"
k() { printf '%s' "$1" | tr '/:' '__'; }
case "$1 $2" in
  "image inspect") [[ -f "$FAKE_IMG/$(k "$3")" ]] ;;
  "pull -q") if [[ "$3" == mirror.gcr.io/* ]]; then ok="${FAKE_MIRROR_OK:-1}"; else ok="${FAKE_HUB_OK:-1}"; fi
             [[ "$ok" == 1 ]] && touch "$FAKE_IMG/$(k "$3")" ;;
  tag*)      [[ -f "$FAKE_IMG/$(k "$2")" ]] && touch "$FAKE_IMG/$(k "$3")" ;;
  *) exit 9 ;;
esac
EOF
chmod +x "$T/stub/docker"
run() { : >"$T/log"; env PATH="$T/stub:$PATH" FAKE_LOG="$T/log" FAKE_IMG="$T/img" DOCKER_PULL_SLEEP=0 "$@" bash "$S" "${ARGS[@]}" >"$T/out" 2>&1; }

# 1
ARGS=(); run; rc=$?
[[ $rc -eq 2 && ! -s "$T/log" ]] && pass "1. no argument: exit 2, no docker call" || fail "1. no argument: rc=$rc $(cat "$T/log")"
ARGS=(postgres); run; rc=$?
[[ $rc -eq 2 && ! -s "$T/log" ]] && pass "1. an untagged image: exit 2, no docker call" || fail "1. untagged: rc=$rc $(cat "$T/log")"

# 2
touch "$T/img/postgres_16-alpine"
ARGS=(postgres:16-alpine); run; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '^docker pull' "$T/log" && pass "2. a cached image: no pull" || fail "2. cached: rc=$rc $(cat "$T/log")"
rm -f "$T/img/"*

# 3
ARGS=(postgres:16-alpine fsouza/fake-gcs-server:1.52.2); run; rc=$?
[[ $rc -eq 0 && -f "$T/img/postgres_16-alpine" && -f "$T/img/fsouza_fake-gcs-server_1.52.2" ]] \
  && grep -qx 'docker pull -q mirror.gcr.io/postgres:16-alpine' "$T/log" \
  && grep -qx 'docker tag mirror.gcr.io/fsouza/fake-gcs-server:1.52.2 fsouza/fake-gcs-server:1.52.2' "$T/log" \
  && ! grep -qE '^docker pull -q (postgres|fsouza)' "$T/log" \
  && pass "3. absent: pulled via mirror.gcr.io, tagged to the canonical name, no Docker Hub pull" || fail "3. mirror: rc=$rc $(cat "$T/log")"
rm -f "$T/img/"*

# 4
ARGS=(alpine:3.22); run FAKE_MIRROR_OK=0; rc=$?
[[ $rc -eq 0 && $(grep -c '^docker pull -q mirror.gcr.io/alpine:3.22$' "$T/log") -eq 3 \
   && $(grep -c '^docker pull -q alpine:3.22$' "$T/log") -eq 1 ]] \
  && pass "4. the mirror down: 3 mirror tries, then Docker Hub once" || fail "4. fallback: rc=$rc $(cat "$T/log")"
rm -f "$T/img/"*

# 5
ARGS=(alpine:3.22); run FAKE_MIRROR_OK=0 FAKE_HUB_OK=0; rc=$?
[[ $rc -eq 1 ]] && grep -q 'FAIL cannot pull alpine:3.22' "$T/out" \
  && pass "5. both down: exit 1 and a FAIL line" || fail "5. both down: rc=$rc $(cat "$T/out")"

# 6
for f in 10_ci-quality.yml 20_hub-build-deploy.yml 50_oss-standalone.yml; do
  if grep -q 'docker-pull-mirror.sh' "$WF/$f" && ! grep -qE '^\s*(for i in .*)?docker pull ' "$WF/$f"; then
    pass "6. $f pulls through docker-pull-mirror.sh, no bare docker pull"
  else fail "6. $f: a bare docker pull, or no docker-pull-mirror.sh"; fi
done
for f in "$APP_ROOT/csi-spl-api/src/docker/hub.Dockerfile" "$APP_ROOT/csi-spl-wui/src/docker/wui.Dockerfile"; do
  bad=$(grep -E '^FROM ' "$f" | grep -vE '^FROM (--platform=[^ ]+ )?mirror\.gcr\.io/')
  [[ -z "$bad" ]] && pass "6. ${f##*/}: every FROM reads mirror.gcr.io" || fail "6. ${f##*/}: $bad"
done

# 7
: >"$T/log"; env PATH="$T/stub:$PATH" FAKE_LOG="$T/log" FAKE_IMG="$T/img" docker pull -q x:1
grep -qx 'docker pull -q x:1' "$T/log" && pass "7. CONTROL: the stub records a pull" || fail "7. CONTROL: stub log empty"

echo "=== $([[ $fails -eq 0 ]] && echo 'all docker-pull-mirror.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
