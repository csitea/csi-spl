#!/usr/bin/env bash
# test-classify-screen.sh — classify_screen reads a FINISHED claude turn as
# idle: the past-tense line "✻ Crunched for 4s · done 12.34" left after a turn
# shares a stem with the live spinner "✻ Crunching…" and read busy on every
# finished pane (CLE-77975, 2026-10-02). Live work still reads busy.
set -uo pipefail
. "$(dirname "$0")/lib.inc.sh"
t_sandbox
. "$T_FEAT/lib/agent-state.inc.sh"

prompt=$'\n────────\n❯ \n────────\n  ⏵⏵ auto mode on (shift+tab to cycle)'

# 1. a finished turn, in every past-tense spinner word seen on live panes
for w in Crunched Brewed Churned Cogitated Cooked Baked Sautéed Worked; do
  eq "1. finished '$w for 4s' -> idle" idle \
    "$(classify_screen "● Done.
✻ $w for 4s · done 12.34${prompt}")"
done
eq "1. finished with minutes and a background shell -> idle" idle \
  "$(classify_screen "✻ Churned for 8m 46s · done 13.15 · 1 shell still running${prompt}")"

# 2. a live spinner -> busy, with or without the footer
for w in Crunching Brewing Churning Cogitating Cooking Spinning Razzle-dazzling Ebbing Skedaddling; do
  eq "2. live '$w…' -> busy" busy "$(classify_screen "✻ $w…${prompt}")"
done
eq "2. live spinner with ASCII dots -> busy" busy "$(classify_screen "✻ Brewing...${prompt}")"
eq "2. live timer '(8s · ' -> busy" busy "$(classify_screen "✢ Grooving… (8s · ↓ 426 tokens)${prompt}")"
eq "2. live token counter -> busy" busy "$(classify_screen "✽ Levitating ↓ 2.8k tokens${prompt}")"

# 3. esc to interrupt -> busy, even under an old finished line
eq "3. esc to interrupt -> busy" busy \
  "$(classify_screen "✻ Crunched for 4s · done 12.34
  ⏵⏵ auto mode on · esc to interrupt")"

# 4. a dialog wins over everything
eq "4. dialog -> dialog" dialog \
  "$(classify_screen "Do you want to proceed?
❯ 1. Yes
  2. No")"

t_done
