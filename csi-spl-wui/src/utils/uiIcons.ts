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
  // CLE-34994: the theme picker's button (lucide palette). The paint dots
  // are filled path discs, never <circle>, so they survive at 18px.
  palette: [
    "M12 22a1 1 0 0 1 0-20 10 9 0 0 1 10 9 5 5 0 0 1-5 5h-2.25a1.75 1.75 0 0 0-1.4 2.8l.3.4a1.75 1.75 0 0 1-1.4 2.8z",
    { d: "M13.5 5.4a1.1 1.1 0 1 1 0 2.2 1.1 1.1 0 1 1 0-2.2z", fill: true },
    { d: "M17.5 9.4a1.1 1.1 0 1 1 0 2.2 1.1 1.1 0 1 1 0-2.2z", fill: true },
    { d: "M6.5 10.4a1.1 1.1 0 1 1 0 2.2 1.1 1.1 0 1 1 0-2.2z", fill: true },
    { d: "M8.5 5.4a1.1 1.1 0 1 1 0 2.2 1.1 1.1 0 1 1 0-2.2z", fill: true },
  ],
  // The sidebar's one "add a channel" control, next to the Channels heading.
  plus: ["M12 5v14", "M5 12h14"],
  // Deadline picker (owner, topic 778ad161): opens the month grid.
  calendar: [
    "M5 4h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z",
    "M16 2v4",
    "M8 2v4",
    "M3 10h18",
  ],
  // Remove a person or an agent from a channel (Properties, People tab).
  minus: ["M5 12h14"],
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
  // Left-strip tab: the admin's Users (lucide users), CLE-34969.
  users: [
    "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2",
    "M9 3a4 4 0 1 1 0 8 4 4 0 1 1 0-8z",
    "M22 21v-2a4 4 0 0 0-3-3.87",
    "M16 3.13a4 4 0 0 1 0 7.75",
  ],
  // CLE-34991: the tenant drop box's glyph (lucide building-2), in place of
  // the visible "Tenant" caption.
  building: [
    "M6 22V4a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v18z",
    "M6 12H4a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h2",
    "M18 9h2a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-2",
    "M10 6h4",
    "M10 10h4",
    "M10 14h4",
    "M10 18h4",
  ],
  // Left-strip tab: the personal Event log, after Flow (lucide history), CLE-34990.
  history: [
    "M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8",
    "M3 3v5h5",
    "M12 7v5l4 2",
  ],
  // CLE-3433: the notification control in the collapsed 72px sidebar rail,
  // where its label does not fit and must not be shown as wrapped text.
  // chime on/off (owner, 2026-09-26): lucide "music" - two notes on a beam
  music: [
    "M9 18V5l12-2v13",
    "M6 15a3 3 0 1 0 0 6a3 3 0 1 0 0-6",
    "M18 13a3 3 0 1 0 0 6a3 3 0 1 0 0-6",
  ],
  // chime off: the same two notes with bell-off's own slash path, so the
  // strike has the bell's stroke width and colour (owner, SPL-998).
  "music-off": [
    "M9 18V5l12-2v13",
    "M6 15a3 3 0 1 0 0 6a3 3 0 1 0 0-6",
    "M18 13a3 3 0 1 0 0 6a3 3 0 1 0 0-6",
    "M2 2 22 22",
  ],
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
  // Message menu, Open parent section (lucide corner-up-left): back up to
  // the channel or DM the thread lives in. CLE-34996.
  parent: [
    "m9 14-5-5 5-5",
    "M20 20v-7a4 4 0 0 0-4-4H4",
  ],
  // Message menu: two messages become one (a Y joining downward).
  merge: [
    "M8 4v6",
    "M16 4v6",
    "M8 10h8",
    "M12 10v10",
  ],
  // Add an emoji to a message (lucide smile). Path-only, like the rest.
  smile: [
    "M12 22c5.523 0 10-4.477 10-10S17.523 2 12 2 2 6.477 2 12s4.477 10 10 10z",
    "M8 14s1.5 2 4 2 4-2 4-2",
    { d: "M9 9.1a1.1 1.1 0 1 1 0 2.2 1.1 1.1 0 1 1 0-2.2z", fill: true },
    { d: "M15 9.1a1.1 1.1 0 1 1 0 2.2 1.1 1.1 0 1 1 0-2.2z", fill: true },
  ],
  // Message menu: edit this message (lucide pencil). Path-only.
  pencil: [
    "M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z",
    "m15 5 4 4",
  ],
  // Row menu: remove a person from the tenant.
  trash: [
    "M3 6h18",
    "M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6",
    "M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2",
    "M10 11v6",
    "M14 11v6",
  ],
  // SPL-983 (spec 041): the owner asked for Gmail's archive glyph (Material
  // Symbols "archive": a tray under a lid, an arrow going in). Stroke-drawn so
  // it matches the rest of the set. Also the left-rail Archive entry.
  archive: [
    "M4 3h16a1 1 0 0 1 1 1v3a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z",
    "M5 8v11a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8",
    "M12 11v6",
    "m9 14 3 3 3-3",
  ],
  // Unarchive (Material "unarchive"): the same tray, the arrow going out.
  unarchive: [
    "M4 3h16a1 1 0 0 1 1 1v3a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z",
    "M5 8v11a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8",
    "M12 17v-6",
    "m9 14 3-3 3 3",
  ],
  // Delete a whole topic (Material "delete"): a plain can with its lid.
  delete: [
    "M4 6h16",
    "M9 6V4h6v2",
    "M6 6l1 14a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1l1-14",
  ],
  // Attach control (SPL-953): lucide paperclip. The button shows only this glyph.
  paperclip: [
    "m16 6-8.414 8.586a2 2 0 0 0 2.829 2.829l8.414-8.586a4 4 0 1 0-5.657-5.657l-8.379 8.551a6 6 0 1 0 8.485 8.485l8.379-8.551",
  ],
  // SPL-991 phone composer: take a photo (lucide camera).
  camera: [
    "M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3l-2.5-3z",
    "M12 10a3 3 0 1 1 0 6 3 3 0 1 1 0-6z",
  ],
  // SPL-991 long-press sheet: Reply (lucide reply) and Kind (lucide tag).
  reply: ["M20 18v-2a4 4 0 0 0-4-4H4", "m9 17-5-5 5-5"],
  tag: [
    "M12.586 2.586A2 2 0 0 0 11.172 2H4a2 2 0 0 0-2 2v7.172a2 2 0 0 0 .586 1.414l8.704 8.704a2.426 2.426 0 0 0 3.42 0l6.58-6.58a2.426 2.426 0 0 0 0-3.42z",
    { d: "M7.5 6.4a1.1 1.1 0 1 1 0 2.2 1.1 1.1 0 1 1 0-2.2z", fill: true },
  ],
  // Attachment of no known type (lucide file).
  "file": [
    "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z",
    "M14 2v4a2 2 0 0 0 2 2h4",
  ],
  // Attachment: a document or a PDF (lucide file-text).
  "file-text": [
    "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z",
    "M14 2v4a2 2 0 0 0 2 2h4",
    "M10 9H8",
    "M16 13H8",
    "M16 17H8",
  ],
  // Attachment: a spreadsheet (lucide file-spreadsheet).
  "file-spreadsheet": [
    "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z",
    "M14 2v4a2 2 0 0 0 2 2h4",
    "M8 13h2",
    "M14 13h2",
    "M8 17h2",
    "M14 17h2",
  ],
  // Attachment: a slide deck.
  "file-slides": [
    "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z",
    "M14 2v4a2 2 0 0 0 2 2h4",
    "M8 12h8v5H8z",
  ],
  // Attachment: a picture that does not preview.
  "file-image": [
    "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z",
    "M14 2v4a2 2 0 0 0 2 2h4",
    "M10 10a1.5 1.5 0 1 1 0 3 1.5 1.5 0 1 1 0-3z",
    "m20 17-3-3-8 8",
  ],
  // Attachment: an archive (zip, tar, ...).
  "file-archive": [
    "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z",
    "M14 2v4a2 2 0 0 0 2 2h4",
    "M10 7V6",
    "M10 12v-2",
    "M10 17v-2",
  ],
  // Attachment: source code or structured text (lucide file-code).
  "file-code": [
    "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z",
    "M14 2v4a2 2 0 0 0 2 2h4",
    "m10 12-2 2 2 2",
    "m14 16 2-2-2-2",
  ],
  // Attachment: audio or video.
  "file-media": [
    "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z",
    "M14 2v4a2 2 0 0 0 2 2h4",
    "m10 11 5 3-5 3z",
  ],
  // Issues rail: a circle with a centre dot (Linear), third tab. GRK-3519.
  issues: [
    "M12 3a9 9 0 1 0 0 18 9 9 0 1 0 0-18z",
    { d: "M12 9.2a2.8 2.8 0 1 1 0 5.6 2.8 2.8 0 1 1 0-5.6z", fill: true },
  ],
  // SPL-952: the message kind badges (KindBadge.vue, utils/msg-kind.mjs).
  // note: three writing lines, no page and no folded corner.
  "kind-note": ["M6 7h12", "M6 12h12", "M6 17h8"],
  // task: a hammer and a screwdriver, crossed.
  "kind-task": [
    "M13.3 5.1 18.9 10.7 16.7 12.9 11.1 7.3z",
    "M4 20l9.9-9.9",
    "M15.8 13.2 20.8 18.2 18.2 20.8 13.2 15.8z",
    "M14.5 14.5 4 4",
  ],
  // blocker: a stop sign struck through (lucide octagon + a slash).
  "kind-blocker": [
    "M2.586 16.726A2 2 0 0 1 2 15.312V8.688a2 2 0 0 1 .586-1.414l4.688-4.688A2 2 0 0 1 8.688 2h6.624a2 2 0 0 1 1.414.586l4.688 4.688A2 2 0 0 1 22 8.688v6.624a2 2 0 0 1-.586 1.414l-4.688 4.688a2 2 0 0 1-1.414.586H8.688a2 2 0 0 1-1.414-.586z",
    "M5 19 19 5",
  ],
  // msg: a plain speech bubble (lucide message-square).
  "kind-msg": ["M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"],
  // result: a check in a circle (lucide circle-check).
  "kind-result": ["M12 2a10 10 0 1 0 0 20 10 10 0 1 0 0-20z", "m8.5 12 2.5 2.5 4.5-4.5"],
  // reject: an x in a circle (lucide circle-x).
  "kind-reject": ["M12 2a10 10 0 1 0 0 20 10 10 0 1 0 0-20z", "m15 9-6 6", "m9 9 6 6"],
  // Card height modes (CardClipControl, SPL-941): one line / a clipped
  // paragraph / the whole card.
  "clip-titles": ["M4 12h16"],
  "clip-rows": ["M4 5h16", "M4 9.5h16", "M4 14h16", "M4 18.5h10"],
  "clip-full": ["M12 3v18", "m8 7 4-4 4 4", "m8 17 4 4 4-4"],
  // The omnibox's GO (SPL-977): a filled play triangle, sends or runs /search.
  go: [{ d: "M7 4.6v14.8a1 1 0 0 0 1.5.86l12-7.4a1 1 0 0 0 0-1.72l-12-7.4A1 1 0 0 0 7 4.6z", fill: true }],
  // Add a subtask (SPL-974): a tree (trunk + two children) with a plus.
  "subtask-add": ["M5 3v13a2 2 0 0 0 2 2h5", "M5 9h5", "M18 4v8", "M14 8h8", "M15 18h5"],
  // Left panel order (SPL-979): move one up / down, and the drag grip.
  "chevron-up": ["m18 15-6-6-6 6"],
  "chevron-down": ["m6 9 6 6 6-6"],
  // Back one level on the phone top bar (SPL-990); rtl mirrors it in CSS.
  "chevron-left": ["m15 18-6-6 6-6"],
  grip: [{ d: "M9 3.7a1.3 1.3 0 1 1 0 2.6 1.3 1.3 0 1 1 0-2.6z", fill: true }, { d: "M9 10.7a1.3 1.3 0 1 1 0 2.6 1.3 1.3 0 1 1 0-2.6z", fill: true }, { d: "M9 17.7a1.3 1.3 0 1 1 0 2.6 1.3 1.3 0 1 1 0-2.6z", fill: true }, { d: "M15 3.7a1.3 1.3 0 1 1 0 2.6 1.3 1.3 0 1 1 0-2.6z", fill: true }, { d: "M15 10.7a1.3 1.3 0 1 1 0 2.6 1.3 1.3 0 1 1 0-2.6z", fill: true }, { d: "M15 17.7a1.3 1.3 0 1 1 0 2.6 1.3 1.3 0 1 1 0-2.6z", fill: true }],
} as const

export type UiIconName = keyof typeof UI_ICON_PATHS
