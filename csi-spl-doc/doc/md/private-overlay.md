# The private overlay: hidden workspaces in a public repo

> Generated from qto doc `737a2da7-d4b7-4995-9417-556c132c09f2`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

SPL-1874. Owner HUM-10, t1 topic 7b4b9ddb, poll 6c701ac9: "Let's have the
csitea and relishbg visible, and the rest not visible". Our own platform
workspaces visible on poll 7b41f5e6: csi-rel, t1, system, demo, e2e, e2e-2.
Every other workspace slug is HIDDEN: it is never written into this repo.

## 1. How it works

- The public cnf (`csi-spl-cnf/csi-spl/<env>.env.yaml`) lists a hidden
  workspace by its **placeholder**, `ws-hidden-NN`, in place of its slug
  (`env.dns.mapped_tenants`, `steps.052-gcs-workspace-docs.workspaces`,
  `marketing.workspaces`). `do_tpl_gen` renders the placeholders into
  `<env>.env.json` and the tfvars as they are, so CI's render parity needs
  no secret.
- The **overlay** maps each placeholder to its slug. It is one file, never in
  git: `$HOME/.gcp/.csi/csi-spl-private.yaml` (override: `SPL_PRIVATE_CNF`),
  mode 600, beside the project SA keys, so the tf-runner reads it through its
  `~/.gcp` mount.
- Only what needs the real slug resolves it, through one library,
  `csi-spl-iac/lib/bash/funcs/spl-private-cnf.func.sh`:
  - terraform: `do_tf_init` writes the resolved tfvars into the step's run dir
    (`tf_vars_path`, mode 600); every `do_tf_*` action reads that. A tfvars
    with a placeholder and no overlay is a FATAL that names the file: no plan
    or apply ever runs on placeholders.
  - the runtime cnf: `do_spl_cloud_cnf` resolves `SPL_CNF` (a private state
    dir). Without the overlay it WARNS and keeps the placeholders;
    `do_spl_tenant_test_purge` then refuses.
  - the tenant host actions (`do_spl_tenant_host_provision`, `_reconcile`,
    `_deprovision`) write the placeholder into the cnf. A NEW tenant is
    hidden by default: the action adds its line to the overlay. Visible
    instead: `TENANT_VISIBLE=1` (and `e2e*` test workspaces). In GitHub
    Actions the overlay is a copy of a secret, so a new hidden tenant is
    refused there. Commit messages name the placeholder, never the slug.
  - the gates: the 10 ci distribution-hygiene Sweep, and `do_oss_gate`'s
    `{{private:workspaces}}` / `{{private:orgs}}` rules.

## 2. The file

```yaml
workspaces:            # one line per hidden workspace
  ws-hidden-01: <slug>
forms_only:            # slugs that are also ordinary words here
  - <slug>
orgs:                  # other organisations (do_oss_gate other-org)
  - <org>
deny:                  # other literals the hygiene gate refuses (PCRE)
  - '<regex>'
```

- **Hide a slug:** add its `ws-hidden-NN` line, write the placeholder in
  place of the slug in the cnf, `ENV=<env> ./run -a do_tpl_gen` (csi-spl-iac).
- **Make one visible:** the reverse: delete its line, write the slug back.
- A `forms_only` slug (the product word `spool` is one) is refused only as a
  workspace: an entry of a list whose key names workspaces, tenants or fqdns,
  a DNS record name, a `<slug>.[dev.]<BASE_DOMAIN>` host. Any other slug is
  refused anywhere, as a word.

## 3. The gate

The 10 ci Sweep builds its patterns with `spl_private_gate_patterns` from the
overlay: in CI the repository secret `SPL_PRIVATE_CNF_YAML` (the file's
content), on a box the file (`./run -a do_check_dist_hygiene`). It prints a
label and file:line, never the name. A master push with no overlay fails; a
pull request (no secrets) warns. Controls:
`csi-spl-iac/src/bash/tests/hygiene-hidden-workspaces.tst.sh` and
`spl-private-cnf.tst.sh`.

Skipped, named in the Sweep: rdb migration 0051, whose sha256 is pinned in
every env's `spool_schema_migrations` (forward-only: a changed comment fails
the hub's migrate).

## 4. Where the copies are, and the backup

- The satellite: `~/.gcp/.csi/` of the box owner user and of the agent user
  (cnf `box_owner_user`, `box_agent_user`). The other box: the same paths,
  pulled from the satellite (which cannot reach it), for both users, by
  `cd csi-spl-orc && DRY_RUN=0 ./run -a do_spl_private_overlay_pull`
  (SPL-1919): it fails fast when either source is missing or empty, writes
  each file mode 600 owned by its user, verifies the sha256 and never prints
  the content. Dry run by default.
- GitHub: the secret `SPL_PRIVATE_CNF_YAML` (write-only; it feeds CI and the
  40 reconcile workflow).
- An update is made on the satellite, then copied to the other user, the
  other box and the secret
  (`gh secret set SPL_PRIVATE_CNF_YAML < <file>`).
- Lost everywhere: the names are recoverable. Git history before SPL-1874
  still holds every slug in place (no history rewrite, CLAUDE.md 5.1): the
  placeholder at a list position stands for the slug at the same position in
  `git show <sha before SPL-1874>:csi-spl-cnf/csi-spl/prd.env.yaml`. A tenant
  hidden later is in the hub's `tenants` table and 052's terraform state.

## 5. What it does not do

- It does not rewrite history: commits before SPL-1874 still hold the names.
- It cannot prove absence (a deny list only finds what it names): a slug that
  is not in the overlay is not swept.
- The 40 reconcile workflow is disabled. Its job logs on a public repo are
  public: enable it only once its logs name placeholders, not slugs.
