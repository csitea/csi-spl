# Tasks: 042 @ Mention Picker Everywhere and the Mention Poke (SPL-985)

- [ ] T001 `utils/mention-poke.mjs`: who to poke (K3 dedupe/self/addressee), the DM body (K1), and the access filter (K4). Unit tests.
- [ ] T002 `composables/useMentionPicker.ts` + `components/MentionList.vue`: the omnibox picker moved out of `MessageComposer.vue` (P1-P4).
- [ ] T003 The picker in: message edit box, issue description, issue comment, new issue, subtask title, channel description (P1).
- [ ] T004 `composables/useMentionPoke.ts`: sends the DMs after a store succeeds (channel / DM / lobby / thread sends, edit, issue, comment) and warns (K4, K6); 19 locales.
- [ ] T005 Live proof on dev t1 and prd e2e: @ in 3 inputs, the agent's DM and pane poke arrive.
