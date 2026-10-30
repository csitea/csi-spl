/* SPL-4392 (owner HUM-10, t1 d3bb743c, msgs 4491ddee and 0bd38b1f): copy a
   code block, then the page scrolls so the NEXT step's heading sits at the
   top. "Next step" = the next heading after the copied block, in document
   order, that is itself followed by a code block before the next heading of
   the same or a higher level; none (the last block) = no scroll. Both ways
   of copying count: the block's copy button and a normal copy of a
   selection inside a <pre>. The scroll runs after the copy (setTimeout 0),
   so the copy is never blocked or changed. The `-` prefix keeps Nuxt from
   registering this file as a component. */

/** one step mark in document order: a heading with its level, or a code block */
export type StepMark = { kind: 'heading'; level: number } | { kind: 'code' }

/** the index of the next step's heading after the code block at `from`, else -1 */
export function nextStepIndex(marks: readonly StepMark[], from: number): number {
  for (let i = from + 1; i < marks.length; i++) {
    const m = marks[i]
    if (m.kind === 'heading' && hasCode(marks, i, m.level)) return i
  }
  return -1
}

/* a code block under the heading at `at`, before the next heading of the same or a higher level */
function hasCode(marks: readonly StepMark[], at: number, level: number): boolean {
  for (let i = at + 1; i < marks.length; i++) {
    const m = marks[i]
    if (m.kind === 'code') return true
    if (m.level <= level) return false
  }
  return false
}

const MARKS = 'h2, h3, h4, h5, h6, pre'
/* the copy button of a code block (CodeBlock.vue) and the block around it */
const COPY_BTN = '[data-testid="code-copy"]'
const BLOCK = '.code-block'

/** a click on a code block's own buttons (Copy, Open): the read paragraph
    stays read, so the next step's block is still where the user aims */
export const onCodeTool = (e: Event) => Boolean((e.target as Element | null)?.closest?.(`${BLOCK} button`))

/* a heading's level: its section's depth in the Qto doc view (every section
   heading there is an h3), else its tag */
function levelOf(el: Element): number {
  const depth = Number((el.closest('[data-depth]') as HTMLElement | null)?.dataset.depth)
  return depth > 0 ? depth + 1 : Number(el.tagName.slice(1))
}

/** the heading of the step after the <pre> `block` inside `root`, else null */
export function nextStepHeading(root: Element, block: Element): HTMLElement | null {
  const els = [...root.querySelectorAll(MARKS)]
  const marks: StepMark[] = els.map((el) =>
    el.tagName === 'PRE' ? { kind: 'code' } : { kind: 'heading', level: levelOf(el) })
  const at = els.indexOf(block)
  const i = at < 0 ? -1 : nextStepIndex(marks, at)
  return i < 0 ? null : (els[i] as HTMLElement)
}

/* the <pre> a copy came from: a copy button's block, else the selection's anchor */
function copiedPre(e: Event): Element | null {
  if (e.type === 'click') {
    const btn = (e.target as Element | null)?.closest?.(COPY_BTN)
    return btn?.closest(BLOCK)?.querySelector('pre') ?? null
  }
  const node = document.getSelection()?.anchorNode
  const el = node && (node.nodeType === Node.ELEMENT_NODE ? (node as Element) : node.parentElement)
  return el?.closest('pre') ?? null
}

/** the article's copy and click handler: scroll to the next step once the copy is done */
export function scrollToNextStep(e: Event) {
  const root = e.currentTarget as Element | null
  const pre = copiedPre(e)
  if (!root || !pre || !root.contains(pre)) return
  /* found now: the read paragraph may turn into its textarea on the same click */
  const heading = nextStepHeading(root, pre)
  if (heading) setTimeout(() => heading.scrollIntoView({ block: 'start', behavior: 'smooth' }), 0)
}
