/**
 * Phone thread end-jump (owner topic 639b04df).
 *
 * A long reply thread shows one round arrow. "Bottom" is the newest end:
 * the visual bottom when message order is newest-last, the visual top when
 * it is newest-first. Away from that end the arrow jumps to it and hides
 * once the reader is there. At that end the same button points the other
 * way, at the oldest end. A thread that fits in the view shows nothing.
 * Pure; LiveFeed applies it on a phone thread only.
 */
import { distanceFromBottom, NEAR_BOTTOM_PX, NEAR_TOP_PX } from './scroll-anchor.mjs'

const NONE = { show: '', dir: '', top: 0 }

/**
 * @param {{ scrollTop?: number, scrollHeight?: number, clientHeight?: number, newestLast?: boolean }} m
 * @returns {{ show: '' | 'newest' | 'oldest', dir: '' | 'up' | 'down', top: number }}
 */
export function threadJumpState({ scrollTop = 0, scrollHeight = 0, clientHeight = 0, newestLast = false } = {}) {
  if (clientHeight < 1) return { ...NONE }
  const near = newestLast ? NEAR_BOTTOM_PX : NEAR_TOP_PX
  if (scrollHeight - clientHeight <= near) return { ...NONE }
  const fromNewest = newestLast
    ? distanceFromBottom({ top: scrollTop, height: scrollHeight, client: clientHeight })
    : scrollTop
  if (fromNewest <= near) {
    return newestLast
      ? { show: 'oldest', dir: 'up', top: 0 }
      : { show: 'oldest', dir: 'down', top: scrollHeight }
  }
  return newestLast
    ? { show: 'newest', dir: 'down', top: scrollHeight }
    : { show: 'newest', dir: 'up', top: 0 }
}
