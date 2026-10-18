# Set the Mistral key on a box

> Generated from qto doc `b6dfdbac-9296-48fa-bcc7-380d4999ef7d`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Spool agents of the Mistral kind (spec 110) read their key from
`.vibe/.env` in the **agent user's** home: one line `MISTRAL_API_KEY=<key>`,
mode `600` in a `700` dir. One action writes it:
`./run -a do_set_mistral_key`, run from `csi-spl-orc` in the box's spool
checkout. The key never goes on a command line, into a log or into a tmux
window.

<a id="ws-doc-5df51b62-84e8-4259-a43f-2c2764a313c1"></a>
## 1. The key is already in a file (the usual case)

If the key is already on the main box in a file of yours (e.g. the
`~/.mistral/crs` file, one line `MISTRAL_API_KEY=<key>`, mode `600`), nothing
is typed or pasted. From `csi-spl-orc` in the main box's checkout:

1. The main box:

   ```bash
   MISTRAL_KEY_FILE=$HOME/.mistral/crs ./run -a do_set_mistral_key
   ```

2. The satellite, streamed over ssh stdin to its agent user (the ssh alias
   comes from `./run -a do_satellite_ssh_config`):

   ```bash
   MISTRAL_KEY_FILE=$HOME/.mistral/crs TO_BOX=sat ./run -a do_set_mistral_key
   ```

An agent may run these for you: neither shows the key.

<a id="ws-doc-2bd11ca3-00fc-4dbf-8d86-a4d719da0b43"></a>
## 2. Typing the key

When the key exists only in the Mistral console, type it at a prompt, in a
**plain ssh session with no tmux**. Inside a fleet agent window the action
refuses, because agents read those windows' scrollback.

1. Open a plain session on the box: `ssh <box>` from your own machine, and
   do not run `tmux attach`. Check with `echo "${TMUX:-no tmux}"`, which must
   print `no tmux`.
2. `cd` to `csi-spl-orc` in the box's spool checkout and run:

   ```bash
   ./run -a do_set_mistral_key
   ```

3. Paste the key at the `Mistral API key (not echoed):` prompt and press
   Enter. Nothing shows while you paste.

Repeat on each box. `TO_BOX=sat` also works from the main box.

<a id="ws-doc-ebe47041-fd3b-44eb-b927-1bd9d8076bb0"></a>
## 3. What success looks like

The action prints only the key's length and its last 4 characters, never
the key:

```text
INFO key read: length=32 last4=Ab9z
verify path=<agent-home>/.vibe/.env mode=600 dir_mode=700 owner=<agent-user> key=length=32 last4=Ab9z
OK MISTRAL_API_KEY is in <agent-home>/.vibe/.env for <agent-user> (length=32 last4=Ab9z)
INFO key validity check skipped (MISTRAL_KEY_CHECK_URL not set)
```

Compare the last 4 characters with the key in the Mistral console. Any
other lines already in `.vibe/.env` are kept. Running it again replaces the
key.

<a id="ws-doc-0c616b12-464a-40e4-b070-8c18ff9adf53"></a>
## 4. Optional: ask the vendor whether the key works

Set `MISTRAL_KEY_CHECK_URL` to the vendor's read-only model-list endpoint
(see the Mistral API docs). The action then makes one GET, passing the key
as a header through a file descriptor. HTTP 200 prints `OK the vendor
accepts the key`. HTTP 401 or 403 prints `FAIL ... dead`, and the key stays
written so you can replace it.
