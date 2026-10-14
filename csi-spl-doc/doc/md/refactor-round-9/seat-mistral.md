# Mistral seat review for refactor-round-9-plan.md

**Plan sha:** `9296e7b99` (2026-10-14T08:37:00Z)

## Objections

1. **Row 03 (`refactor(r9-03-wui-small-stores-topic-viewer)`): Incorrect line counts in plan.**
   - **Plan claim:** `src/stores/topic.ts <anon>` is 117 lines, `src/stores/viewer.ts <anon>` is 173 lines.
   - **Measured (9296e7b99):** `topic.ts` is 153 lines, `viewer.ts` is 183 lines.
   - **Measured (origin/master):** Same as 9296e7b99; **no LONG entries** for either file in `cleancode.test.mjs`.
   - **Command:** `find src/stores -name "*.ts" -exec wc -l {} \;` in `csi-spl-wui`.
   - **Objection:** The plan's line counts are incorrect. Neither file is listed as LONG in `cleancode.test.mjs`.
   - **Suggested replacement:**
     ```text
     | 03 `refactor(r9-03-wui-small-stores-topic-viewer)` | small functions | Two store anonymous setup bodies exceed MAX_LINES | `wui:src/stores/topic.ts:25`<br>`wui:src/stores/viewer.ts:28`<br>`wui:tests/unit/cleancode.test.mjs:40,41` | 2 entries (153 and 183 lines) | Decompose inner actions into named module-level step functions under 80 lines; preserve store interface and reactivity. Delete both lines from `cleancode.test.mjs` LONG map (10 -> 8 listed). **Red control:** dummy 81-line function in `topic.ts` fails `cleancode.test.mjs`. `topic-kind.test.mjs`, typecheck | PC | simple_coding | 1 |
     ```

## Withdrawn objections

2. **Row 05 (`test(r9-05-bash-stripe-measure-fix)`): Withdrawn.**
   - **Plan v1.0 correctly describes the defect:** The awk walker misses inline closing braces, hiding `do_spl_provision_stripe_endpoints` (118 lines) and listing `_spl_stripe_json_get` as fake LONG (130 lines, real: 13 lines).
   - **Measured (9296e7b99):** `_spl_stripe_json_get` is 13 lines, `do_spl_provision_stripe_endpoints` is 118 lines.
   - **No objection.**

3. **Row 01 (`test(r9-01-go-coverage-spool-cli-fs)`): Tooling unavailable for verification.**
   - **Withdrawn:** Plan v1.0 clarifies that tests use an `httptest.Server` stub hub, so tooling is not required for verification.

## Signature

**No further objections.**

`signed: m-501 on 9296e7b99`