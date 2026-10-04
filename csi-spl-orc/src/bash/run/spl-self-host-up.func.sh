#!/bin/bash
#------------------------------------------------------------------------------
# @description Bring up the standalone stack (the root docker-compose.yml) on
# @description your own domain in one command (spec 072 A2, "spool-up"):
# @description   1. asks ~5 questions - domain, owner email, SMTP host / port /
# @description      user / password. Each is also an env var named as its .env
# @description      key, so a re-run or a script needs no prompt; an existing
# @description      .env answers the rest (a safe re-run)
# @description   2. preflight, all of it before `up`: Docker + compose, the DNS
# @description      A record of the domain, ports 80/443 free, the SMTP login.
# @description      Each failure prints its fix on one line; any failure stops
# @description      here and nothing is started or written
# @description   3. writes .env (mode 600): the own-domain profile of
# @description      .env.example plus three generated Postgres passwords; a
# @description      re-run KEEPS the passwords already there (Postgres took them
# @description      on its first boot and never takes new ones)
# @description   4. `docker compose up -d --wait`, then prints the owner link
# @description Nothing reaches a hosted service but your own DNS and SMTP relay.
# @param SPOOL_DOMAIN - the domain the stack answers on (its A record points here)
# @param SPOOL_OWNER_EMAIL - the one address that becomes the tenant owner
# @param SPOOL_MAIL_SMTP_HOST - the SMTP relay for confirmation mail
# @param SPOOL_MAIL_SMTP_PORT (optional) - default 587 (STARTTLS); 465 = TLS
# @param SPOOL_MAIL_SMTP_USER - the SMTP login
# @param SPOOL_MAIL_SMTP_PASSWORD - the SMTP password (prompted without echo)
# @param SPOOL_MAIL_FROM (optional) - default spool@<SPOOL_DOMAIN>
# @param SPOOL_PUBLIC_IP (optional) - this machine's public address when it sits behind NAT (default: its own addresses, hostname -I)
# @param SPOOL_SELF_HOST_DIR (optional) - the dir holding docker-compose.yml and .env (default: this checkout)
# @example SPOOL_DOMAIN=<<run-time>>.csitea.net SPOOL_OWNER_EMAIL=you@example.com ./run -a do_spl_self_host_up
#------------------------------------------------------------------------------

# the questions: .env key | prompt | default ('' = required)
SPL_SELF_HOST_ASK=(
  "SPOOL_DOMAIN|the domain this stack answers on (its DNS A record points here), e.g. chat.example.com|"
  "SPOOL_OWNER_EMAIL|the owner's email (the one address that becomes the tenant owner)|"
  "SPOOL_MAIL_SMTP_HOST|the SMTP relay host for confirmation mail|"
  "SPOOL_MAIL_SMTP_PORT|the SMTP port (587 = STARTTLS, 465 = TLS)|587"
  "SPOOL_MAIL_SMTP_USER|the SMTP login|"
  "SPOOL_MAIL_SMTP_PASSWORD|the SMTP password|"
)
# generated once, kept on every re-run
SPL_SELF_HOST_SECRETS=(SPOOL_DB_OWNER_PASSWORD SPOOL_DB_RUNTIME_PASSWORD SPOOL_DB_SUPERUSER_PASSWORD)

# spl_self_host_env_get <file> <key> - the value of KEY=... in a dotenv file
# (quotes stripped), empty when absent. Never sources the file.
spl_self_host_env_get() {
  [[ -f "$1" ]] || return 0
  local line v
  line="$(grep -E "^$2=" "$1" | tail -n 1)" || return 0
  v="${line#*=}"
  if [[ ${#v} -ge 2 && ( "$v" == \'*\' || "$v" == \"*\" ) ]]; then v="${v:1:${#v}-2}"; fi
  printf '%s' "$v"
}

# spl_self_host_smtp_login <host> <port> - connect, TLS, AUTH, quit; no mail
# sent. The user and password come in the env (SMTP_USER / SMTP_PASSWORD),
# never argv. 127 = no python3.
spl_self_host_smtp_login() {
  command -v python3 >/dev/null 2>&1 || return 127
  SMTP_HOST="$1" SMTP_PORT="$2" python3 - <<'PY'
import os, smtplib, ssl, sys
h, p = os.environ["SMTP_HOST"], int(os.environ["SMTP_PORT"])
try:
    ctx = ssl.create_default_context()
    if p == 465:
        s = smtplib.SMTP_SSL(h, p, timeout=15, context=ctx)
    else:
        s = smtplib.SMTP(h, p, timeout=15)
        s.ehlo(); s.starttls(context=ctx); s.ehlo()
    s.login(os.environ["SMTP_USER"], os.environ["SMTP_PASSWORD"])
    s.quit()
except Exception as e:
    print(f"{type(e).__name__}: {e}", file=sys.stderr); sys.exit(1)
PY
}

# spl_self_host_port_busy <port> - 0 when something listens on it here
spl_self_host_port_busy() {
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}

do_spl_self_host_up() {
  local dir="${SPOOL_SELF_HOST_DIR:-${APP_PATH:-}}"
  [[ -n "$dir" && -f "$dir/docker-compose.yml" ]] ||
    { do_log "FATAL no docker-compose.yml in '$dir': run this from the spool checkout, or set SPOOL_SELF_HOST_DIR"; return 1; }
  local envf="$dir/.env"

  # --- 1. the answers: env var > existing .env > prompt > default -----------
  local row key prompt def val
  local -A ans=()
  for row in "${SPL_SELF_HOST_ASK[@]}"; do
    IFS='|' read -r key prompt def <<<"$row"
    val="${!key:-}"
    [[ -n "$val" ]] || val="$(spl_self_host_env_get "$envf" "$key")"
    if [[ -z "$val" && -t 0 ]]; then
      if [[ "$key" == *PASSWORD ]]; then
        read -r -s -p "$prompt: " val; echo >&2
      else
        read -r -p "$prompt${def:+ [$def]}: " val
      fi
    fi
    [[ -n "$val" ]] || val="$def"
    [[ -n "$val" ]] || { do_log "FATAL $key is unanswered and there is no terminal to ask on: set $key=<value>"; return 1; }
    [[ "$val" != *"'"* && "$val" != *$'\n'* ]] ||
      { do_log "FATAL $key holds a single quote or a newline, which .env cannot carry literally: choose another value"; return 1; }
    ans[$key]="$val"
  done
  local domain="${ans[SPOOL_DOMAIN]}" email="${ans[SPOOL_OWNER_EMAIL]}"
  local smtp_host="${ans[SPOOL_MAIL_SMTP_HOST]}" smtp_port="${ans[SPOOL_MAIL_SMTP_PORT]}" smtp_user="${ans[SPOOL_MAIL_SMTP_USER]}"
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] ||
    { do_log "FATAL SPOOL_DOMAIN '$domain' is not a bare domain: give the host name only, e.g. chat.example.com (no scheme, port or path)"; return 1; }
  [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] ||
    { do_log "FATAL SPOOL_OWNER_EMAIL '$email' is not an email address"; return 1; }
  [[ "$smtp_port" =~ ^[0-9]{1,5}$ ]] ||
    { do_log "FATAL SPOOL_MAIL_SMTP_PORT '$smtp_port' is not a port number"; return 1; }
  local from="${SPOOL_MAIL_FROM:-$(spl_self_host_env_get "$envf" SPOOL_MAIL_FROM)}"
  from="${from:-spool@$domain}"

  # --- 2. preflight: every check, then stop before `up` on any failure ------
  local fails=0
  _shu_fail() { do_log "PREFLIGHT FAIL $1"; do_log "  fix: $2"; fails=$((fails + 1)); }
  _shu_ok() { do_log "PREFLIGHT ok   $1"; }

  local docker_ok=0
  if ! command -v docker >/dev/null 2>&1; then
    _shu_fail "docker is not installed" "install Docker Engine with its compose plugin (docs.docker.com/engine/install), then re-run"
  elif ! docker compose version >/dev/null 2>&1; then
    _shu_fail "docker has no compose plugin" "install the docker-compose-plugin package (Compose v2), then re-run"
  elif ! docker info >/dev/null 2>&1; then
    _shu_fail "the docker daemon does not answer" "start it (sudo systemctl start docker), or add $USER to the docker group and log in again"
  else
    docker_ok=1; _shu_ok "docker + compose"
  fi

  local want="${SPOOL_PUBLIC_IP:-}" got ip hit=0
  [[ -n "$want" ]] || want="$(hostname -I 2>/dev/null)"
  if ! command -v dig >/dev/null 2>&1; then
    _shu_fail "dig is missing, so the A record cannot be checked" "install it (sudo apt-get install -y dnsutils), then re-run"
  else
    got="$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | tr '\n' ' ')"
    got="${got% }"
    for ip in $got; do [[ " $want " == *" $ip "* ]] && hit=1; done
    if [[ -z "$got" ]]; then
      _shu_fail "$domain has no DNS A record" "add an A record for $domain pointing at this machine (${want:-its public address}), wait until it resolves, re-run"
    elif (( ! hit )); then
      _shu_fail "the A record of $domain is $got, not this machine (${want:-unknown})" "point the A record of $domain at this machine, or set SPOOL_PUBLIC_IP=<its public address> when it sits behind NAT"
    else
      _shu_ok "the A record of $domain is this machine ($got)"
    fi
  fi

  # on a re-run the running web container holds 80/443 itself
  local ours=0 p
  if (( docker_ok )) && docker compose --project-directory "$dir" ps --status running --services 2>/dev/null | grep -x web >/dev/null; then ours=1; fi
  for p in 80 443; do
    if (( ours )); then
      _shu_ok "port $p (held by this stack's web container)"
    elif spl_self_host_port_busy "$p"; then
      _shu_fail "port $p is in use" "stop what listens on it (sudo ss -ltnp 'sport = :$p' names it), then re-run"
    else
      _shu_ok "port $p free"
    fi
  done

  local src=0
  SMTP_USER="$smtp_user" SMTP_PASSWORD="${ans[SPOOL_MAIL_SMTP_PASSWORD]}" \
    spl_self_host_smtp_login "$smtp_host" "$smtp_port" >/dev/null 2>&1 || src=$?
  if (( src == 127 )); then
    _shu_fail "python3 is missing, so the SMTP login cannot be checked" "install it (sudo apt-get install -y python3), then re-run"
  elif (( src )); then
    _shu_fail "the SMTP login to $smtp_host:$smtp_port as $smtp_user failed" "check the host, port, user and password with your mail provider and that outbound port $smtp_port is open, then re-run"
  else
    _shu_ok "SMTP login to $smtp_host:$smtp_port as $smtp_user"
  fi

  if (( fails )); then
    do_log "FATAL $fails preflight check(s) failed: nothing was written or started. Fix each line above and re-run"
    return 1
  fi

  # --- 3. .env, mode 600, existing secrets kept -----------------------------
  local k sec
  local -A put=(
    [SPOOL_PUBLIC_URL]="https://$domain" [SPOOL_SITE_ADDRESS]="$domain" [SPOOL_DOMAIN]="$domain"
    [SPOOL_BIND]=0.0.0.0 [SPOOL_HTTP_PORT]=80 [SPOOL_HTTPS_PORT]=443
    [SPOOL_HUB_ENV]=prd [SPOOL_LOG_FORMAT]=json [SPOOL_AUTH_DEBUG_LINKS]=false [SPOOL_COOKIE_SECURE]=true
    [SPOOL_MAIL_TRANSPORT]=smtp [SPOOL_MAIL_PREFLIGHT]=require [SPOOL_MAIL_FROM]="$from"
    [SPOOL_OWNER_EMAIL]="$email" [SPOOL_MAIL_SMTP_HOST]="$smtp_host" [SPOOL_MAIL_SMTP_PORT]="$smtp_port"
    [SPOOL_MAIL_SMTP_USER]="$smtp_user" [SPOOL_MAIL_SMTP_PASSWORD]="${ans[SPOOL_MAIL_SMTP_PASSWORD]}"
  )
  for k in "${SPL_SELF_HOST_SECRETS[@]}"; do
    sec="$(spl_self_host_env_get "$envf" "$k")"
    if [[ -z "$sec" || "$sec" == spool-local-* || "$sec" == "<"* ]]; then
      sec="$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')"
      [[ ${#sec} -eq 48 ]] || { do_log "FATAL could not generate $k"; return 1; }
      do_log "INFO $k generated (value not logged)"
    else
      do_log "INFO $k kept from the existing .env"
    fi
    put[$k]="$sec"
  done

  local tmp="$envf.tmp.$$" line
  if ! (
    umask 077
    {
      echo "# written by ./run -a do_spl_self_host_up (spec 072 A2); never commit it."
      echo "# A re-run keeps the three Postgres passwords: Postgres took them on its first boot."
      for k in $(printf '%s\n' "${!put[@]}" | sort); do printf "%s='%s'\n" "$k" "${put[$k]}"; done
      if [[ -f "$envf" ]] && grep -qE '^[A-Za-z_][A-Za-z0-9_]*=' "$envf"; then
        echo "# kept from the previous .env"
        grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$envf" | while IFS= read -r line; do
          [[ -n "${put[${line%%=*}]+x}" ]] || printf '%s\n' "$line"
        done
      fi
    } >"$tmp"
  ) || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$envf"; then
    rm -f "$tmp"; do_log "FATAL cannot write $envf"; return 1
  fi
  do_log "INFO wrote $envf (mode 600)"

  # --- 4. up, then the owner link -------------------------------------------
  do_log "INFO docker compose up -d --wait (pulls the images; a failed pull builds them)"
  docker compose --project-directory "$dir" up -d --wait ||
    { do_log "FATAL docker compose up failed: 'docker compose --project-directory $dir logs hub-init hub web' names the problem"; return 1; }
  local tenant
  tenant="$(spl_self_host_env_get "$envf" SPOOL_TENANT)"
  do_log "INFO the stack is up on https://$domain"
  echo "OWNER LINK: https://$domain/login?tenant=${tenant:-main} - sign up there with $email (only that confirmed address becomes the owner)"
}
