// WUI/utils/realm-hours-api.mjs
// Spec 118 T005: API client for realm hours routes.
// Routes:
// - GET /v1/me/realm/hours?from=<date>&to=<date>
// - PUT /v1/me/realm/hours
// - GET /v1/me/realm/targets?workspace=<id>&q=<query>

/**
 * @typedef {Object} RealmHoursResponse
 * @property {string} tz - IANA timezone (e.g., 'UTC')
 * @property {string} tz_source - Source of timezone (e.g., 'profile')
 * @property {string} from - Start date in YYYY-MM-DD format
 * @property {string} to - End date in YYYY-MM-DD format
 * @property {Array<{id: string, name: string, state: string}>} workspaces - Workspaces in the window
 * @property {Array<Object>} days - PersonalDay objects (see hours-across.mjs)
 * @property {Object} totals - Totals for the window
 * @property {boolean} incomplete - True if any workspace was unavailable
 * @property {Array<{kind: string, minutes: number, window: string}>} limits - Person's limits
 */

/**
 * @typedef {Object} RealmHoursEntry
 * @property {string} workspace - Workspace ID
 * @property {string} op_id - Operation ID (for idempotency)
 * @property {string} day - Date in YYYY-MM-DD format
 * @property {string} target - Target ID
 * @property {number} [minutes] - Minutes (if no start/end)
 * @property {string} [start] - RFC 3339 UTC timestamp (if start/end)
 * @property {string} [end] - RFC 3339 UTC timestamp (if start/end)
 * @property {string} [note] - Optional note
 */

/**
 * @typedef {Object} RealmHoursWriteResponse
 * @property {Array<{op_id: string, workspace: string, status: string, detail?: string, replayed?: boolean}>} rows
 * @property {Array<{op_id: string, error: string}>} bad_row
 * @property {Array<{workspace: string, error: string}>} unavailable
 */

/**
 * @typedef {Object} RealmTarget
 * @property {string} target - Target ID
 * @property {string} label - Display label
 * @property {string} kind - Target kind (e.g., 'job', 'topic', 'channel', 'meeting', 'workspace')
 */

/**
 * @typedef {Object} RealmTargetsResponse
 * @property {string} workspace - Workspace ID
 * @property {RealmTarget[]} targets - Array of targets
 */

/**
 * Fetch realm hours for a date range.
 * @param {string} from - Start date in YYYY-MM-DD format
 * @param {string} to - End date in YYYY-MM-DD format
 * @returns {Promise<RealmHoursResponse>} Realm hours response
 */
export async function fetchRealmHours(from, to) {
  const url = new URL('/v1/me/realm/hours', window.location.origin);
  url.searchParams.append('from', from);
  url.searchParams.append('to', to);

  const response = await fetch(url, {
    method: 'GET',
    credentials: 'include',
    headers: {
      'Accept': 'application/json'
    }
  });

  if (!response.ok) {
    throw new Error(`Failed to fetch realm hours: ${response.status} ${response.statusText}`);
  }

  return await response.json();
}

/**
 * Save realm hours entries.
 * @param {RealmHoursEntry[]} entries - Array of entries to save
 * @returns {Promise<RealmHoursWriteResponse>} Write response
 */
export async function saveRealmHours(entries) {
  const response = await fetch('/v1/me/realm/hours', {
    method: 'PUT',
    credentials: 'include',
    headers: {
      'Content-Type': 'application/json',
      'Accept': 'application/json'
    },
    body: JSON.stringify(entries)
  });

  if (!response.ok) {
    throw new Error(`Failed to save realm hours: ${response.status} ${response.statusText}`);
  }

  return await response.json();
}

/**
 * Fetch targets for a workspace.
 * @param {string} workspace - Workspace ID
 * @param {string} [query] - Optional search query
 * @returns {Promise<RealmTargetsResponse>} Targets response
 */
export async function fetchRealmTargets(workspace, query = '') {
  const url = new URL('/v1/me/realm/targets', window.location.origin);
  url.searchParams.append('workspace', workspace);
  if (query) url.searchParams.append('q', query);

  const response = await fetch(url, {
    method: 'GET',
    credentials: 'include',
    headers: {
      'Accept': 'application/json'
    }
  });

  if (!response.ok) {
    throw new Error(`Failed to fetch realm targets: ${response.status} ${response.statusText}`);
  }

  return await response.json();
}