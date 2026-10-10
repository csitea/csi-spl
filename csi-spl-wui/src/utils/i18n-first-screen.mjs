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
}

/** True when the route renders a first-screen page (its strings are all in core). */
export function isFirstScreenRoute(route) {
  const name = typeof route?.name === "string" ? route.name.split("___")[0] : ""
  return Object.prototype.hasOwnProperty.call(FIRST_SCREEN_PAGES, name)
}
