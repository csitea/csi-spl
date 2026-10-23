# 152 tasks: workspace modes and prompt access control

Build rows for [spec.md](spec.md) v0.2. Nothing is built before the owner
answers spec section 9; each row then gets its own issue (the dispatcher
files them). One small task per row, in order: store and API first, then
WUI, then docs. Paths as in the spec (`api/`, `hub/`, `store/`, `rbac/`,
`wui/`).

| row | depends | files (only these) | does | proves (spec section 4) |
|---|---|---|---|---|
| T1 | - | `store/prompt_mode.go`, `store/prompt_mode_test.go`, `rbac/prompt_mode.go`, `rbac/prompt_mode_test.go` | registers `prompt.mode` (`OneOf` from Q1, default `agile`; `prompt.custom` on Q1-C); the matrix of spec 3.3 and the four derived permission ids; `PromptAllows(mode, roles, action)`; an exhaustive table test (every mode x role x action), the `agile` rows equal to `agents.command` of `rbac.Defaults` | R1, R2 |
| T2 | T1 | `hub/rbac.go` (`s.access` only, `:45-59`), `hub/prompt_mode.go`, `hub/prompt_mode_test.go`, `hub/wui.go` (`:838-839` only), `hub/sender_allow.go` (`wuiErrAgent` `reason`, `mode`, `permission`) | the derived bits; the action of a send incl. the mention-poke rule (`ref_task_id`, spec 3.1 / D9); the `EXISTS` new-topic probe; the refusal for `dm`, `mention`, `start` (and Q2-B / C if picked); `TestRoundTripsPerRequest` unchanged; send p95 on dev before / after, with n | R3, R4, R5, R6, R7, R9, R10, R11, R12, R18, R19, R20 |
| T3 | T2 | `hub/wui.go` (`:769-770` only), `hub/topic_reply.go`, `hub/prompt_mode_fanout_test.go`, `hub/rbac.go` (`meBody` only, `:108-112`, `:139`), `hub/tenant_settings.go` (the log line `:173-177` only); on Q4-B also the fan-out list probe | the fan-out and topic-reply skip with `agents_skipped`; `prompt_mode` on `/v1/view/me`; the mode-change log line | R8, R13, R17 |
| T4 | T3 deployed | `wui/pages/tenant-settings/agents.vue`, `wui/components/PromptModeSettings.vue` (new), `csi-spl-wui/tests/unit/prompt-mode.test.mjs`, `csi-spl-wui/tests/e2e/agent-senders.test.mjs` (extend, no new e2e file), the 19 `csi-spl-wui/i18n/locales/*.json` (EVERY new key of spec 3.9, the `composer.*` ones too, so T5 touches no locale file) | the mode picker with its matrix tables (and the custom-mode editor on Q1-C) | R14, R16 |
| T5 | T4 | `wui/utils/send-failure.mjs`, `wui/components/ComposerStatusLine.vue` (or the file that shows the send line, read at build time), `csi-spl-wui/tests/unit/send-failure.test.mjs` | the refusal line, the skipped note, the pre-send hint from `/v1/view/me` `permissions` | R15 |
| T6 | T5 | `csi-spl-doc/specs/044-spool-open-source/contracts/sender-allow-list.md`, this folder's `spec.md` (status v1.x) | the contract's "the mode comes first" section (and the fan-out row on Q4-B); spec marked built | - |
| T7 | T4, T5 | none (review only) | agy reviews the new keys in all 19 locales, the last step before T4 and T5 ship | - |

T2 and T3 both edit `hub/wui.go` and `hub/rbac.go` (different lines), so
they run one after the other (T3 depends on T2), never in parallel; every
other pair of rows shares no file. No row has a migration (spec 3.7).
