// Glyph path data for UiIcon.vue (lucide-style, 24×24), the subset the WUI
// uses. Path-only so SSR output is plain markup — no <circle>/<rect>, no
// v-html. Dots are small filled path blobs, never hairlines that vanish at 18px.

/** Stroke d, or a filled disc. */
export type UiIconPath = string | { readonly d: string; readonly fill: true }

/** Path data per glyph. */
export const UI_ICON_PATHS = {
  x: ["M21 3 3 21", "M3 3l18 18"],
  search: ["M11 3a8 8 0 1 0 0 16a8 8 0 1 0 0-16z", "m21 21-4.3-4.3"],
  check: ["M22 4.5 8.25 18.25l-6.25 -6.25"],
  // Error/warning marker, so an error notice does not signal by colour alone.
  "alert-triangle": [
    "m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3",
    "M12 9v4",
    { d: "M12 15.9a1.1 1.1 0 1 1 0 2.2 1.1 1.1 0 1 1 0-2.2z", fill: true },
  ],
  copy: [
    "M11 9h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H11a2 2 0 0 1-2-2V11a2 2 0 0 1 2-2z",
    "M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1",
  ],
  // Top-right user control (UserMenu.vue): signed-out silhouette + menu items.
  user: [
    "M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2",
    "M12 3a4 4 0 1 1 0 8 4 4 0 1 1 0-8z",
  ],
  settings: [
    "M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z",
    "M12 9a3 3 0 1 1 0 6 3 3 0 1 1 0-6z",
  ],
  "log-in": ["M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4", "m10 17 5-5-5-5", "M15 12H3"],
  "log-out": ["M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4", "m16 17 5-5-5-5", "M21 12H9"],
  // "Open" affordance (lucide square-arrow-out-up-right): box + arrow out.
  // One glyph for every Open control — pane or dedicated page.
  open: [
    "M21 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h6",
    "m21 3-9 9",
    "M15 3h6v6",
  ],
  // Theme toggle: destination glyph. lucide sun (circle as a path) and
  // lucide moon (crescent / half-moon). Path-only — never a circle or rect element.
  sun: [
    "M12 8a4 4 0 1 0 0 8 4 4 0 1 0 0-8z",
    "M12 2v2",
    "M12 20v2",
    "m4.93 4.93 1.41 1.41",
    "m17.66 17.66 1.41 1.41",
    "M2 12h2",
    "M20 12h2",
    "m6.34 17.66-1.41 1.41",
    "m19.07 4.93-1.41 1.41",
  ],
  moon: [
    "M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z",
  ],
  // The sidebar's one "add a channel" control, next to the Channels heading.
  plus: ["M12 5v14", "M5 12h14"],
  // Left-strip tab: direct messages (lucide "messages", two bubbles).
  messages: [
    "M14 9a2 2 0 0 1-2 2H6l-4 4V4a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2z",
    "M18 9h2a2 2 0 0 1 2 2v11l-4-4h-6a2 2 0 0 1-2-2v-1",
  ],
  // Left-strip tab: channels (lucide hash).
  hash: ["M4 9h16", "M4 15h16", "M10 3 8 21", "M16 3 14 21"],
  // Left-strip tab: topics (lucide rows-3).
  list: ["M3 6h18", "M3 12h18", "M3 18h18"],
  // Row menu on a left-pane object. Three bars, separate from the topics tab.
  menu: ["M4 6h16", "M4 12h16", "M4 18h16"],
  // Left-strip tab: the live flow (lucide waves).
  waves: [
    "M2 6c.6.5 1.2 1 2.5 1C7 7 7 5 9.5 5c2.6 0 2.4 2 5 2 2.5 0 2.5-2 5-2 1.3 0 1.9.5 2.5 1",
    "M2 12c.6.5 1.2 1 2.5 1 2.5 0 2.5-2 5-2 2.6 0 2.4 2 5 2 2.5 0 2.5-2 5-2 1.3 0 1.9.5 2.5 1",
    "M2 18c.6.5 1.2 1 2.5 1 2.5 0 2.5-2 5-2 2.6 0 2.4 2 5 2 2.5 0 2.5-2 5-2 1.3 0 1.9.5 2.5 1",
  ],
  // CLE-3433: the notification control in the collapsed 72px sidebar rail,
  // where its label does not fit and must not be shown as wrapped text.
  bell: [
    "M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9",
    "M13.73 21a2 2 0 0 1-3.46 0",
  ],
  // Row menu: mute is the bell with a slash; unmute is the plain bell.
  "bell-off": [
    "M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9",
    "M13.73 21a2 2 0 0 1-3.46 0",
    "M2 2 22 22",
  ],
  // Row menu: block (a circle with a slash) and unblock (person plus a check).
  ban: [
    "M12 2a10 10 0 1 0 0 20 10 10 0 1 0 0-20z",
    "M4.9 4.9 19.1 19.1",
  ],
  "user-check": [
    "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2",
    "M9 11a4 4 0 1 0 0-8 4 4 0 1 0 0 8z",
    "m16 11 2 2 4-4",
  ],
  // Row menu: pin a person to the top of the list.
  pin: [
    "M12 17v5",
    "M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z",
  ],
  // Row menu: remove a person from the tenant.
  trash: [
    "M3 6h18",
    "M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6",
    "M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2",
    "M10 11v6",
    "M14 11v6",
  ],
} as const

export type UiIconName = keyof typeof UI_ICON_PATHS
