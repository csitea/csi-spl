// SPL-5181 (owner HUM-10, t1 8426e63e, t1 36406a93): whether this reader sees
// the operator's costs, expenses and lanes: the hub's operator_reader on
// /v1/view/me (internal/hub/operator_read.go), or, before a hub that sends it,
// the operator console's probe. Hiding only; the hub's 403 is the control.
import { computed } from 'vue'
import { useAccessStore } from '~/stores/access'
import { useOperatorPane } from '~/stores/operator-pane'
import { operatorReads } from '~/utils/access.mjs'

export function useOperatorReader() {
  const access = useAccessStore()
  const operator = useOperatorPane()
  return computed(() => operatorReads(access.me, operator.visible))
}
