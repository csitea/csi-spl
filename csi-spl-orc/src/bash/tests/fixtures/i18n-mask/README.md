# The i18n mask's shared fixture

`input.txt` masked with `terms.txt` is `masked.txt`, token for token, by both
masks: the bash action `do_spl_i18n_mask` (spec 115 T9) and the hub's Go port
`csi-spl-api/src/go/spool-hub-api/internal/i18nmask` (spec 123 16.6.5).
`map.tsv` is the bash action's map for it. Tested by
`csi-spl-orc/src/bash/tests/spl-i18n-mask-fixture.tst.sh` and
`internal/i18nmask/mask_test.go`. Every value is synthetic.

To change it: edit `input.txt` or `terms.txt`, then rewrite `masked.txt` and
`map.tsv` with the bash action (`SPL_I18N_MASK_FIXTURE_WRITE=1` on the bash
test), and check that the Go test agrees.
