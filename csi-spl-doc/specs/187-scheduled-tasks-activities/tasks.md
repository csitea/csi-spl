# Spec 187 tasks: Scheduled Tasks and Activities

Spec: [spec.md](spec.md) v0.3 (Decided). The rows, their files, done tests
and red controls are in spec section 9; their binding contracts in 9.1. This
list only orders them and tracks their state. Epic SPL-2398; spec issue
SPL-6067.

| task | row | depends on | kind | state |
|---|---|---|---|---|
| T001 | S1 rdb + store | — | `complex_coding` | not started |
| T002 | S2 grammar `idle:` / `changed:` | — | `simple_coding` | not started |
| T003 | S3 hub runner + fixed actions | T001 | `complex_coding` | not started |
| T004 | S4 event triggers + chains | T003 | `complex_coding` | not started |
| T005 | S5 agent action + caps | T003 | `complex_coding` | not started |
| T006 | S6 two levels (`t1` admins, default caps) | T001, T003 | `complex_coding` | not started |
| T007 | S7 workspace routes | T001, T003 | `simple_coding` | not started |
| T008 | S8 wui (then agy for the locales) | T007, T011, T012 | `simple_coding`, `i18n` | not started |
| T009 | S9 e2e | T008 | `tests` | not started |
| T010 | S10 docs | T003-T008, T011, T012 | `specs_and_docs` | not started |
| T011 | S11 labels on topics and messages | T002 | `complex_coding` | not started |
| T012 | S12 cron trigger | parser: —; store and runner part: T003 | `simple_coding` | not started |

Parallel now: T001, T002 and T012's parser. T011 after T002 (both edit
grammar 1.7). After T003: T004, T005, T006, T007 and T012's runner part in
parallel. The owner answered Q1-Q11 (spec 1.1.2); nothing is open.
