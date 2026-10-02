/**
 * P3-15: the one mock constant a live first screen reads (useLive's lobby
 * fallback). It lives apart from mock-data.mjs so the mock tenant's data
 * stays out of the live initial JS; mock-data.mjs re-exports it.
 */

/** lde mock #lobby: the welcome topic of mock-data.mjs. The real id comes from the hub / cnf. */
export const MOCK_LOBBY_TASK_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
