# Tasks: 042 @ Mention Picker Everywhere and the Mention Poke (SPL-985)

- [x] T001 `utils/mention-poke.mjs`: who to poke (K3 dedupe/self/addressee), the DM body (K1), and the access filter (K4). Unit tests.
- [x] T002 `composables/useMentionPicker.ts` + `components/MentionList.vue`: the omnibox picker moved out of `MessageComposer.vue` (P1-P4).
- [x] T003 The picker in: message edit box, issue description, issue comment, new issue, subtask title, channel description (P1).
- [x] T004 `composables/useMentionPoke.ts`: sends the DMs after a store succeeds (channel / DM / lobby / thread sends, edit, issue, comment) and warns (K4, K6); 19 locales.
- [x] T005 Live proof on dev t1 and prd e2e: @ in 3 inputs, the agent's DM and pane poke arrive.
  `tests/e2e/mention-poke-live.proof.mjs`, n=1 each, AGENT=CLE-35020@box-desk (a seated desk agent):
  - dev t1, WUI cdf2ac7a, run muiv39j4: steps 1a-3b PASS; 3 poke DMs in the desk inbox, 3 pane notices, 0 for the edit
    (the step-5 FAIL of that run was the proof's own author lookup, fixed in f57ca024)
  - prd e2e, WUI cdf2ac7a, run muiv6zqd: 2 of 3 - the lobby-room line was refused by the K4 lookup (fixed in a20fdab4)
  - prd e2e, WUI a20fdab4, run muivj0t2: ALL PASS (9 steps), 3 DMs, 3 pane notices, no snackbar warning
