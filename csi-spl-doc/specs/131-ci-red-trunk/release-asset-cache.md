# Scanner installs survive a release-asset outage (SPL-5050)

On 2026-11-08 the pinned gitleaks and trufflehog release assets answered
502/503/504 for hours while other GitHub URLs answered 200, and pushes went
red at `Install gitleaks 8.30.1`.

Every scanner install in `.github/workflows` now follows one pattern:

1. An `actions/cache` step holds the asset, key
   `release-asset-<tool>-<version>-<sha256>`, path
   `.release-asset-cache/<tool>-<version>` (workspace-relative, so all runners
   share one entry; git-ignored).
2. The `Install <tool>` step copies the cached asset, or downloads it on a miss.
3. The sha256 pinned in the step is checked on every use, cached or downloaded.
   Only a verified asset is written to the cache path.

- **Warm cache:** the release URL is never contacted.
- **Cold cache and the release is down:** the step fails with
  `::error::<url> is unavailable and has no cached copy: the scan cannot run`.
  The scan is never skipped silently.
- **Tool already in the runner's tool cache:** nothing is fetched, as before.
- A bad cached copy fails closed; the key is immutable, so delete that cache
  entry to recover.

`64_trufflehog.yml` restores and saves in separate steps and removes the asset
before the scan, because trufflehog reads the whole checkout.

The trivy steps in wf 10 and 15 also check the release's checksums file on a
download, and now pin the same sha256 as wf 70.

The orc test job in wf 10 exports `GITLEAKS_BIN` from its install step, so
`oss_gitleaks_bin` (`csi-spl-orc/src/bash/run/oss-gate.func.sh`) uses that binary
and does not download its own.

Test: `csi-spl-iac/src/bash/tests/workflow-release-asset-cache.tst.sh`.
