# Refactor round 6 - agy seat proposal

Re-measured on origin/master:
- r5 D3: `grep -rnE "await fetch\(" csi-spl-wui/src/utils/ | grep -v signal | wc -l` -> 13
- r5 D4: `grep -rnE "^\\s+exit [0-9]" --include=*.func.sh csi-spl-{iac,orc}/{src,lib}` -> 11
- r5 section 8: `git ls-files "csi-spl-api/*.sh" "csi-spl-wui/*.sh" | wc -l` -> 22, and shellcheck -> 6 findings

## The 10 actions

- **01 agree**: adding abort signals prevents hung calls on fetch failures.
- **02 agree**: applies the same timeout fix to calendar calls.
- **03 agree**: returning instead of exiting prevents killing the caller shell.
- **04 agree**: enforcing static analysis on missing scripts improves CI.
- **05 agree**: preventing stale tree pushes avoids silent reverts.
- **06 agree**: higher coverage in hub packages improves test reliability.
- **07 agree**: DRY extraction reduces code duplication in cron blocks.
- **08 agree**: DRY extraction of probe preambles simplifies code.
- **09 agree**: splitting WUI functions keeps them under the length limit.
- **10 agree**: splitting bash functions improves readability.

Signed: plan sha ed453dd77
