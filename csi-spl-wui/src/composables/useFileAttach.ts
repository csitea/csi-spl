/**
 * Attach files to a text box: the paperclip's file picker and a pasted file.
 *
 * Lifted out of MessageComposer.vue so the issue description and the issue
 * comment box take files the same way (owner HUM-10, t1 43ebdf0b: Ctrl + V
 * files in the issue descriptions and the comments, and an attach button
 * there too). The caller owns the hidden <input type="file"> (`fileEl`) and
 * decides what happens to `picked`.
 */
import { onBeforeUnmount, ref, type Ref } from 'vue'
import { filesOf, pasteAttaches } from '~/utils/transfer-files'

export function useFileAttach(fileEl: Ref<HTMLInputElement | null>) {
  const picked = ref<File[]>([])
  /* Owner, 2026-09-25: eight tries, eight messages with no file, and not a
     word on screen. A DOUBLE-CLICK on the file in the GTK file dialog lost the
     pick before the page saw it (Select + Open worked, n=1). The page cannot
     get that file back, but it must not stay silent: when the dialog closes
     with nothing, say so and name the two ways that work. Chrome fires
     `cancel` on the input for an empty close; a close that fires neither
     `change` nor `cancel` is caught when the window gets the focus back. */
  const pickLost = ref(false)
  let awaitingPick = false
  let pickTimer: ReturnType<typeof setTimeout> | null = null

  function clearPickWait() {
    awaitingPick = false
    if (pickTimer) clearTimeout(pickTimer)
    pickTimer = null
    window.removeEventListener('focus', onWindowFocusAfterPick)
  }

  function onWindowFocusAfterPick() {
    if (!awaitingPick) return
    if (pickTimer) clearTimeout(pickTimer)
    pickTimer = setTimeout(() => {
      if (awaitingPick) pickLost.value = true
      clearPickWait()
    }, 1000)
  }

  function openFiles() {
    pickLost.value = false
    clearPickWait()
    awaitingPick = true
    window.addEventListener('focus', onWindowFocusAfterPick)
    fileEl.value?.click()
  }

  function onPickCancel() {
    clearPickWait()
    pickLost.value = true
  }

  function onFiles(ev: Event) {
    clearPickWait()
    const input = ev.target as HTMLInputElement
    if (!input.files || input.files.length === 0) {
      pickLost.value = true
      return
    }
    pickLost.value = false
    // uploaded on send (POST /v1/files), then referenced by file_id in files[]
    picked.value = [...picked.value, ...input.files]
    input.value = ''
  }
  onBeforeUnmount(clearPickWait)

  /* A pasted screenshot or copied file is attached, as if picked with Attach.
     A paste with no files, or rich text from a document, stays a text paste. */
  function onPaste(ev: ClipboardEvent) {
    if (!pasteAttaches(ev.clipboardData)) return
    ev.preventDefault()
    pickLost.value = false
    picked.value = [...picked.value, ...filesOf(ev.clipboardData)]
  }

  /** the file dialog is open: its focus loss is not the reader leaving the box */
  const picking = () => awaitingPick

  return { picked, pickLost, openFiles, onPickCancel, onFiles, onPaste, picking }
}
