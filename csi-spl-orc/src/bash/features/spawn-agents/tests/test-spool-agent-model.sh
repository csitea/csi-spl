#!/usr/bin/env bash
# Spec 184 row L1: spool_agent_model (7.1.2) and spool_model_args (7.1.3) of
# lib/spool-env.inc.sh, against a fixture cnf of contract 7.1.1 (never the
# real one). Cases: the resolution order step by step, empty in -> nothing
# out, a model with a quote or a space refused (exit 3), an unknown vendor
# (exit 2), and the words per vendor.
# Red control: swap steps 3 and 4 in spool_agent_model -> case 4 fails.
# Usage: bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-agent-model.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.inc.sh
. "$HERE/lib.inc.sh"
# shellcheck source=../lib/spool-env.inc.sh
. "$T_FEAT/lib/spool-env.inc.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
unset SPAWN_MODEL SPAWN_MODEL_MAP SPAWN_TASK_KIND

cat >"$T/full.yaml" <<'EOF'
env:
  box:
    agent_model:
      default: { claude: "opus", agy: "", grok: "grok-4.7", mistral: "mistral-large", qwen: "", codex: "" }
      by_kind:
        simple_coding: { claude: "sonnet", grok: "grok-4.6" }
        tests: { claude: "" }
EOF
cat >"$T/empty.yaml" <<'EOF'
env:
  box:
    agent_model:
      default: { claude: "", agy: "", grok: "", mistral: "", qwen: "", codex: "" }
      by_kind: {}
EOF
printf 'env:\n  box:\n    agent_split: {}\n' >"$T/nokey.yaml"
printf 'env:\n  box:\n    agent_model:\n      default: { claude: "a b" }\n' >"$T/space.yaml"
printf 'env:\n  box:\n    agent_model:\n      default: { claude: "x'"'"'y" }\n' >"$T/quote.yaml"

# run VAR CMD...: stdout into VAR, the exit code into RC
out=""; RC=0
run() { local _v="$1" _o; shift; _o="$("$@" 2>"$T/err")"; RC=$?; printf -v "$_v" '%s' "$_o"; }
export SPOOL_AGENT_MODEL_CNF="$T/full.yaml"

# 1. step 1: SPAWN_MODEL beats the map and both cnf steps
SPAWN_MODEL=haiku SPAWN_MODEL_MAP='claude:simple_coding=opus' run out spool_agent_model claude simple_coding
eq "1. SPAWN_MODEL wins over map and cnf" haiku "$out"
# 2. step 2: (vendor, kind) of the map beats (vendor, *) and the cnf
export SPAWN_MODEL_MAP='grok:*=grok-4.5,claude:*=fable,claude:simple_coding=claude-opus-5-5'
run out spool_agent_model claude simple_coding
eq "2a. map (vendor, kind) wins" claude-opus-5-5 "$out"
run out spool_agent_model claude tests
eq "2b. map (vendor, *) when no (vendor, kind)" fable "$out"
run out spool_agent_model grok simple_coding
eq "2c. map (vendor, *) beats the cnf cell" grok-4.5 "$out"
SPAWN_MODEL_MAP='SPAWN_MODEL_MAP=claude:simple_coding=sonnet' run out spool_agent_model claude simple_coding
eq "2d. the show line with its SPAWN_MODEL_MAP= prefix reads the same" sonnet "$out"
SPAWN_MODEL_MAP='claude:simple_coding=,claude:*=fable' run out spool_agent_model claude simple_coding
eq "2e. an empty map cell falls through to (vendor, *)" fable "$out"
SPAWN_MODEL_MAP='xclaude:*=bad,claude:simple_codingx=bad' run out spool_agent_model claude simple_coding
eq "2f. a map entry of another vendor or kind is not matched" sonnet "$out"
unset SPAWN_MODEL_MAP
# 3. step 3: the cnf by_kind cell beats the vendor default
run out spool_agent_model claude simple_coding
eq "3a. cnf by_kind cell" sonnet "$out"
run out spool_agent_model grok SIMPLE_CODING
eq "3b. the task kind is read lower case" grok-4.6 "$out"
SPAWN_TASK_KIND=simple_coding run out spool_agent_model claude
eq "3c. TASK_KIND defaults to SPAWN_TASK_KIND" sonnet "$out"
# 4. step 4: the cnf vendor default when the kind has no cell (or an empty one)
run out spool_agent_model claude specs_and_docs
eq "4a. cnf default for a kind with no row" opus "$out"
run out spool_agent_model claude tests
eq "4b. cnf default for an empty by_kind cell" opus "$out"
run out spool_agent_model mistral simple_coding
eq "4c. cnf default for a vendor with no cell in the kind" mistral-large "$out"
run out spool_agent_model claude
eq "4d. no task kind: the vendor default" opus "$out"
# 5. step 5: empty in, nothing out
run out spool_agent_model agy simple_coding
eq "5a. empty default: nothing" "" "$out"; eq "5a. exit 0" 0 "$RC"
SPOOL_AGENT_MODEL_CNF="$T/empty.yaml" run out spool_agent_model claude simple_coding
eq "5b. the shipped-empty block: nothing" "" "$out"; eq "5b. exit 0" 0 "$RC"
SPOOL_AGENT_MODEL_CNF="$T/nokey.yaml" run out spool_agent_model grok tests
eq "5c. no agent_model key (C1 not landed): nothing, exit 0" "0:" "$RC:$out"
SPOOL_AGENT_MODEL_CNF="$T/missing.yaml" run out spool_agent_model grok tests
eq "5d. no cnf file: nothing, exit 0" "0:" "$RC:$out"
# 6. refusals
SPOOL_AGENT_MODEL_CNF="$T/quote.yaml" run out spool_agent_model claude
eq "6a. a cnf model with a quote: exit 3, nothing printed" "3:" "$RC:$out"
has "6a. the refusal names the syntax" REFUSED "$(cat "$T/err")"
SPOOL_AGENT_MODEL_CNF="$T/space.yaml" run out spool_agent_model claude
eq "6b. a cnf model with a space: exit 3" "3:" "$RC:$out"
SPAWN_MODEL="so'nnet" run out spool_agent_model claude
eq "6c. SPAWN_MODEL with a quote: exit 3" "3:" "$RC:$out"
SPAWN_MODEL="$(printf 'a%.0s' {1..81})" run out spool_agent_model claude
eq "6d. an 81-char model: exit 3" "3:" "$RC:$out"
SPAWN_MODEL="$(printf 'a%.0s' {1..80})" run out spool_agent_model claude
eq "6e. an 80-char model passes" "0:80" "$RC:${#out}"
SPAWN_MODEL='models/gemini-3:latest_v1.2' run out spool_agent_model claude
eq "6f. every allowed char class passes" "models/gemini-3:latest_v1.2" "$out"
run out spool_agent_model gpt simple_coding
eq "6g. unknown vendor: exit 2" "2:" "$RC:$out"
run out spool_agent_model ""
eq "6h. no vendor: exit 2" "2:" "$RC:$out"
# 7. spool_model_args: the words per vendor (7.1.3)
run out spool_model_args claude sonnet
eq "7a. claude" "--model 'sonnet'" "$out"
run out spool_model_args grok grok-4.6
eq "7b. grok, the long form" "--model 'grok-4.6'" "$out"
run out spool_model_args mistral mistral-large
eq "7c. mistral, the env assignment" "VIBE_ACTIVE_MODEL='mistral-large'" "$out"
for v in agy qwen codex; do
  run out spool_model_args "$v" some-model
  eq "7d. $v (UNVERIFIED until M0): nothing, exit 0" "0:" "$RC:$out"
done
for v in $SPOOL_SPAWN_KINDS; do
  run out spool_model_args "$v" ""
  eq "7e. $v, empty model: nothing, exit 0" "0:" "$RC:$out"
done
run out spool_model_args claude "x'y"
eq "7f. a model with a quote: exit 3, no words" "3:" "$RC:$out"
run out spool_model_args claude 'a b'
eq "7g. a model with a space: exit 3" "3:" "$RC:$out"
run out spool_model_args gpt x
eq "7h. unknown vendor: exit 2" "2:" "$RC:$out"

t_done
