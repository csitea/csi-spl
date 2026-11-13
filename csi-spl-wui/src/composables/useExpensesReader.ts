// SPL-5420 (owner HUM-10, t1 ea5d52a7): whether this reader opens the
// Expenses section: the hub's expenses_reader on /v1/view/me
// (internal/hub/operator_read.go expensesReaders: the operator reader, and the
// operator workspace's biz_owner and internal_accountant), or, before a hub
// that sends it, useOperatorReader's answer. Hiding only; the hub's 403 is the
// control.
import { computed } from 'vue'
import { useAccessStore } from '~/stores/access'
import { useOperatorPane } from '~/stores/operator-pane'
import { expensesReads } from '~/utils/access.mjs'

export function useExpensesReader() {
  const access = useAccessStore()
  const operator = useOperatorPane()
  return computed(() => expensesReads(access.me, operator.visible))
}
