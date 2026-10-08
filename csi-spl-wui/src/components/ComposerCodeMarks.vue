<!-- t1 3558e416 (owner): code looks like code WHILE TYPING, as in Slack.
     A mirror of the composer's textarea, laid exactly over it, that paints a
     box behind every `inline` span and every ``` block - an unclosed block
     too, from its opener to the end of the draft (composerCodeRuns). Its own
     text is transparent and it takes no pointer, so the real textarea keeps
     the caret, selection, IME, undo, paste and the send keys; the mirror only
     follows its font, padding, size and scroll. Lazy: the composer mounts it
     only while the draft holds a backtick. -->
<template>
  <div
    ref="box"
    class="composer-code-marks"
    data-test="composer-code-marks"
    aria-hidden="true"
    :style="boxStyle"
  ><template v-for="(r, i) in runs" :key="i"><mark
    v-if="r.kind"
    class="ccm"
    :data-kind="r.kind"
    data-test="composer-code-mark"
  >{{ r.text }}</mark><template v-else>{{ r.text }}</template></template>{{ TAIL }}</div>
</template>

<script setup lang="ts">
import { composerCodeRuns } from '~/utils/composer-code-marks.mjs'

const props = defineProps<{ el: HTMLTextAreaElement | null, text: string }>()
/* a draft ending in a newline still owns that last empty line */
const TAIL = String.fromCharCode(0x200b)
const COPIED = ['fontFamily', 'fontSize', 'fontWeight', 'fontStyle', 'fontFeatureSettings', 'fontVariantLigatures', 'lineHeight', 'letterSpacing', 'wordSpacing', 'textIndent', 'textTransform', 'tabSize', 'direction', 'textAlign', 'whiteSpace', 'overflowWrap', 'wordBreak', 'paddingTop', 'paddingBottom', 'paddingLeft', 'borderTopWidth', 'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth'] as const

const box = ref<HTMLElement | null>(null)
const boxStyle = ref<Record<string, string>>({})
const runs = computed(() => composerCodeRuns(props.text))

function sync() {
  const el = props.el
  if (!el || !box.value) return
  const c = getComputedStyle(el)
  const s: Record<string, string> = {}
  for (const k of COPIED) s[k] = c[k]
  // the textarea's scrollbar narrows its text; the mirror has none
  const bar = el.offsetWidth - el.clientWidth - parseFloat(c.borderLeftWidth) - parseFloat(c.borderRightWidth)
  s.paddingRight = `${parseFloat(c.paddingRight) + Math.max(0, bar)}px`
  s.left = `${el.offsetLeft}px`
  s.top = `${el.offsetTop}px`
  s.width = `${el.offsetWidth}px`
  s.height = `${el.offsetHeight}px`
  boxStyle.value = s
  nextTick(() => { if (box.value && props.el) box.value.scrollTop = props.el.scrollTop })
}

function onScroll() {
  if (box.value && props.el) box.value.scrollTop = props.el.scrollTop
}

let ro: ResizeObserver | null = null
let mo: MutationObserver | null = null
function attach(el: HTMLTextAreaElement | null) {
  ro?.disconnect()
  mo?.disconnect()
  if (!el) return
  el.addEventListener('scroll', onScroll, { passive: true })
  ro = new ResizeObserver(sync)
  ro.observe(el)
  // the composer swaps the textarea's class (in-code: the mono font) and style
  mo = new MutationObserver(sync)
  mo.observe(el, { attributes: true, attributeFilter: ['class', 'style'] })
  sync()
}

watch(() => props.el, (el, old) => {
  old?.removeEventListener('scroll', onScroll)
  attach(el)
})
watch(() => props.text, () => nextTick(sync))
onMounted(() => attach(props.el))
onBeforeUnmount(() => {
  ro?.disconnect()
  mo?.disconnect()
  props.el?.removeEventListener('scroll', onScroll)
})
</script>

<style scoped>
.composer-code-marks {
  position: absolute;
  box-sizing: border-box;
  margin: 0;
  border-style: solid;
  border-color: transparent;
  background: transparent;
  color: transparent;
  overflow: hidden;
  pointer-events: none;
  user-select: none;
}
.ccm {
  color: transparent;
  background: var(--color-code-inline-bg);
  box-shadow: inset 0 0 0 1px var(--color-code-inline-edge);
  border-radius: var(--radius-sm);
  -webkit-box-decoration-break: clone;
  box-decoration-break: clone;
}
/* over the text, so both fills stay translucent */
.ccm[data-kind="block"] { box-shadow: inset 0 0 0 1px var(--color-border-strong); }
</style>
