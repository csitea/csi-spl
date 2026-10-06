/**
 * Spec 096 §7.5: the "Set a status" picker, opened from the reader's own row
 * at the top of the DM list and from the avatar menu. One instance, mounted
 * lazily by the default layout while open (the 160 KB initial-chunk budget).
 */
export function useStatusPicker() {
  const open = useState('status-picker-open', () => false)
  return {
    open,
    show() { open.value = true },
    hide() { open.value = false },
  }
}
