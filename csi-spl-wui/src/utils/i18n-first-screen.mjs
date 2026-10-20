// The first screen of the WUI, for the catalogue split (perf round 3, P3-06).
//
// The build (src/node/i18n/split-catalogue.mjs) puts every message these pages
// can show, with everything they reach, into the core catalogue that loads
// with the entry. Every other message goes to a second catalogue per locale
// that src/plugins/i18n-more.client.ts loads before any other page and when
// the browser is idle. Shared by both, so the two can never disagree.

/** Nuxt route name (without the `___<locale>` suffix) -> its page file under src/. */
export const FIRST_SCREEN_PAGES = {
  index: "pages/index.vue",
  lobby: "pages/lobby.vue",
  login: "pages/login.vue",
  "t-task_id": "pages/t/[task_id].vue",
  "channel-name": "pages/channel/[name].vue",
  "dm-peer": "pages/dm/[peer].vue",
}

/**
 * Components the first screen mounts only behind a gate that the loader
 * awaits, so their strings can wait in the second catalogue: file -> the gate.
 */
export const ON_DEMAND_COMPONENTS = {
  // app.vue mounts it once ?settings=<section> is in the address.
  "components/SettingsDialog.vue": "settings",
  // spec 096: both render once the second catalogue is merged (te() of their keys)
  "components/StatusPicker.vue": "idle",
  "components/ComposerStatusLine.vue": "idle",
  // spec 116 T3: the sign-in page shows it once GET /v1/demo answered AND the
  // second catalogue is merged (te('demo.intro.title')); its ~0.5 KB of text
  // stays off the first download of every first-screen page (ci_home_gzip_kb).
  "components/DemoIntro.vue": "idle",
  // SPL-1560: the attachment X and its confirm; FileAttachment mounts it once
  // te('feed.file_remove.label') holds, so the feed's first paint is unchanged
  "components/AttachmentRemoveX.vue": "idle",
  // SPL-1637: a ```poll form renders once te('poll.chat') holds (PollBody);
  // until then it shows as its fence text, so first paint is unchanged
  "components/PollBody.vue": "idle",
  "components/PollForm.vue": "idle",
  // SPL-1833: a failed search's plain sentence + Try again; it says the core
  // "Something went wrong" until its own keys are merged
  "components/SearchErrorNotice.vue": "idle",
  // SPL-1839: every other screen's plain error sentence + Try again, and the
  // snackbar row; it says the core "Something went wrong" until merged
  "components/PlainErrorNotice.vue": "idle",
  // SPL-1994: the hourglass on a post waiting for an agent; it renders once
  // te('await_reply.spin') holds, so first paint is unchanged
  "components/AwaitReply.vue": "idle",
  // SPL-2141: an empty channel's invitation to post; it says the core
  // "No messages yet." until its own strings are merged (a key literal here
  // would pull it into core)
  "components/FeedEmpty.vue": "idle",
  // SPL-2143: the composer's "Draft saved" line and its Clear; it renders
  // once its own strings are merged, so first paint is unchanged (a key
  // literal here would pull it into core)
  "components/ComposerDraftState.vue": "idle",
  // SPL-2145: the tablet channel strip names its expand button by the core
  // "Channels" until its own string is merged (a key literal here would
  // pull it into core)
  "components/TabletStrip.vue": "idle",
  // SPL-2149: the offline strip renders once its own strings are merged
  // (te()); app.vue mounts it only offline, so first paint is unchanged
  "components/OfflineBanner.vue": "idle",
}

/** True when the route renders a first-screen page (its strings are all in core). */
export function isFirstScreenRoute(route) {
  const name = typeof route?.name === "string" ? route.name.split("___")[0] : ""
  return Object.prototype.hasOwnProperty.call(FIRST_SCREEN_PAGES, name)
}
