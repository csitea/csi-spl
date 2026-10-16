#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the system-change half of the shared pre-tool matcher
# (features/spawn-agents/lib/force-push-guard.inc.sh), SPL-2187: a doc seat
# apt-installed systemd-resolved as root and took a box off DNS for 22 min.
#   1. a package, service or /etc change is refused: rc 2, one
#      "force-push-guard: refused: system change: ..." line on stderr - the
#      incident's own commands, every wrapper (sudo, sudo -u <owner> bash -c,
#      env, xargs, ssh, $( ), &&), redirections and tee into /etc
#   2. the read-only and legitimate forms pass: rc 0, nothing on stderr -
#      apt list / -s, dpkg -l, systemctl status / --user, sudo -u <owner> git
#      status, a copy OUT of /etc, a commit message or grep that only names
#      apt-get, apt-get inside a container
#   3. the vibe hook's reason does not call a system change a force push
# Control: the matcher with system() made a no-op allows every case in 1.
#------------------------------------------------------------------------------
# shellcheck disable=SC2016,SC1091  # the cases are literal commands, never expanded
set -uo pipefail
LIB="$(cd "$(dirname "$0")/../features/spawn-agents/lib" && pwd)"
G="$LIB/force-push-guard.inc.sh"
VIBE="$(cd "$(dirname "$0")/../features/spool-install/assets/vibe-push-guard" && pwd)/vibe-push-guard.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }

REFUSE=(
  'apt-get update'
  'sudo apt-get install -y manpages manpages-dev network-manager'
  'sudo apt-get install -y systemd-resolved'
  'sudo DEBIAN_FRONTEND=noninteractive apt-get -y install libnss-resolve'
  'apt install jq'
  'sudo apt purge systemd-resolved'
  'aptitude upgrade'
  'sudo apt-get -o Dpkg::Options::=--force-confnew dist-upgrade'
  'sudo dpkg -i ./x.deb'
  'dpkg --purge libnss-resolve'
  'sudo dpkg --configure -a'
  'sudo apt-mark hold sudo'
  'sudo snap install yq'
  'sudo add-apt-repository ppa:x/y'
  'sudo dpkg-reconfigure tzdata'
  'sudo systemctl stop systemd-resolved'
  'sudo systemctl --no-pager restart docker'
  'systemctl enable --now x.service'
  'sudo systemctl daemon-reload'
  'sudo systemctl mask x'
  'sudo service cron restart'
  'sudo /etc/init.d/ssh reload'
  'sudo resolvectl dns eth0 1.1.1.1'
  'sudo hostnamectl set-hostname x'
  'sudo timedatectl set-timezone UTC'
  'sudo reboot'
  'echo nameserver 1.1.1.1 | sudo tee /etc/resolv.conf'
  'echo x | sudo tee -a /etc/hosts >/dev/null'
  'echo x > /etc/hosts'
  'cat >>/etc/sudoers.d/x <<EOF
x ALL=(ALL) NOPASSWD:ALL
EOF'
  'sudo cp ./resolv.conf /etc/resolv.conf'
  'sudo cp -t /etc/sudoers.d ./x'
  'sudo install -m 0440 x /etc/sudoers.d/x'
  'sudo install -d /etc/x'
  'sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf'
  'sudo rm -f /etc/resolv.conf'
  'sudo chmod 777 /etc/sudoers.d'
  'sudo mkdir -p /etc/x'
  'sudo sed -i s/a/b/ /etc/nsswitch.conf'
  'sudo perl -pi -e s/a/b/ /etc/nsswitch.conf'
  'sudo dd if=x of=/etc/x'
  'sudo -u owner bash -c "sudo apt-get install -y x"'
  'sudo -n -u box-owner sh -c "sudo systemctl stop docker"'
  'env A=1 sudo apt-get remove x'
  'echo x | xargs sudo apt-get install -y'
  'cd /tmp && sudo apt-get install -y x'
  'true; sudo systemctl restart cron'
  'echo $(sudo apt-get install -y x)'
  'ssh box sudo apt-get install -y x'
  'timeout 60 sudo apt-get update'
)
ALLOW=(
  'apt list --installed'
  'apt-cache policy systemd-resolved'
  'apt show jq'
  'apt-get -s install jq'
  'apt-get install --simulate jq'
  'dpkg -l'
  'dpkg -L systemd-resolved'
  'dpkg -s sudo'
  'dpkg --get-selections'
  'dpkg-query -W -f=x sudo'
  'systemctl status systemd-resolved'
  'systemctl --no-pager -l status docker'
  'systemctl is-active cron'
  'systemctl list-units --type=service'
  'systemctl'
  'systemctl --user restart spool-desk.service'
  'systemctl --user daemon-reload'
  'service --status-all'
  'service cron status'
  'resolvectl status'
  'resolvectl dns'
  'resolvectl query example.com'
  'hostnamectl'
  'timedatectl status'
  'journalctl -u systemd-resolved --since today --no-pager'
  'cat /etc/resolv.conf'
  'grep -r nameserver /etc/'
  'cp /etc/hosts /tmp/hosts.copy'
  'ls -la /etc/sudoers.d'
  'sudo -u owner git status'
  'sudo -u owner bash -c "cd /opt/x && git add a && git commit -m y"'
  'sudo -u owner tee -a /var/spool-hub/x/lifetime/state.md'
  'sudo -n true'
  'sudo -n find /proc -mindepth 2 -maxdepth 2 -path "/proc/[0-9]*/cwd" -printf "%l\n"'
  'git commit -m "fix: refuse sudo apt-get install and systemctl stop"'
  'grep -n "apt-get install" README.md'
  'echo "sudo systemctl restart x" >/tmp/note'
  'docker run --rm debian:12 apt-get install -y jq'
  'sed -n 1,5p /etc/hosts'
  'sed -i s/a/b/ /tmp/x'
  'perl -Mstrict -e 1 /etc/hosts'
  'echo x 2>&1 >/tmp/y'
  'mkdir -p /tmp/etc/x'
  'git push origin HEAD:master'
)

check() {  # <lib> <command> -> "rc|stderr"
  local err rc
  err="$(bash "$1" --check "$2" 2>&1 >/dev/null)"; rc=$?
  printf '%s|%s' "$rc" "$err"
}

# 1. refused
for c in "${REFUSE[@]}"; do
  r="$(check "$G" "$c")"; rc="${r%%|*}"; err="${r#*|}"
  if [ "$rc" = 2 ] && [ "$(printf '%s\n' "$err" | wc -l)" = 1 ] &&
     [[ "$err" == "force-push-guard: refused: system change: "* ]] && [[ "$err" == *SPL-2187* ]]
  then pass "refused: $c"; else fail "should refuse (rc=$rc err=$err): $c"; fi
done

# 2. allowed
for c in "${ALLOW[@]}"; do
  r="$(check "$G" "$c")"; rc="${r%%|*}"; err="${r#*|}"
  if [ "$rc" = 0 ] && [ -z "$err" ]; then pass "allowed: $c"; else fail "should allow (rc=$rc err=$err): $c"; fi
done

# 3. the vibe hook says "system change", not "force push", for one
if command -v python3 >/dev/null 2>&1 && [ -r "$VIBE" ]; then
  cp "$VIBE" "$G" "$T/"
  out="$(printf '{"tool_name":"bash","tool_input":{"command":"sudo apt-get install -y x"}}' |
    python3 "$T/vibe-push-guard.py")"; rc=$?
  if [ "$rc" = 0 ] && [[ "$out" == *'"decision": "deny"'* ]] && [[ "$out" == *"system change"* ]] &&
     [[ "$out" != *"no force push"* ]]; then pass "vibe hook: a system change is denied as one"
  else fail "vibe hook on a system change (rc=$rc): $out"; fi
  out="$(printf '{"tool_name":"bash","tool_input":{"command":"git push -f origin master"}}' |
    python3 "$T/vibe-push-guard.py")"
  [[ "$out" == *"no force push"* ]] && pass "vibe hook: a force push keeps its owner-order reason" ||
    fail "vibe hook on a force push: $out"
else
  fail "vibe hook not testable (python3 or $VIBE missing)"
fi

# Control: system() made a no-op -> every case in 1 must pass the matcher
sed 's/^def system(t, b, args):$/def system(t, b, args):\n    return/' "$G" >"$T/nosys.inc.sh"
if grep -q '^    return$' "$T/nosys.inc.sh"; then
  leaked=0
  for c in "${REFUSE[@]}"; do
    r="$(check "$T/nosys.inc.sh" "$c")"
    [ "${r%%|*}" = 0 ] && leaked=$((leaked + 1))
  done
  # the redirections into /etc are refused by split(), not system(): 3 of them
  [ "$leaked" -ge $((${#REFUSE[@]} - 3)) ] && pass "control: without system() $leaked/${#REFUSE[@]} refused cases pass (the guard is what refuses them)" ||
    fail "control: without system() only $leaked/${#REFUSE[@]} cases pass"
else
  fail "control: could not neutralise system()"
fi

echo "system-change-guard: $((n - fails))/$n passed"
[ "$fails" = 0 ]
