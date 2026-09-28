// In-page inventory of visible rectangular surfaces and selected-state rings.
// Used by tests/e2e/rounded-corners.test.mjs.
//
// A "surface" is a visible box with its own fill, border, or shadow.
// Full-bleed chrome (the page, the 3-pane shell, the top bar, pane
// dividers, viewport dimmers) is allow-listed: those are the canvas,
// not the boxes on it. Circles (50% / pill covering the short side)
// are not rectangles.

export const INVENTORY_JS = `(() => {
  const ALLOW_CLASS = [
    'layout', 'app-frame', 'spool-shell', 'spool-main', 'feed-col',
    'sidebar', 'topic', 'live-pane', 'live-feed', 'live-rows',
    'feed-header', 'feed-body', 'top-bar', 'top-bar__start', 'top-bar__end',
    'top-bar__omnibox', 'app-corner', 'pane-divider', 'ui-dialog-backdrop',
    'composer', 'new-pill-wrap', 'older-sentinel', 'sr-only', 'visually-hidden',
    'login', 'login-wallpaper', 'login-wallpaper__drift', 'login-bar', 'login-bar__title', 'login-body', 'settings-layout', 'settings-content', 'settings-page',
    'notify-box', 'debug-panel', 'pinned-root', 'search-page', 'search-results',
    'search-group', 'search-help', 'idp', 'native-auth', 'native-auth__form',
    'native-auth__field', 'create-row', 'msg-meta', 'msg-body', 'code-head',
    'code-lines', 'code-line', 'keys__facts', 'keys__actions', 'settings__row',
    'lang-setting', 'lang-setting__row', 'user-menu__names', 'user-menu__items',
    'user-menu__who', 'composer-row', 'file-chips', 'mention-list',
  ]
  const ALLOW_TAG = new Set([
    'HTML', 'BODY', 'MAIN', 'SVG', 'PATH', 'G', 'IMG', 'VIDEO', 'CANVAS',
    'BR', 'HR', 'SCRIPT', 'STYLE', 'LINK', 'META', 'NOSCRIPT', 'HEAD',
    'TITLE', 'SLOT', 'TEMPLATE',
  ])

  function clsList(el) {
    const c = el.className
    if (!c) return []
    if (typeof c === 'string') return c.trim().split(/\\s+/).filter(Boolean)
    if (c.baseVal != null) return String(c.baseVal).trim().split(/\\s+/).filter(Boolean)
    return []
  }

  function allowReason(el, r) {
    if (el.id === '__nuxt') return 'full-bleed:#__nuxt'
    if (ALLOW_TAG.has(el.tagName)) return 'chrome:' + el.tagName
    const cls = clsList(el)
    for (const c of cls) if (ALLOW_CLASS.includes(c)) return 'full-bleed:.' + c
    if (r.width >= innerWidth - 4 && r.height >= innerHeight - 4) return 'full-bleed:viewport'
    if (r.width >= innerWidth - 4 && r.left <= 2 && r.height <= 8) return 'hairline'
    if (Math.min(r.width, r.height) <= 4) return 'hairline'
    return null
  }

  function parsePx(v) {
    const n = parseFloat(v)
    return Number.isFinite(n) ? n : 0
  }

  function radiusOf(style) {
    const corners = [
      style.borderTopLeftRadius,
      style.borderTopRightRadius,
      style.borderBottomRightRadius,
      style.borderBottomLeftRadius,
    ].map(parsePx)
    return { min: Math.min(...corners), max: Math.max(...corners), corners }
  }

  function isCircleOrPill(rad, r) {
    const short = Math.min(r.width, r.height)
    if (short <= 0) return false
    return rad.min >= short / 2 - 0.5
  }

  function visibleFill(style, parentStyle) {
    const bg = style.backgroundColor
    if (!bg || bg === 'transparent' || bg === 'rgba(0, 0, 0, 0)') return false
    if (parentStyle && bg === parentStyle.backgroundColor &&
        (!style.backgroundImage || style.backgroundImage === 'none')) return false
    return true
  }

  function visibleBorder(style) {
    const sides = ['Top', 'Right', 'Bottom', 'Left']
    return sides.some((s) => parsePx(style['border' + s + 'Width']) > 0 &&
      style['border' + s + 'Style'] !== 'none' &&
      style['border' + s + 'Color'] !== 'transparent' &&
      !/^rgba\\(0, 0, 0, 0\\)/.test(style['border' + s + 'Color']))
  }

  function isSurface(el, style, parentStyle, r) {
    if (r.width < 8 || r.height < 8) return false
    const st = style.display
    if (st === 'none' || style.visibility === 'hidden' || parseFloat(style.opacity) === 0) return false
    if (r.bottom < 0 || r.right < 0 || r.top > innerHeight || r.left > innerWidth) return false
    return visibleFill(style, parentStyle) || visibleBorder(style) ||
      (style.boxShadow && style.boxShadow !== 'none')
  }

  function selectorOf(el) {
    const cls = clsList(el).slice(0, 3).join('.')
    const test = el.getAttribute && el.getAttribute('data-test')
    return (el.tagName.toLowerCase()) +
      (el.id ? '#' + el.id : '') +
      (test ? '[data-test=' + test + ']' : '') +
      (cls ? '.' + cls : '')
  }

  const sharp = []
  const ok = []
  const allowed = []
  const all = document.querySelectorAll('body *')
  for (const el of all) {
    const r = el.getBoundingClientRect()
    const style = getComputedStyle(el)
    const parentStyle = el.parentElement ? getComputedStyle(el.parentElement) : null
    const allow = allowReason(el, r)
    const rad = radiusOf(style)
    const sel = selectorOf(el)
    if (allow) {
      allowed.push({ sel, reason: allow, radius: rad.min, w: Math.round(r.width), h: Math.round(r.height) })
      continue
    }
    if (!isSurface(el, style, parentStyle, r)) continue
    if (isCircleOrPill(rad, r)) {
      ok.push({ sel, radius: rad.min, kind: 'circle-or-pill', w: Math.round(r.width), h: Math.round(r.height) })
      continue
    }
    const row = {
      sel,
      radius: rad.min,
      corners: rad.corners,
      w: Math.round(r.width),
      h: Math.round(r.height),
      bg: style.backgroundColor,
      border: style.borderTopWidth + ' ' + style.borderTopColor,
    }
    if (rad.min < 1) sharp.push(row)
    else ok.push(row)
  }

  function parseShadows(shadow) {
    if (!shadow || shadow === 'none') return []
    const layers = []
    let depth = 0, cur = ''
    for (const ch of shadow) {
      if (ch === '(') depth++
      if (ch === ')') depth--
      if (ch === ',' && depth === 0) { layers.push(cur.trim()); cur = ''; continue }
      cur += ch
    }
    if (cur.trim()) layers.push(cur.trim())
    return layers.map((layer) => {
      const inset = /\\binset\\b/.test(layer)
      const color = (layer.match(/rgba?\\([^)]+\\)|hsla?\\([^)]+\\)|#[0-9a-fA-F]{3,8}/) || [''])[0]
      const nums = (layer.replace(/rgba?\\([^)]+\\)|hsla?\\([^)]+\\)|#[0-9a-fA-F]{3,8}/g, '')
        .match(/-?\\d+\\.?\\d*px/g) || []).map(parsePx)
      // inset dx dy blur spread
      const width = inset ? Math.abs(nums[0] || 0) + (nums[3] || 0) : (nums[3] || 0)
      return { inset, color, width, nums, layer }
    })
  }

  const SELECTED = [
    '.nav-item.active', '.msg.selected', '.topic-row.selected',
    '.search-row.active', '.settings-nav__link--active',
    '.native-auth__tab.is-active', '.lang-switcher__option--selected',
    '.locale-cbx__option--selected', '[aria-current="page"]',
  ]
  const selected = []
  const seen = new Set()
  for (const q of SELECTED) {
    for (const el of document.querySelectorAll(q)) {
      if (seen.has(el)) continue
      seen.add(el)
      const s = getComputedStyle(el)
      const colors = new Set()
      let width = 0
      const ow = parsePx(s.outlineWidth)
      if (ow > 0 && s.outlineStyle !== 'none') {
        width = Math.max(width, ow)
        colors.add(s.outlineColor)
      }
      for (const side of ['Top', 'Right', 'Bottom', 'Left']) {
        const w = parsePx(s['border' + side + 'Width'])
        const col = s['border' + side + 'Color']
        if (w > 0 && s['border' + side + 'Style'] !== 'none' &&
            col !== 'transparent' && !/^rgba\\(0, 0, 0, 0\\)/.test(col)) {
          width = Math.max(width, w)
          colors.add(col)
        }
      }
      for (const sh of parseShadows(s.boxShadow)) {
        if (sh.inset && sh.width > 0) {
          width = Math.max(width, sh.width)
          if (sh.color) colors.add(sh.color)
        }
      }
      selected.push({
        sel: selectorOf(el),
        width,
        colors: [...colors],
        outline: s.outline,
        boxShadow: s.boxShadow,
        borderInlineStart: s.borderInlineStart,
      })
    }
  }

  return {
    href: location.href,
    theme: document.documentElement.getAttribute('data-theme') || 'dark',
    viewport: { w: innerWidth, h: innerHeight },
    sharp: sharp.slice(0, 80),
    sharpCount: sharp.length,
    okCount: ok.length,
    selected,
  }
})()`
