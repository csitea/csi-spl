/*
 * The fleet load card's two box lists (FleetLoadCard, split out in r17-06).
 * `bands` = the per-box bands (editBand, removeBand, addBand); `boxes` = the
 * box order (move, removeAt, addBox). Every edit clears its list's reset
 * flag. The refs stay declared in the card: its draft, take, resetToDefault
 * and save read them too.
 */
import type { Ref } from 'vue'
import { moveItem } from '~/utils/tenant-settings.mjs'
import { FLEET_BOX_MAX, validFleetBox } from '~/utils/fleet-load.mjs'
import type { FleetBoxBand, FleetLoadView } from '~/utils/fleet-load.mjs'

export interface FleetLoadBoxesOpts {
  bands: Ref<FleetBoxBand[]>
  boxes: Ref<string[]>
  resetBoxes: Ref<boolean>
  resetOrder: Ref<boolean>
  /* the add fields: a band's box id, the order's box id */
  bandBox: Ref<string>
  candidate: Ref<string>
  formError: Ref<string>
  /* the fleet band as edited: a new band starts on it */
  low: Ref<number | ''>
  high: Ref<number | ''>
  view: Ref<FleetLoadView | null>
  t: (key: string) => string
}

export function useFleetLoadBoxes(opts: FleetLoadBoxesOpts) {
  const { bands, boxes, resetBoxes, resetOrder, bandBox, candidate, formError, low, high, view, t } = opts

  /*
   * The one admission check of addBand and addBox: a bad id or a full list
   * says so; an id already there clears the field. '' = not admitted (no
   * valid box id is empty).
   */
  function admit(field: Ref<string>, taken: (id: string) => boolean, size: number): string {
    const id = field.value.trim().toLowerCase()
    formError.value = ''
    if (!validFleetBox(id)) {
      formError.value = t('tenant_settings.fleet_load_bad_box')
      return ''
    }
    if (taken(id)) {
      field.value = ''
      return ''
    }
    if (size >= FLEET_BOX_MAX) {
      formError.value = t('tenant_settings.fleet_load_full')
      return ''
    }
    return id
  }

  /* an empty cap or core count is null: that box uses the fleet's; an empty aim is null: no aim (= high) */
  function editBand(i: number, field: 'low' | 'aim' | 'high' | 'runnerCpuPct' | 'runnerCpus', raw: string) {
    const empty = field === 'low' || field === 'high' ? NaN : null
    bands.value = bands.value.map((b, j) => (j === i ? { ...b, [field]: raw === '' ? empty : Number(raw) } : b))
    resetBoxes.value = false
  }
  function removeBand(i: number) {
    bands.value = bands.value.filter((_, j) => j !== i)
    resetBoxes.value = false
  }
  /* A new band starts on the fleet band in force, for the admin to edit. */
  function addBand() {
    const id = admit(bandBox, (x) => bands.value.some((b) => b.box === x), bands.value.length)
    if (!id) return
    const lo = Number(low.value) || view.value?.defaults.low || 50
    const hi = Number(high.value) || view.value?.defaults.high || 75
    bands.value = bands.value.concat({ box: id, low: lo, high: hi })
    resetBoxes.value = false
    bandBox.value = ''
  }

  function move(i: number, delta: number) {
    boxes.value = moveItem(boxes.value, i, delta)
    resetOrder.value = false
  }
  function removeAt(i: number) {
    boxes.value = boxes.value.filter((_, j) => j !== i)
    resetOrder.value = false
  }
  function addBox() {
    const id = admit(candidate, (x) => boxes.value.includes(x), boxes.value.length)
    if (!id) return
    boxes.value = boxes.value.concat(id)
    resetOrder.value = false
    candidate.value = ''
  }

  return { editBand, removeBand, addBand, move, removeAt, addBox }
}
