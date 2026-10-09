# Refactor Round 5 Proposal - agy (tnk)

1. **Practice**: 3. eliminate dead code, duplicate logic (DRY), unnecessary comments
   **Sites**: `csi-spl-iac/src/bash/run/gcp-sync-s3-to-local.func.sh`, `csi-spl-iac/src/bash/run/gcp-sync-local-to-s3.func.sh`
   **Measure**: 6 on `d5d136053ac58a95c5d9f40e8463c4c9ee3f2d28` via `grep -E 'SC2034.*(gcp-sync-s3-to-local|gcp-sync-local-to-s3)' .shellcheck-warning-baseline.txt | wc -l`
   **Test**: `gcp-actions-isolated-config.tst.sh` passes.

2. **Practice**: 3. eliminate dead code, duplicate logic (DRY), unnecessary comments
   **Sites**: `csi-spl-iac/src/bash/tests/resolve-oap-worktree.tst.sh`
   **Measure**: 2 on `d5d136053ac58a95c5d9f40e8463c4c9ee3f2d28` via `grep 'SC2034.*resolve-oap' .shellcheck-warning-baseline.txt | wc -l`
   **Test**: `resolve-oap-worktree.tst.sh` passes.

3. **Practice**: 3. hidden failure paths / readable code
   **Sites**: `csi-spl-iac/src/bash/run/gcp-import-to-cloudsql.func.sh`, `csi-spl-iac/src/bash/run/gcp-export-dns-settings.func.sh`
   **Measure**: 2 on `d5d136053ac58a95c5d9f40e8463c4c9ee3f2d28` via `awk '/^[ \t]+exit 1$/' csi-spl-iac/src/bash/run/gcp-import-to-cloudsql.func.sh csi-spl-iac/src/bash/run/gcp-export-dns-settings.func.sh | wc -l`
   **Test**: `gcp-actions-isolated-config.tst.sh` passes.

4. **Practice**: 4. automated linting, formatting and static analysis
   **Sites**: `csi-spl-iac/src/bash/tests/check-pre-push-baseline.tst.sh`
   **Measure**: 3 on `d5d136053ac58a95c5d9f40e8463c4c9ee3f2d28` via `grep 'check-pre-push-baseline.tst.sh' .shellcheck-warning-baseline.txt | wc -l`
   **Test**: `check-pre-push-baseline.tst.sh` passes.

5. **Practice**: 4. automated linting, formatting and static analysis
   **Sites**: `csi-spl-orc/src/bash/features/spool-install/tests/test-install.sh`
   **Measure**: 1 on `d5d136053ac58a95c5d9f40e8463c4c9ee3f2d28` via `grep 'SC2054.*test-install.sh' .shellcheck-warning-baseline.txt | wc -l`
   **Test**: `test-install.sh` passes.

6. **Practice**: 3. hidden failure paths (missing signal in fetch)
   **Sites**: `wui:src/utils/release-notes-api.mjs`, `wui:src/utils/hours-calendar-api.mjs`, `wui:src/utils/public-calendar-web.mjs`, `wui:src/utils/calendar-events-api.mjs`, `wui:src/utils/hours-team-api.mjs`
   **Measure**: 7 on `d5d136053ac58a95c5d9f40e8463c4c9ee3f2d28` via `grep -rnE "await fetch\(" csi-spl-wui/src/utils/ | grep -v "signal" | grep -E "release-notes|hours-calendar|public-calendar|calendar-events|hours-team" | wc -l`
   **Test**: `pnpm run test:unit` in WUI.

7. **Practice**: 3. hidden failure paths (missing signal in fetch)
   **Sites**: `wui:src/utils/msg-ai-actions.mjs`, `wui:src/utils/human-status.mjs`, `wui:src/utils/hours-timer.mjs`
   **Measure**: 4 on `d5d136053ac58a95c5d9f40e8463c4c9ee3f2d28` via `grep -rnE "await fetch\(" csi-spl-wui/src/utils/ | grep -v "signal" | grep -E "msg-ai-actions|human-status|hours-timer" | wc -l`
   **Test**: `pnpm run test:unit` in WUI.

8. **Practice**: 3. hidden failure paths (missing signal in fetch)
   **Sites**: `wui:src/components/workspace-docs/-doctree-api.ts`, `wui:src/components/CalendarPhonePeek.vue`, `wui:src/components/ApiDocViewer.vue`
   **Measure**: 3 on `d5d136053ac58a95c5d9f40e8463c4c9ee3f2d28` via `grep -rnE "await fetch\(" csi-spl-wui/src/components/ | grep -v "signal" | wc -l`
   **Test**: `pnpm run test:unit` in WUI.

9. **Practice**: 1. unnecessary comments / say why error swallow is safe
   **Sites**: `api:internal/store/workspace_docs_ops.go`, `api:internal/store/message_claim.go`
   **Measure**: 2 on `d5d136053ac58a95c5d9f40e8463c4c9ee3f2d28` via `grep -rnE "(early|id), _ = " csi-spl-api/src/go/spool-hub-api/internal/store/ | grep -v "_test.go" | wc -l`
   **Test**: `go test ./internal/store/`

10. **Practice**: 4. automated linting, formatting and static analysis
    **Sites**: `csi-spl-orc/src/bash/features/spawn-agents/tests/lib.inc.sh`, `csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-agent.sh`
    **Measure**: 2 on `d5d136053ac58a95c5d9f40e8463c4c9ee3f2d28` via `grep -E 'SC2155.*spawn-agents/tests' .shellcheck-warning-baseline.txt | wc -l`
    **Test**: `test-spool-agent.sh` passes.
