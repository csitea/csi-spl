#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_setup_box_sysstat and do_report_box_sar on a fake /etc and fake
# apt-get / dpkg-query / systemctl / sadf.
#   1. setup: the dry run plans all five steps and calls nothing; DRY_RUN=0
#      installs, sets ENABLED="true" and HISTORY=28 (every other line kept),
#      writes the 10-min timer drop-in and enables + starts the four units; a
#      second run is all OK and calls nothing; bad DRY_RUN / HISTORY refused
#   2. report: per-hour n, avg and peak of cpu% (100 - %idle), load1 and
#      mem% from the sa files, samples outside SINCE and LINUX-RESTART
#      records dropped; bad SINCE and an empty window refused
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
export TZ=UTC

E="$T/etc" U="$T/units" CL="$T/calls.log"
mkdir -p "$T/stub" "$U"
# dpkg-query: installed once apt-get ran. apt-get: lays down the packaged
# files (ENABLED="false", HISTORY=7), as the Debian 13 package does.
cat >"$T/stub/dpkg-query" <<EOF
#!/bin/sh
[ -f "$T/installed" ] && printf 'install ok installed'
EOF
cat >"$T/stub/apt-get" <<EOF
#!/bin/sh
echo "apt-get \$*" >>"$CL"
mkdir -p "$E/default" "$E/sysstat"
printf '# Should sadc collect\nENABLED="false"\n' >"$E/default/sysstat"
printf '# keep\nHISTORY=7\nCOMPRESSAFTER=10\n' >"$E/sysstat/sysstat"
touch "$T/installed"
EOF
cat >"$T/stub/systemctl" <<EOF
#!/bin/sh
case "\$1" in
  is-enabled) [ -f "$U/\$2" ] && echo enabled || echo disabled ;;
  is-active) [ -f "$U/\$2" ] && echo active || echo inactive ;;
  enable) echo "systemctl \$*" >>"$CL"; touch "$U/\$3" ;;
  *) echo "systemctl \$*" >>"$CL" ;;
esac
EOF
chmod +x "$T/stub/"*
setup() { SNIPPET='do_setup_box_sysstat' in_orc SYSSTAT_ETC="$E" SYSSTAT_SUDO= "$@" 2>&1; }

out="$(setup)"; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^PLAN ' <<<"$out")" = 8 ] && [ ! -s "$CL" ] && [ ! -e "$E" ] \
  && pass "1. the dry run (default) plans install, 2 keys, the timer, 4 units and calls nothing" || fail "1. dry run (rc $rc: $out)"
out="$(setup DRY_RUN=2)"; rc=$?
[ "$rc" = 1 ] && grep -q 'DRY_RUN must be 0 or 1' <<<"$out" && pass "1. DRY_RUN is checked" || fail "1. DRY_RUN=2 ($out)"
out="$(setup SYSSTAT_HISTORY=x)"; rc=$?
[ "$rc" = 1 ] && grep -q 'SYSSTAT_HISTORY must be' <<<"$out" && pass "1. SYSSTAT_HISTORY is checked" || fail "1. HISTORY=x ($out)"

out="$(setup DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && grep -q '^apt-get install -y -qq sysstat$' "$CL" && pass "1. DRY_RUN=0 installs sysstat" || fail "1. install (rc $rc: $out)"
[ "$(cat "$E/default/sysstat")" = "$(printf '# Should sadc collect\nENABLED="true"')" ] \
  && pass "1. ENABLED=\"true\", the comment kept" || fail "1. default file: $(cat "$E/default/sysstat")"
[ "$(cat "$E/sysstat/sysstat")" = "$(printf '# keep\nHISTORY=28\nCOMPRESSAFTER=10')" ] \
  && pass "1. HISTORY=28 in place, every other line kept" || fail "1. sysstat conf: $(cat "$E/sysstat/sysstat")"
D="$E/systemd/system/sysstat-collect.timer.d/csi-spl.conf"
grep -qx 'OnCalendar=' "$D" && grep -qx 'OnCalendar=\*:00/10' "$D" && grep -q '^systemctl daemon-reload$' "$CL" \
  && pass "1. the drop-in resets and pins OnCalendar=*:00/10, daemon-reload" || fail "1. drop-in ($(cat "$D" 2>&1))"
for u in sysstat.service sysstat-collect.timer sysstat-summary.timer sysstat-rotate.timer; do
  grep -qx "systemctl enable --now $u" "$CL" || fail "1. not enabled: $u"
done
[ "$(grep -c 'enable --now' "$CL")" = 4 ] && pass "1. the four units are enabled --now" || fail "1. enables: $(cat "$CL")"

: >"$CL"; cp -r "$E" "$T/etc.1"
out="$(setup DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && [ ! -s "$CL" ] && [ "$(grep -c '^OK ' <<<"$out")" = 9 ] && ! grep -q '^DO ' <<<"$out" \
  && diff -r "$E" "$T/etc.1" >/dev/null && pass "1. a second run is all OK and changes nothing" || fail "1. second run (rc $rc: $out; $(cat "$CL"))"

# --- 2. the report --------------------------------------------------------
S="$T/sa"; mkdir -p "$S"
now=$(date -d '2026-10-04 12:30:00' +%s)
h10=$(date -d '2026-10-04 10:00:00' +%s) h11=$(date -d '2026-10-04 11:00:00' +%s) old=$(date -d '2026-10-03 09:00:00' +%s)
: >"$S/sa04"; : >"$S/sa03"
cat >"$T/stub/sadf" <<EOF
#!/bin/sh
case "\$5" in */sa04) ;; *) exit 0 ;; esac
case "\$4" in
  -u) echo '# hostname;interval;timestamp;CPU;%user;%nice;%system;%iowait;%steal;%idle'
      echo "box;600;$h10;-1;5;0;5;0;0;90"; echo "box;600;$((h10 + 600));-1;25;0;5;0;0;70"
      echo "box;600;$h11;-1;1;0;1;0;0;98"; echo "box;600;$old;-1;99;0;0;0;0;1" ;;
  -q) echo "box;-1;$((h10 + 1));LINUX-RESTART	(16 CPU)"
      echo '# hostname;interval;timestamp;runq-sz;plist-sz;ldavg-1;ldavg-5;ldavg-15;blocked'
      echo "box;600;$h10;1;300;1.00;1;1;0"; echo "box;600;$((h10 + 600));1;300;3.00;1;1;0"
      echo "box;600;$h11;1;300;0.50;1;1;0" ;;
  -r) echo '# hostname;interval;timestamp;kbmemfree;kbavail;kbmemused;%memused;kbbuffers'
      echo "box;600;$h10;1;1;1;40.00;1"; echo "box;600;$((h10 + 600));1;1;1;60.00;1"
      echo "box;600;$h11;1;1;1;50.00;1" ;;
esac
EOF
chmod +x "$T/stub/sadf"
rep() { SNIPPET='do_report_box_sar' in_orc SAR_DIR="$S" SAR_NOW="$now" "$@" 2>&1; }
out="$(rep SINCE=3h)"; rc=$?
[ "$rc" = 0 ] && grep -qE '^2026-10-04 10:00 +2 +20\.0 +30\.0 +2\.0 +3\.0 +50\.0 +60\.0$' <<<"$out" \
  && pass "2. hour 10: n=2, cpu 20/30, load 2/3, mem 50/60" || fail "2. hour 10 (rc $rc: $out)"
grep -qE '^2026-10-04 11:00 +1 +2\.0 +2\.0 +0\.5 +0\.5 +50\.0 +50\.0$' <<<"$out" && pass "2. hour 11: one sample" || fail "2. hour 11 ($out)"
! grep -q '2026-10-03' <<<"$out" && [ "$(grep -c '^2026-' <<<"$out")" = 2 ] && pass "2. a sample before SINCE and a restart record are dropped" || fail "2. window ($out)"
out="$(rep SINCE=20x)"; rc=$?
[ "$rc" = 1 ] && grep -q 'SINCE must be' <<<"$out" && pass "2. a bad SINCE is refused" || fail "2. SINCE=20x ($out)"
out="$(rep SINCE=3h SAR_NOW=$((now + 86400 * 3)))"; rc=$?
[ "$rc" = 1 ] && grep -q 'FATAL no s' <<<"$out" && pass "2. an empty window exits 1" || fail "2. empty window (rc $rc: $out)"

echo "box-sysstat: ${fails} failure(s)"
[ "$fails" -eq 0 ]
