# modules

Reusable terraform modules for the numbered steps. `do_tf_init` (ported
from csi-rel unchanged) copies `src/terraform/modules` beside every run dir
and md5-compares it on each run, so the directory must exist even while no
step uses a module.
