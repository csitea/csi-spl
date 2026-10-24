/*
 * The fleet load card's fleet-wide defaults (FleetLoadCard, split out in
 * r19-08): one "uses the default" computed per field, the field edits that
 * clear its reset flag, and resetToDefault(which), which sets a field back to
 * the hub's default and raises its flag. The refs stay declared in the card:
 * its draft, take, save, load and useFleetLoadBoxes read them too. Nuxt
 * auto-imports computed.
 */
import type { Ref } from 'vue'
import type { FleetBoxBand, FleetLoadView } from '~/utils/fleet-load.mjs'

export interface FleetLoadDefaultsOpts {
  view: Ref<FleetLoadView | null>
  low: Ref<number | ''>
  high: Ref<number | ''>
  cpu: Ref<number | ''>
  overflow: Ref<boolean>
  cpus: Ref<number | ''>
  boxes: Ref<string[]>
  bands: Ref<FleetBoxBand[]>
  resetLow: Ref<boolean>
  resetHigh: Ref<boolean>
  resetOrder: Ref<boolean>
  resetBoxes: Ref<boolean>
  resetCpu: Ref<boolean>
  resetOverflow: Ref<boolean>
  resetCpus: Ref<boolean>
  formError: Ref<string>
}

/* one "uses the default" computed per field: its reset flag is up, or
 * nothing is stored and the value is the default */
function defaultFlags(opts: FleetLoadDefaultsOpts) {
  const {
    view, low, high, cpu, overflow, cpus, boxes, bands,
    resetLow, resetHigh, resetOrder, resetBoxes, resetCpu, resetOverflow, resetCpus,
  } = opts

  const lowUsesDefault = computed(() => {
    const s = view.value
    if (!s) return false
    if (resetLow.value) return true
    return s.stored.low == null && Number(low.value) === s.defaults.low
  })
  const highUsesDefault = computed(() => {
    const s = view.value
    if (!s) return false
    if (resetHigh.value) return true
    return s.stored.high == null && Number(high.value) === s.defaults.high
  })
  const orderUsesDefault = computed(() => {
    const s = view.value
    if (!s) return false
    if (resetOrder.value) return true
    return s.stored.boxOrder == null && boxes.value.length === 0
  })
  const bandsUseDefault = computed(() => {
    const s = view.value
    if (!s) return false
    if (resetBoxes.value) return true
    return s.stored.boxes == null && bands.value.length === 0
  })
  const cpuUsesDefault = computed(() => {
    const s = view.value
    if (!s) return false
    if (resetCpu.value) return true
    return s.stored.runnerCpuPct == null && Number(cpu.value) === s.defaults.runnerCpuPct
  })
  const overflowUsesDefault = computed(() => {
    const s = view.value
    if (!s) return false
    if (resetOverflow.value) return true
    return s.stored.ciOverflow == null && overflow.value === s.defaults.ciOverflow
  })
  const cpusUseDefault = computed(() => {
    const s = view.value
    if (!s) return false
    if (resetCpus.value) return true
    return s.stored.runnerCpus == null && Number(cpus.value) === s.defaults.runnerCpus
  })

  return { lowUsesDefault, highUsesDefault, orderUsesDefault, bandsUseDefault, cpuUsesDefault, overflowUsesDefault, cpusUseDefault }
}

/* the field edits (each clears its reset flag) and resetToDefault(which) */
function defaultEdits(opts: FleetLoadDefaultsOpts) {
  const {
    view, low, high, cpu, overflow, cpus, boxes, bands,
    resetLow, resetHigh, resetOrder, resetBoxes, resetCpu, resetOverflow, resetCpus, formError,
  } = opts

  function editLow(raw: string) {
    resetLow.value = false
    low.value = raw === '' ? '' : Number(raw)
  }
  function editHigh(raw: string) {
    resetHigh.value = false
    high.value = raw === '' ? '' : Number(raw)
  }

  function editCpu(raw: string) {
    resetCpu.value = false
    cpu.value = raw === '' ? '' : Number(raw)
  }

  function editOverflow(on: boolean) {
    resetOverflow.value = false
    overflow.value = on
  }

  function editCpus(raw: string) {
    resetCpus.value = false
    cpus.value = raw === '' ? '' : Number(raw)
  }

  function resetToDefault(which: 'low' | 'high' | 'order' | 'boxes' | 'cpu' | 'overflow' | 'cpus') {
    const s = view.value
    if (!s) return
    formError.value = ''
    if (which === 'low') {
      low.value = s.defaults.low
      resetLow.value = true
    } else if (which === 'high') {
      high.value = s.defaults.high
      resetHigh.value = true
    } else if (which === 'cpu') {
      cpu.value = s.defaults.runnerCpuPct
      resetCpu.value = true
    } else if (which === 'overflow') {
      overflow.value = s.defaults.ciOverflow
      resetOverflow.value = true
    } else if (which === 'cpus') {
      cpus.value = s.defaults.runnerCpus
      resetCpus.value = true
    } else if (which === 'order') {
      boxes.value = []
      resetOrder.value = true
    } else {
      bands.value = []
      resetBoxes.value = true
    }
  }

  return { editLow, editHigh, editCpu, editOverflow, editCpus, resetToDefault }
}

export function useFleetLoadDefaults(opts: FleetLoadDefaultsOpts) {
  return { ...defaultFlags(opts), ...defaultEdits(opts) }
}
