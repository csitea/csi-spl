#!/bin/bash
#------------------------------------------------------------------------------
# @description Set the wine-box VNC password and prove the desktop takes it.
# @description The playbook (08_vnc) writes the password once and never again,
# @description so this is the one way to set a chosen one on a running box.
# @description 1. The password file: WINE_BOX_VNC_PASS_FILE, default
# @description    $HOME/.secrets/csi-spl/wine-box-vnc.<vm>.pass, mode 0600 in a
# @description    0700 dir. Absent (or WINE_BOX_VNC_ROTATE=1): generate 8
# @description    characters (VncAuth uses 8), upper + lower + digit, none
# @description    of 0 O 1 l I. Present: reuse it.
# @description 2. DRY_RUN=0: ssh (IAP tunnel, the dev project SA, --account)
# @description    as the admin user; the password goes on stdin only. The box
# @description    writes /root/wine-box-vnc.pass and ~<desktop_user>/.vnc/passwd
# @description    (vncpasswd -f), restarts wine-box-vnc, then runs a VncAuth
# @description    handshake on 127.0.0.1: the password must be accepted and a
# @description    wrong one refused.
# @description Never prints the password: SHA_LOCAL / SHA_BOX are the first 12
# @description hex of its sha256, and they must match.
# @param DRY_RUN (optional) - 1: generate the file, print the plan. Default 1.
# @param WINE_BOX_VNC_PASS_FILE (optional) - the local password file.
# @param WINE_BOX_VNC_ROTATE (optional) - 1: mint a new password. Default 0.
# @example ./run -a do_spl_wine_box_vnc_password
# @example DRY_RUN=0 ./run -a do_spl_wine_box_vnc_password
#------------------------------------------------------------------------------
do_spl_wine_box_vnc_password() {
  local proj zone vm user duser port pwbin key file sha proxy remote out rc
  proj=$(do_spl_wine_box_cnf gcp_project) || return 1
  zone=$(do_spl_wine_box_cnf gcp_zone) || return 1
  vm=$(do_spl_wine_box_cnf vm_name) || return 1
  user=$(do_spl_wine_box_cnf os_user) || return 1
  duser=$(do_spl_wine_box_cnf desktop_user) || return 1
  port=$(do_spl_wine_box_cnf vnc_port) || return 1
  pwbin=$(do_spl_wine_box_cnf vnc_passwd_bin) || return 1
  [[ "$duser" =~ ^[a-z_][a-z0-9_-]*$ && "$port" =~ ^59[0-9][0-9]$ && "$pwbin" =~ ^/[A-Za-z0-9/._-]+$ ]] \
    || { do_log "FATAL desktop_user, vnc_port or vnc_passwd_bin in the cnf is not a plain value"; return 1; }
  file="${WINE_BOX_VNC_PASS_FILE:-$HOME/.secrets/csi-spl/wine-box-vnc.${vm}.pass}"
  _wine_box_vnc_pass_file "$file" || return 1
  sha=$(sha256sum "$file" | cut -c1-12)
  do_log "INFO password file ${file} (0600) SHA_LOCAL=${sha}"
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    do_log "INFO DRY_RUN would set it on ${vm} (${proj}/${zone}) for ${duser}, restart wine-box-vnc, prove VncAuth on 127.0.0.1:${port}"
    return 0
  fi
  command -v gcloud >/dev/null 2>&1 || { do_log "FATAL gcloud is not installed"; return 1; }
  key=$(do_spl_wine_box_private_key) || return 1
  [[ -f "$key" ]] || { do_log "FATAL no admin key at ${key}: run this where the box was built"; return 1; }
  unset ACCOUNT GCP_ACCOUNT
  export PROJ_ID="$proj"
  do_gcp_pin_account || return 1
  proxy="gcloud compute start-iap-tunnel ${vm} 22 --listen-on-stdin --zone=${zone} --project=${proj} --account=${GCP_ACCOUNT} --verbosity=error"
  remote=$(_wine_box_vnc_remote_script)
  out=$(ssh -i "$key" -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ProxyCommand="$proxy" "${user}@${vm}" \
    "sudo env DUSER=${duser} PORT=${port} PWBIN=${pwbin} bash -c $(printf '%q' "$remote")" <"$file")
  rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || { do_log "FATAL setting the VNC password on ${vm} failed (rc ${rc})"; return 1; }
  grep -qx "SHA_BOX=${sha}" <<<"$out" || { do_log "FATAL SHA_BOX differs from SHA_LOCAL=${sha}"; return 1; }
  grep -qx 'VNC_AUTH_GOOD=accepted' <<<"$out" && grep -qx 'VNC_AUTH_WRONG=rejected' <<<"$out" \
    || { do_log "FATAL the desktop did not accept the password and refuse a wrong one"; return 1; }
  do_log "OK ${vm}: VNC password set, SHA_LOCAL=SHA_BOX=${sha}, VncAuth accepts it and refuses a wrong one"
}

#------------------------------------------------------------------------------
# @description Make sure $1 holds a password: reuse it, or mint one (absent,
# @description or WINE_BOX_VNC_ROTATE=1). The dir is 0700, the file 0600.
#------------------------------------------------------------------------------
_wine_box_vnc_pass_file() {
  local file=$1 dir pw
  dir=$(dirname "$file")
  (umask 077; mkdir -p "$dir") || { do_log "FATAL cannot create ${dir}"; return 1; }
  chmod 700 "$dir" || return 1
  if [[ -s "$file" && "${WINE_BOX_VNC_ROTATE:-0}" != 1 ]]; then
    chmod 600 "$file" || return 1
  else
    pw=$(python3 -c '
import secrets, string
abc = "".join(c for c in string.ascii_letters + string.digits if c not in "0O1lI")
while True:
    pw = "".join(secrets.choice(abc) for _ in range(8))
    if any(c.isupper() for c in pw) and any(c.islower() for c in pw) and any(c.isdigit() for c in pw):
        print(pw)
        break
') || { do_log "FATAL python3 could not generate a password"; return 1; }
    (umask 077; printf '%s\n' "$pw" >"${file}.new") && mv -f "${file}.new" "$file" \
      || { do_log "FATAL cannot write ${file}"; return 1; }
    unset pw
    do_log "INFO generated a new VNC password into ${file}"
  fi
  [[ "$(head -n1 "$file" | tr -d '\n' | wc -c)" == 8 ]] \
    || { do_log "FATAL ${file} does not hold an 8-character password"; return 1; }
}

#------------------------------------------------------------------------------
# @description The root script run on the box. Reads the password from stdin;
# @description DUSER, PORT, PWBIN come from env. Prints SHA_BOX and the two
# @description handshake verdicts, never the password.
#------------------------------------------------------------------------------
_wine_box_vnc_remote_script() {
  cat <<'REMOTE'
set -euo pipefail
IFS= read -r pw
[ "${#pw}" -eq 8 ] || { echo "VNC_SET=refused-length"; exit 2; }
umask 077
printf '%s\n' "$pw" >/root/wine-box-vnc.pass.new
mv -f /root/wine-box-vnc.pass.new /root/wine-box-vnc.pass
vdir="/home/${DUSER}/.vnc"
install -d -o "$DUSER" -g "$DUSER" -m 0700 "$vdir"
printf '%s\n' "$pw" | "$PWBIN" -f >"$vdir/passwd.new"
unset pw
chown "$DUSER:$DUSER" "$vdir/passwd.new"
chmod 600 "$vdir/passwd.new"
mv -f "$vdir/passwd.new" "$vdir/passwd"
echo "SHA_BOX=$(sha256sum /root/wine-box-vnc.pass | cut -c1-12)"
systemctl restart wine-box-vnc
for _ in $(seq 1 45); do
  ss -H -ltn | grep -q "127\.0\.0\.1:${PORT} " && break
  sleep 2
done
python3 - "$PORT" <<'PY'
import socket, subprocess, sys

port = int(sys.argv[1])
pw = open("/root/wine-box-vnc.pass", "rb").read().split(b"\n")[0]

def rev(b):
    return int("{:08b}".format(b)[::-1], 2)

def des(key, data):
    out = subprocess.run(
        ["openssl", "enc", "-des-ecb", "-nopad", "-K", key.hex(), "-provider", "legacy", "-provider", "default"],
        input=data, capture_output=True, check=True)
    return out.stdout

def recv(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise EOFError("closed")
        buf += chunk
    return buf

def vnc_auth(secret):
    with socket.create_connection(("127.0.0.1", port), timeout=15) as s:
        recv(s, 12)
        s.sendall(b"RFB 003.008\n")
        types = recv(s, recv(s, 1)[0])
        if 2 not in types:
            return "no-vncauth"
        s.sendall(b"\x02")
        challenge = recv(s, 16)
        key = bytes(rev(b) for b in (secret + b"\0" * 8)[:8])
        s.sendall(des(key, challenge))
        return "accepted" if recv(s, 4) == b"\0\0\0\0" else "rejected"

wrong = pw[:-1] + (b"x" if pw[-1:] != b"x" else b"y")
good = vnc_auth(pw)
bad = vnc_auth(wrong)
print("VNC_AUTH_GOOD=" + good)
print("VNC_AUTH_WRONG=" + bad)
sys.exit(0 if (good, bad) == ("accepted", "rejected") else 3)
PY
REMOTE
}
