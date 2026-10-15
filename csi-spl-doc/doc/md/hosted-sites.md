# Hosted static sites: step 021 and do_deploy_hosted_site

SPL-1985. A static website that is not the spool app gets its OWN Firebase
Hosting site in the env's project, its own host `<name>.<fqdn>` and its own
DNS records. The WUI site (019) is never touched: its host serves the spool.

## 1. The cnf

One entry per site, keyed by its name. The shared values go in
`csi-spl-cnf/csi-spl/all.env.yaml`, the per-env ones in `<env>.env.yaml`:

```yaml
021-firebase-hosted-sites:      # all.env.yaml
  sites:
    ws-hidden-NN:               # a customer name is its placeholder
      src_dir: /opt/csi/<repo>  # the site's Nuxt repo on the box
021-firebase-hosted-sites:      # dev.env.yaml (prd: site_id only)
  sites:
    ws-hidden-NN:
      site_id: csi-spl-dev-ws-hidden-NN
      noindex: true             # dev: always true
```

- A customer name never enters this public repo: it is a `ws-hidden-NN`
  placeholder of the [private overlay](private-overlay.md). `do_tf_init` and
  `do_spl_cloud_cnf` resolve the host; the `site_id` keeps the placeholder
  (Firebase site ids are global and permanent).
- When the slug is also an ordinary word somewhere in the repo, it goes in
  the overlay's `forms_only` list too, or the hygiene gate refuses that word.
- Render: `cd csi-spl-iac && ENV=<env> ./run -a do_tpl_gen`.

## 2. The infrastructure: step 021-firebase-hosted-sites

Per site: `google_firebase_hosting_site` (`prevent_destroy`: a deleted site
id can never be reused), `google_firebase_hosting_custom_domain` for
`<name>.<fqdn>`, and the records Firebase asks for, `A 199.36.158.100` +
`TXT "hosting-site=<site_id>"`, ADDED to 025's zone (no other record is
touched). Needs 019 applied first (the Firebase project and the hosting API).

Plan, then apply with the go (repo CLAUDE.md: tf-runner only, dev leads prd):

`cd csi-spl-orc && ENV=dev STEP=021-firebase-hosted-sites make do-tf-plan`

Firebase verifies the host and mints its certificate asynchronously, minutes
to an hour after the records exist.

## 3. The deploy: do_deploy_hosted_site

Builds `src_dir` at a commit (default its HEAD) from a clean clone, never its
work tree: `pnpm install --frozen-lockfile`, `pnpm run generate` with
`NUXT_PUBLIC_SITE_URL=https://<host>`; a `noindex` site also gets
`NUXT_PUBLIC_NOINDEX=1`, `NUXT_PUBLIC_PREVIEW_NOTICES=1` and the header
`X-Robots-Tag: noindex, nofollow`. The two flags are passed JSON-quoted
(`"1"`): Nuxt parses a `NUXT_PUBLIC_*` value, and a bare `1` becomes a
number that a `=== '1'` test never matches. Then `firebase deploy --only hosting` with
the env's project SA key, and a probe of `<site_id>.web.app/build.json`.
firebase-tools runs on a pinned node (`FIREBASE_NODE_VERSION`, default
22.20.0): on node 20.19.2 its token fetch fails ("Premature close", reported
as "Failed to authenticate").

`cd csi-spl-orc && ENV=dev ./run -a do_deploy_hosted_site`

prints the plan (DRY_RUN=1 is the default). To deploy:

`cd csi-spl-orc && ENV=dev DRY_RUN=0 SITE=ws-hidden-NN ./run -a do_deploy_hosted_site`

Test: `csi-spl-orc/src/bash/tests/deploy-hosted-site.tst.sh`.
