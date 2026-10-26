# ./run logs and secrets

SPL-3614 (epic SPL-2402, spec 011). The `./run` framework
(`csi-spl-{iac,orc,utl}/src/bash/run/run.sh`, byte-identical) tees every
action's stdout and stderr into `~/var/log/<proj>/<unit>.<ts>.{out,err}.log`.
Those files are created under the caller's umask, mode 664 on the fleet
boxes: readable by the group.

## 1. What the log copy masks

The terminal, or whatever the caller redirected `./run` into, gets every
byte unchanged. Only the log copy passes through `do_mask_private_keys`,
which replaces with `<redacted>`:

- the value of a JSON field whose name ends in `private_key` or
  `privateKey` (`"root_private_key":"<v>"`, any case, spaces around `:`
  allowed, an escaped `\"` or `\\` inside `<v>` masked with it);
- a `<name>private_key=<v>` or `<name>privateKey=<v>` assignment, any case;
- a PEM `-----BEGIN ... PRIVATE KEY-----` block, on one line or many.

So `ENV=<env> DRY_RUN=0 TENANT_ID=<id> ./run -a do_spl_tenant_create`
still prints the tenant root private key once on stdout, and its run log
holds `"root_private_key":"<redacted>"`.

## 2. The rule for an action that handles a secret

A mask hides only the shapes it names; it cannot prove a log is clean. An
action that must hand a secret to its caller prints it in one of the shapes
above, or writes it to a mode-0600 file the caller names and never to
stdout or stderr. A token, password or DSN in any other shape is not masked.

## 3. Proof

`csi-spl-orc/src/bash/tests/run-log-no-key.tst.sh`: a fake key, made in the
test, through all three `run.sh` copies and through the real
`do_spl_tenant_create` with a stub spool CLI; the stdout keeps the key, no
log does. Its control replaces the mask with `cat` and must see the leak.
