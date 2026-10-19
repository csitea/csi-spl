/*
 * The doc view's pictures (r14-01, out of WorkspaceDocView; owner HUM-10, t1
 * 46d9c236): each image's src resolved once, an image checked as the hub
 * checks it and uploaded, then put into a paragraph (the file picker, a paste,
 * a drop) or set as the section's image.
 */
import { nextTick, reactive, ref, type ComputedRef, type Ref } from 'vue'
import { DOC_IMAGE_MAX, DOC_IMAGE_TYPES, type DocItem, type DocSession } from '~/components/workspace-docs/-doctree-api'
import { imagePaths, picToken, setPicCaption } from '~/components/workspace-docs/-doc-pics'

type Editor = { paraEditing: Set<string>, grow: (el: HTMLTextAreaElement) => void, textOf: (id: string) => HTMLTextAreaElement | null }

type PicView = {
  props: { session: DocSession }
  busy: Ref<boolean>
  /* the preamble, then the items */
  docs: ComputedRef<DocItem[]>
  attr: (it: DocItem, k: string) => string
  commit: (it: DocItem, field: 'body', value: string) => Promise<void>
  commitAttrs: (it: DocItem, set: Record<string, string>) => Promise<void>
  fileEl: Ref<HTMLInputElement | null>
  /* the paragraph in focus (its Insert picture control shows) */
  paraFocus: Ref<string>
  editor: Editor
}

/** a picture's file: an image file of the transfer, else none */
function imageOf(list: DataTransferItemList | undefined): File | null {
  for (const x of list ?? []) {
    if (x.kind === 'file' && x.type.startsWith('image/')) return x.getAsFile()
  }
  return null
}

function dragPic(e: DragEvent) {
  if (e.dataTransfer?.types.includes('Files')) e.preventDefault()
}

type InsertPic = (it: DocItem, file: File, value: string, start: number, end: number) => Promise<void>

/** a pasted or dropped image file goes in at the textarea's cursor */
function fromTransfer(insert: InsertPic, it: DocItem, e: Event, list: DataTransferItemList | undefined) {
  const file = imageOf(list)
  if (!file) return
  e.preventDefault()
  const el = e.target as HTMLTextAreaElement
  void insert(it, file, el.value, el.selectionStart, el.selectionEnd)
}

/** the token put in place of the selection, on its own line; `at` = where the token starts */
function withToken(value: string, start: number, end: number, token: string) {
  const pre = value.slice(0, start)
  const post = value.slice(end)
  const before = pre && !pre.endsWith('\n') ? pre + '\n' : pre
  return { next: before + token + (post && !post.startsWith('\n') ? '\n' : '') + post, at: before.length }
}

/** one image checked here as the hub checks it, then uploaded: its hub path ('' = refused) */
async function upload(s: DocSession, busy: Ref<boolean>, file: File): Promise<string> {
  if (!DOC_IMAGE_TYPES.includes(file.type) || file.size > DOC_IMAGE_MAX) {
    s.error.value = 'ws_doctree.err_image'
    return ''
  }
  busy.value = true
  try {
    const up = await s.run(() => s.client.uploadImage(s.doc, file))
    if (!up) {
      if (s.error.value === 'ws_doctree.err_failed') s.error.value = 'ws_doctree.err_image'
      return ''
    }
    return up.img_http_path
  } finally {
    busy.value = false
  }
}

/** resolve each image's src once (the hub path is read with the session's credentials) */
function resolveInto(imgUrl: Record<string, string>, s: DocSession, docs: DocItem[], attr: PicView['attr']) {
  for (const it of docs) {
    for (const p of [attr(it, 'img_http_path'), ...imagePaths(it.body, s.doc)]) {
      if (p && !(p in imgUrl)) {
        imgUrl[p] = ''
        void s.client.imageSrc(p).then((u) => { imgUrl[p] = u })
      }
    }
  }
}

export function useDocPictures(v: PicView) {
  const { t } = useI18n({ useScope: 'global' })
  /* an image's hub path -> the URL the <img> shows (an object URL of the bytes) */
  const imgUrl = reactive<Record<string, string>>({})
  /* the section the file picker adds an image to */
  const imageFor = ref<DocItem | null>(null)
  /* the picture the file picker inserts: the paragraph and its text and cursor when the picker opened */
  const picFor = ref<{ it: DocItem, value: string, start: number, end: number } | null>(null)
  /* the last paragraph save, awaited before a picture is inserted on top of it */
  let saving: Promise<unknown> = Promise.resolve()
  const resolveImages = () => resolveInto(imgUrl, v.props.session, v.docs.value, v.attr)

  /** the file picker's image: a picture into a paragraph, else the section's image */
  async function onImageFile(e: Event) {
    const input = e.target as HTMLInputElement
    const file = input.files?.[0]
    const it = imageFor.value
    const pic = picFor.value
    input.value = ''
    pickCancel()
    if (!file) return
    if (pic) return insertPic(pic.it, file, pic.value, pic.start, pic.end)
    if (!it) return
    const path = await upload(v.props.session, v.busy, file)
    if (path) await v.commitAttrs(it, { img_http_path: path, img_name: v.attr(it, 'img_name') || file.name.replace(/\.[^.]+$/, '') })
  }
  /** the picker closed: nothing waits for its file */
  const pickCancel = () => { imageFor.value = null; picFor.value = null }
  /** the menu's Add image: the picker sets the section's image */
  function pickImage(it: DocItem) {
    imageFor.value = it
    v.fileEl.value?.click()
  }
  /** the Insert picture control: the picker opens, the paragraph's text and cursor kept for the insert */
  function pickPic(it: DocItem) {
    const el = v.editor.textOf(it.id)
    if (!el) return
    picFor.value = { it, value: el.value, start: el.selectionStart, end: el.selectionEnd }
    v.fileEl.value?.click()
  }
  const pastePic = (it: DocItem, e: ClipboardEvent) => fromTransfer(insertPic, it, e, e.clipboardData?.items)
  const dropPic = (it: DocItem, e: DragEvent) => fromTransfer(insertPic, it, e, e.dataTransfer?.items)

  /** upload a picture and put its token at the cursor, on its own line; the caption is then selected to type over */
  async function insertPic(it: DocItem, file: File, value: string, start: number, end: number) {
    const path = await upload(v.props.session, v.busy, file)
    if (!path) return
    await saving
    const stem = file.name.replace(/\.[^.]+$/, '').trim()
    const token = picToken(stem && stem !== 'image' ? stem : t('ws_doctree.picture_caption'), path)
    const { next, at } = withToken(value, start, end, token)
    v.editor.paraEditing.add(it.id)
    await v.commit(it, 'body', next)
    resolveImages()
    await nextTick()
    const el = v.editor.textOf(it.id)
    if (!el) return
    el.value = it.body
    v.editor.grow(el)
    el.focus()
    el.setSelectionRange(at + 2, at + token.indexOf(']('))
  }

  /** a figure's caption edited in place: the k-th picture's token rewritten */
  const commitCaption = (it: DocItem, k: number, caption: string) => v.commit(it, 'body', setPicCaption(it.body, v.props.session.doc, k, caption))
  /** a paragraph left: its text saved, then it reads again (rendered, never the old text first) unless
      the picker is about to insert into it or it was opened again meanwhile */
  function leavePara(it: DocItem, el: HTMLTextAreaElement) {
    const done = v.commit(it, 'body', el.value)
    saving = done
    if (picFor.value?.it.id === it.id) return
    v.paraFocus.value = ''
    void done.finally(() => {
      if (v.paraFocus.value !== it.id) v.editor.paraEditing.delete(it.id)
    })
  }

  return { imgUrl, resolveImages, onImageFile, pickCancel, pickImage, pickPic, pastePic, dragPic, dropPic, leavePara, commitCaption }
}
