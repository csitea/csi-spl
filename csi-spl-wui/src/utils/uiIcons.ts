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
  // CLE-3433: the notification control in the collapsed 72px sidebar rail,
  // where its label does not fit and must not be shown as wrapped text.
  bell: [
    "M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9",
    "M13.73 21a2 2 0 0 1-3.46 0",
  ],
} as const

export type UiIconName = keyof typeof UI_ICON_PATHS
