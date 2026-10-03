## Push trunk and deploy both environments

Standing order from the human. When your work is ready to land:

1. `git fetch` + `git pull --rebase origin master` (or `main`), then **push directly to trunk**. No PR. No force-push.
2. **Deploy both `dev` and `prd`** with the project's deploy action. Do not wait for a second approval. Sequential if they share a build dir.
3. For csi-web-wui, use `ENV=dev` then `ENV=prd` `./run -a do_gcp_deploy_wui` from `csi-web-utl` with `APP_PATH=/opt/csi/csi-web ORG=csi APP=web CON_WUI=con-csi-web-wui`.

Still forbidden: force-push, hard-reset of trunk, deleting trunk.

