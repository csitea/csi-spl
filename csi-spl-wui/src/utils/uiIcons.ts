// Glyph path data for UiIcon.vue (lucide-style, 24×24), the subset the WUI
// uses. Path-only so SSR output is plain markup — no <circle>/<rect>, no
// v-html. Dots are small filled path blobs, never hairlines that vanish at 18px.

/** Stroke d, or a filled disc. */
export type UiIconPath = string | { readonly d: string; readonly fill: true }

/** Path data per glyph. */
export const UI_ICON_PATHS = {
  x: ["M21 3 3 21", "M3 3l18 18"],
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
} as const

export type UiIconName = keyof typeof UI_ICON_PATHS
