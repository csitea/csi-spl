## What and why

Closes #<issue>. <!-- the agreed issue: CONTRIBUTING.md, "Before you write code" -->

## Tests you ran

<!-- paste the command and its last line, for each part you touched -->

- [ ] `bash csi-spl-api/src/bash/tests/run-all-tests.sh` (`csi-spl-api`)
- [ ] `pnpm run typecheck` and `pnpm run test:unit` in `csi-spl-wui`
- [ ] `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` (`csi-spl-iac`)
- [ ] none of these: the change touches only docs

## Cheap gate

- [ ] `cd csi-spl-iac && ./run -a do_check_dist_hygiene` is clean: no secret, no
      filled-in `.env`, no key file, no organisation host name
- [ ] no applied migration in `csi-spl-rdb` was edited
