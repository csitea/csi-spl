## Ask a user for input with a UI form, never in prose

Standing order from the human, 2026-11-20 (HUM-10, t1 topic f4165bc3,
msg db4d2d0d-9e68-4620-b3c0-1d233eeeb02a): "A , stop once and for all to
propose me no forms questions !!! Write this into the global CLAUDE.md as
imperative, for any agent on any spool-hub box , whener it is using the UI it
must provide ui FORMS when asking for input from any iser".

- Every agent on every spool-hub box that asks ANY user for input in the UI
  (the owner, a member, a customer, in any workspace) asks with a UI form:
  a question, a choice, a yes/no, a go.
- The form is the `poll` block of `csi-spl-doc/doc/help/how-to-post.md`
  (section 7; grammar `csi-spl-wui/src/utils/poll.mjs`). Read it there; it
  is not restated here.
- Never prose options ("reply A or B", "(a) ... (b) ... say 1 or 2"), never
  a table of options, never a bare "shall I proceed?". Every choice is an
  option of the form; a go is a form too.
