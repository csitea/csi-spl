// The headers of a JSON read from the hub: accept JSON, and the viewer's
// bearer token when the session carries one (a cookie session has none).
export function hubJsonHeaders(token: string): Record<string, string> {
  const headers: Record<string, string> = { accept: 'application/json' }
  if (token) headers.authorization = `Bearer ${token}`
  return headers
}
