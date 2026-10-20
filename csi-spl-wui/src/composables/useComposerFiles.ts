// r13-03: the composer's attachments, moved out of MessageComposer.vue: the
// paperclip's picker and a pasted file (useFileAttach, shared with the issue
// boxes), the picked pictures' thumbnails and a file dropped on the page.
import type { Ref } from 'vue'
import { isPreviewableImage, readDataUrl } from '~/utils/file-preview'
import { carriesFiles, filesOf } from '~/utils/transfer-files'
import { useFileAttach } from '~/composables/useFileAttach'
import type { ComposerProps } from '~/composables/composerProps'

interface FilesOpts {
  fileEl: Ref<HTMLInputElement | null>
  props: ComposerProps
  focusInput: () => void
}

/* a picked picture shows a thumbnail before it is sent (a data: URL: the
   deployed CSP admits no blob:); every other file shows its type icon */
function useThumbs(picked: Ref<File[]>) {
  const thumbs = shallowRef(new Map<File, string>())
  watch(picked, async (files) => {
    const next = new Map<File, string>()
    for (const f of files) {
      const had = thumbs.value.get(f)
      if (had) next.set(f, had)
      else if (isPreviewableImage(f.name, f.size)) next.set(f, await readDataUrl(f))
    }
    thumbs.value = next
  }, { deep: true })
  return thumbs
}

/* A file dropped anywhere on the page is attached to the Omnibox. Without
   this the browser opens the dropped file and leaves the app. Only the one
   global Omnibox listens, so a drop is attached once. */
function useWindowDrop(o: FilesOpts, attach: ReturnType<typeof useFileAttach>) {
  const { props } = o
  function onWindowDragOver(ev: DragEvent) {
    if (!carriesFiles(ev.dataTransfer)) return
    ev.preventDefault()
    if (ev.dataTransfer) ev.dataTransfer.dropEffect = 'copy'
  }
  function onWindowDrop(ev: DragEvent) {
    if (!carriesFiles(ev.dataTransfer)) return
    ev.preventDefault()
    const files = filesOf(ev.dataTransfer)
    if (!files.length) return
    attach.pickLost.value = false
    attach.picked.value = [...attach.picked.value, ...files]
    o.focusInput()
  }
  onMounted(() => {
    if (!props.global) return
    window.addEventListener('dragover', onWindowDragOver)
    window.addEventListener('drop', onWindowDrop)
  })
  onBeforeUnmount(() => {
    window.removeEventListener('dragover', onWindowDragOver)
    window.removeEventListener('drop', onWindowDrop)
  })
}

export function useComposerFiles(o: FilesOpts) {
  const attach = useFileAttach(o.fileEl)
  useWindowDrop(o, attach)
  return { ...attach, thumbs: useThumbs(attach.picked) }
}
