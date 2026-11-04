# API_NOTES — M0 feasibility results

The REST/SSE/webchat results below were first measured with a personal API key (hosts anonymized; no credential is stored in the repo). The app now signs in only with OAuth (see "Sign-in: OAuth 2.1 + PKCE" at the end); re-running every row with an OAuth token is pending the test hosts (see "Still to verify live").

## Base URLs (differs from the task document)
- The "API Base URL" saved with the key was the web console address. It is not the API.
- The real API base is the console's API host plus `/v1` (example: `https://api.example.test/v1`, so `/v1/me`, `/v1/orgs`). Not `/api/v1`: that path 404s. OpenAPI 3.1 is at `{API_BASE}/openapi.json` (307 paths).
- The console page embeds the API host, relay host and auth host. A user who pastes the console URL cannot be told from an API URL, so the app should accept a base URL, check `GET {base}/me`, and show "That address doesn't look right." on non-JSON replies.
- Requests with no `User-Agent` header can get 403 from the edge. Send a normal one.

## Results
| Item | Result |
|---|---|
| `GET /me` | 200: `userId, email, name, picture, pictureCustom, pictureUploadEnabled`. No org in the reply. |
| `GET /orgs` | 200: the key's organizations: `id, name, slug, role, memberCount, daemonCount, iconUrl...`. The test user belongs to several orgs, so the key is not limited to one org here. The app must pick the org (see gaps). |
| `GET /orgs/{org}/agents` | 200: array with `id, name, displayName, status (active/inactive), ahpWebchat, placementReady, daemonId, runtime, model, chatActions...` |
| `GET /orgs/{org}/sessions` | 200: `{conversations[{key, platform, channel, thread, sessions[], memberSessionIds[]}], total, nextCursor, orgHasSessions, accessSyncDegraded, accessIssues[]}`. Session rows have `sessionId, sessionKey{platform,channel,thread}, agentId, agentName, title, status, lastActivityAt, threadUrl, activityState, visibility, triggeredBy...`. Platforms seen: hook, slack, webchat, dream. `threadUrl` gives the "open in original platform" link. |
| `view=flat&activityState=awaiting_permission&limit=200` | 200: `{sessions[], total, nextCursor, ...}`. Empty at test time (nothing pending). |
| `GET /sessions/{id}/messages?limit=` | 200: `{sessionId, messages[{seq, sender, ts, eventTimeUs, kind, ...}], nextCursor, liveCursor, liveMore}`. Unknown id gives 404. |
| `GET /agents/{id}/permission-requests` | 200 `{requests:[]}` (one agent returned 500 once — treat 5xx as "hide and retry later"). |
| `GET /sessions/{id}/permission-requests` | 200 `{requests:[]}`. Per OpenAPI: webchat conversations and the tasks they started; 409 `DAEMON_FEATURE_MISSING` when the agent's machine can't narrow by conversation. |
| Decision | `POST /agents/{id}/permission-requests/{requestId}/decision` and `POST /sessions/{sessionId}/permission-requests/{requestId}/decision` (method is POST, not PUT). NOT yet exercised: no pending request existed. Needs a live approval to verify the body and option ids. |
| SSE `GET /orgs/{org}/stream` | Connects, answers `: connected`. No events seen during the short window (no activity). |
| Webchat token | `POST /agents/{id}/webchat/token {"protocol":"legacy"}` → 200 `{protocol, token, relayUrl, conversationId, expiresAt}`. Token lives about 5 minutes. |
| Webchat WebSocket | `wss://{relay}/webchat?token=...&conversation_id=...` → 101. First server frame `ready{conversationId, agentId, features, participants}`. Send `{"text":"...","turnId":"<UUID>"}`. `turnId` must be a UUID; anything else gives `error: unrecognized frame`. Received: `ack` → `output` items (`index` increasing; `event.kind` notice / session_info / message / ...; `status` snapshots) → `post` (the full agent message) → `done{lastIndex, stopReason}`. A full round trip works. |

## Gaps and open points
1. **Org selection.** Superseded by OAuth: the org is chosen on the consent page. See "Which organization a sign-in is bound to" below.
2. **Approval decision body and option ids** are unverified until a real pending request appears. Need the test team to trigger one (an agent in a non-auto permission mode running a tool).
3. **"Only mine" filter**: use `triggeredBy` filter on `/sessions` if it accepts the user id; verify next.
4. **SSE events** (`session`, `session-activity`, `session-state`) not yet observed.
5. **No push channel** on the server, as the task expects. Background reminders are best-effort polling.

## Verified while building the app
- Message pages come back ascending by `seq`; `nextCursor` points to older messages. Sort by `seq`.
- Tool messages carry `toolCallId`, `toolStatus`, `toolKind`, `body` (JSON string; `bodyTruncated` flag). Full body: `GET /orgs/{org}/sessions/{id}/tool-body?toolCallId=&offset=` -> `{data,totalBytes,nextOffset}`.
- In-stream approvals: server event `permission{requestId,tool,detail}`; the reply op is `permission_choice{requestId,allow}` (relay-daemon protocol). Not exercised live.
- New chat with an agent: webchat round trip verified in the app (notices, `message` chunks, `post`, `done`).
- Simulator Keychain needs an entitlement: build with `airbuild-xcode archive`, not an unsigned `flutter build`.

## Sign-in: OAuth 2.1 + PKCE (built; replaces API key and the earlier OIDC attempt)

Read from the server source (`packages/control-plane/src/http/oauth/*`, `registry/oauthService.ts`, `http/plugins/auth.ts`, `http/org-scope.ts`; read-only) and implemented in `lib/core/auth/`. Live run pending (see the end).

### Discovery
- `GET {api origin}/.well-known/oauth-protected-resource` (RFC 9728) → `{resource, authorization_servers[1], scopes_supported: [mcp:read, mcp:write], bearer_methods_supported: [header]}`. The same document is also served path-inserted at `/.well-known/oauth-protected-resource/v1/mcp`; the app tries the origin root first, then that one.
- When the deployment has a dedicated MCP origin, `authorization_servers[0]` and `resource` are **that origin**, not the API host (the AS and API are on different hosts). The app never assumes they match.
- `GET {issuer}/.well-known/oauth-authorization-server` (RFC 8414) → `issuer, authorization_endpoint (/oauth/authorize), token_endpoint (/oauth/token), registration_endpoint (/oauth/register), response_types_supported [code], grant_types_supported [authorization_code, refresh_token], code_challenge_methods_supported [S256], token_endpoint_auth_methods_supported [none], scopes_supported [mcp:read, mcp:write, ahp]`.
- **No `revocation_endpoint`** (see gaps).
- `resource` from the PRM is sent as RFC 8707 `resource` on authorize and on the code exchange.

### Registration (RFC 7591)
- `POST /oauth/register` JSON `{client_name, redirect_uris, grant_types}` → **201** `{client_id, client_name, redirect_uris, grant_types, response_types:[code], token_endpoint_auth_method: none, client_id_issued_at}`.
- **Only `https` redirect URIs (or http loopback) can be registered.** A custom scheme is rejected (`invalid_request`). So the app registers only `https://<callback host>/mobile/oauth/callback`; the `agentconnect-test://oauth/callback` fallback is never sent to the server, it is only the target of the callback page's "Return to AgentConnect" button, and the app checks its `state` like the https callback.
- Registrations expire after 90 days. `client_id` is cached in the Keychain per (issuer, redirect URI) with `client_id_issued_at`.

### invalid_client: where it can show up
- `/oauth/authorize` answers an unknown or expired client with a **bare 400 JSON page in the browser** (it can't redirect to an unvalidated redirect URI). The app can't see that page, so it (1) renews the registration 3 days before the 90 days are up and (2) sends the same authorize URL once with redirects off **before** opening the sheet: 302 = fine; 400 `invalid_client` / `invalid_request` (e.g. redirect not registered) → register again silently and retry once. The authorize step stores nothing server-side, so this check has no side effects.
- `/oauth/token` (code exchange) → `invalid_client` → register again and run the sign-in again once (the code is tied to the old client).
- The refresh grant does not check the client at all; a refresh failure means the grant is gone and the user signs in again.

### Authorization and tokens
- Authorize query: `response_type=code, client_id, redirect_uri, scope=mcp:read mcp:write, state, code_challenge, code_challenge_method=S256, resource`. The server 302s to the console's `/oauth/consent` (org picker + Authorize/Deny). Deny → `?error=access_denied&state=` (shown as "cancelled", no error).
- Callback: `?code=&state=`. A callback whose `state` doesn't match the waiting attempt is discarded (also for errors).
- Code: 60 s lifetime, single use.
- Token response (code and refresh): `{access_token, token_type: Bearer, expires_in: 3600, refresh_token, scope}`. **No org id, no id_token.** The access token is opaque (an org-bound key behind the scenes), not a JWT.
- `scope` is what the user approved: the consent page can drop `mcp:write`, leaving `mcp:read`. A read-only token gets **403 "this token is limited to read-only access"** on every non-GET under `/orgs/{org}` (decisions, webchat token). The app stores the granted scope, shows "View only…" in Settings and on a failed decision.
- Refresh: `grant_type=refresh_token` (+ `client_id`). Rotates every time; the previous refresh token stays valid for **one** more use (lost-response retry). Two refreshes racing with the same token → the loser gets `invalid_grant "refresh token superseded"` and the grant must be re-authorized, so the app keeps one in-flight refresh per account and writes the rotated token to the Keychain before using it. 30-day inactivity window, slid on each refresh.
- Errors: `invalid_grant` (unknown / revoked / expired / superseded) → "You were signed out" screen with "Sign in again". 5xx → treated as a network problem (old token used while valid).
- Scope `ahp` must not be mixed with MCP scopes (`invalid_scope`); an AHP-only token is refused on REST (403). The app never asks for it.

### Which organization a sign-in is bound to (gap)
- The grant is bound to the org picked on the consent page, but neither the token response nor `GET /me` says which. `GET /orgs` returns **every** org the user belongs to, and other orgs' subtrees answer **404 "organization not found"** for this token.
- Workaround with public API only: after sign-in, `GET /orgs`, then `GET /orgs/{id}/agents` for each until one answers 200. Costs one call per membership.
- **Server ask:** include the org (`org_id`, ideally name) in the token response, or add a `GET /me` field / endpoint for the token's bound org.

### Sign-out / revocation (gap)
- No RFC 7009 endpoint. `DELETE /api/v1/oauth/grants/:id` exists but is `interactiveOnly` (403 for OAuth tokens), so the app can't revoke its own grant. Sign out deletes the tokens locally; the grant stays until the user removes it in the console Profile page or it ages out (30 days unused). The app calls `revocation_endpoint` automatically if the server ever advertises one.
- **Server ask:** an RFC 7009 `revocation_endpoint` (public client, `token` + `client_id`), advertised in the AS metadata.

### Measured on the test environment (2026-11-04, curl, no user token)
Hosts below as roles: API host, MCP host (dedicated MCP origin, also the AS), console host (callback page).
- **The API host serves no OAuth metadata**: `GET {api}/.well-known/oauth-protected-resource` → 404, and the path-inserted `/v1/mcp` form → 404. Differs from the task document (step 1 "GET {API origin}/.well-known/oauth-protected-resource").
- Entry that works: `POST {api}/v1/mcp` without a token → **401** `WWW-Authenticate: Bearer resource_metadata="https://{mcp}/.well-known/oauth-protected-resource", scope="mcp:read mcp:write"` (RFC 9728 §5.1). The app tries the origin root, then path-inserted, then this challenge.
- `GET {mcp}/.well-known/oauth-protected-resource` → `{"resource":"https://{mcp}","authorization_servers":["https://{mcp}"],"scopes_supported":["mcp:read","mcp:write"],"bearer_methods_supported":["header"]}`.
- `GET {mcp}/.well-known/oauth-authorization-server` → `{"issuer":"https://{mcp}","authorization_endpoint":"https://{mcp}/oauth/authorize","token_endpoint":"https://{mcp}/oauth/token","registration_endpoint":"https://{mcp}/oauth/register","response_types_supported":["code"],"grant_types_supported":["authorization_code","refresh_token"],"code_challenge_methods_supported":["S256"],"token_endpoint_auth_methods_supported":["none"],"scopes_supported":["mcp:read","mcp:write","ahp"]}`. No `revocation_endpoint`.
- `POST /oauth/register` with `https://{console}/mobile/oauth/callback` → 201 with `client_id`. With `agentconnect-test://oauth/callback` → 400 `invalid_request` "redirect_uris must be https or http loopback, without a fragment".
- Authorize preflight: registered client → 302 to `https://{console}/oauth/consent?...` (all params, including `resource`, forwarded). Unknown client → 400 `{"error":"invalid_client","error_description":"unknown or expired client"}`.
- `https://{console}/mobile/oauth/callback` exists: it forwards `code, state, error, error_description` to `agentconnect-test://oauth/callback?...` via a "Return to AgentConnect" button, and clears the query from history.
- `https://{console}/.well-known/apple-app-site-association` → **404**: the https callback can't be intercepted yet (needs the app ID, see README); the fallback button is the path for now.
- Server ask (optional): serve the PRM at the API origin too, so the documented step 1 works without the MCP challenge.

### Still to verify live (needs a person to sign in on the consent page)
3. Authorization through the system sheet + consent page; the fallback button (`agentconnect-test://oauth/callback`) until the AASA file lists the app ID; the https callback after.
4. Code exchange, refresh, refresh after revoking in the console Profile page.
5. With the OAuth token: `/me`, `/orgs`, the bound-org probe, `/orgs/{org}/agents`, `/sessions`, awaiting sessions, both permission-request endpoints, SSE stream, webchat token + one WebSocket round trip.

### Product decision (2026-11-04)
- The server address is built in (xcconfig per package); the "Use your own server" entry from the task document was removed at the owner's request. Self-hosted servers need their own build configuration.
- **https callback needs AASA (measured in the simulator):** with `ASWebAuthenticationSession(callback: .https(host:path:))` and no `apple-app-site-association` on the callback host, iOS opens the sheet and closes it ~60 ms later as "cancelled by user" (no error the app can tell apart). Build flag `AC_HTTPS_CALLBACK` (xcconfig): `NO` (now) completes the sheet on the `agentconnect-test://` URL the callback page's button opens; switch to `YES` once the AASA lists `<TEAMID>.com.yulong.agentconnect`. The registered redirect URI stays https either way.
- **Consent page loses its place after a console sign-in (web console, measured 2026-11-04):** when the sheet opens `/oauth/consent` without a console session, the page stores its URL in `sessionStorage['ac.returnTo']` and starts the console sign-in; after signing in, the user lands on the console **home page** instead of the consent page, so the app's sign-in never completes. The deployed code matches `packages/web/src/app/oauth/consent/page.tsx` and `auth/callback/page.tsx` (it does read `returnTo`), so the stored value is lost on the round trip to the sign-in host inside `ASWebAuthenticationSession`. Workaround for users: tap Sign in again — the console session is kept (non-ephemeral sheet), so the consent page shows directly. Web console ask: carry the return path through the sign-in itself (e.g. in the sign-in `state`, or always also in the `ac.returnTo` cookie that `flow-state.ts` already supports), not only in sessionStorage.

## Verified with an OAuth sign-in (test environment, 2026-11-04)
- Sign-in completed in the simulator (fallback scheme callback). With the OAuth access token the app read:
  `GET /me`, `GET /orgs` + bound-org probe, `GET /orgs/{org}/agents` (54), `GET /orgs/{org}/daemons` (cloud pool
  members + self-hosted), `GET /orgs/{org}/sessions` (grouped; `accessSyncDegraded: true` at the time, shown as the
  "Some conversations can't be shown" note), `GET /sessions/{id}/messages` (list previews). So REST accepts the
  OAuth token as a Bearer token. Not yet exercised with it: SSE events, webchat token + socket, a live approval.

## Gaps found while building the Lite design
1. **Approval cards**: the design shows a tool tag ("Bash", "Write") and a one-line human title ("Run a command on
   prod"). `permission-requests` items only have `command` (one masked line), `kind` (`join` or absent) and
   options. The app shows `command` in the code box and "Join" + "<name> asks to join this conversation" for joins.
   Server ask: `toolName` and a short `summary` per request.
2. **Decided approvals**: the queues return resolved items (`status` allowed/denied/expired, `resolvedAt`,
   `resolvedByName`) but they are read per agent / per conversation, and the app only reads queues of sessions
   that are awaiting now (`activityState=awaiting_permission`). So "Decided" shows what you answered in the app
   plus what those queues still hold. Server ask: an org-wide recent decisions list.
3. **Session list previews**: `/sessions` rows carry no last-message text (content stays on the org's
   machines). The app fetches `messages?limit=8` for visible rows, keeps the text in memory only, and shows
   nothing on 503. Costs one request per row. Server ask: an optional short `lastReply` preview (masked).
4. **Daemon OS**: the design shows "Ubuntu 24.04 · v1.9.4 · 3 running". `/daemons` has `host`, `agentVersion`,
   `activeSessions`, `load {cpu, mem, agents}` but no OS. The app shows host (when it differs from the name),
   version and running count. `load.cpu` arrives as 0–1 on some daemons; the app accepts 0–1 and 0–100.
5. **Cloud pool**: `/daemons` lists each pool member (`cloud: true`) separately; the app shows them as one
   "Cloud pool" row (N nodes, online if any member is, sessions summed, CPU averaged), like the console.
6. **Daemon status values** (from the server source): `ready`, `draining`, `connecting`, `pending`, `unreachable`,
   `offline` → online / paused (draining, connecting, pending) / offline.

## Chat redesign: tasks, run settings, workspace (2026-11-04)
All with existing endpoints / frames:
- **Tasks of a conversation**: `GET /orgs/{org}/agents/{agentId}/assistant/subsessions?parentSessionId=<session>`
  → `{subsessions[{sessionId, title, state open|done|failed, startedAt, summary, summaryUpdatedAt, threaded,
  replies, openedForMessageId, visible, canStop, kind}], nextCursor}`; 409 `DAEMON_FEATURE_MISSING` on old daemons
  (no task cards then). `openedForMessageId` matches a transcript message's `postId`, so the card goes under it.
  A task thread is the task's own session: its messages via `/sessions/{taskSessionId}/messages`, replies via
  that session's continuation token.
- **Run settings**: the web chat socket takes `{type:'set_model', model}`, `{type:'set_effort', effort}`,
  `{type:'set_permission_mode', permissionMode}` (also `set_fast`), as the console does; the daemon confirms with
  `output.status {model, effort, permissionMode, models[], efforts[], permissionModes[]}`. Earlier builds parsed
  `status` as a string and dropped it. Before any snapshot the app shows the session row's values; models fall back
  to `GET /daemons/{id}` `runtimeProfiles[].models` for the agent's runtime; efforts and permission presets are only
  offered when the session reports them (nothing invented). The relay stamps the caller's role; non-editors may be refused.
- **Workspace**: `GET /agents/{id}/workspace/files?sessionId=&path=`, `.../workspace/file?path=` (content/encoding/
  truncated), `.../workspace/gitstatus` (branch, tracking, files[path,index,workingDir,additions,deletions]),
  `POST .../workspace/gitstage {paths}` + `POST .../workspace/gitcommit {message}` (edit access; `ok:false` + reason
  is data; 409 when the agent is busy; 503 offline). The app passes `sessionId` first and falls back to the agent's
  checkout on 400/404. Base branch is taken from `tracking` (no separate base field).
- **File previews**: text pages with `.../workspace/file?offset=` (`nextOffset` while `truncated`; `type: dir` for a
  folder). Images and PDFs read `GET .../workspace/file/download?path=&sessionId=` — the original bytes (≤ 8 MiB,
  413 `WORKSPACE_FILE_TOO_LARGE` above, 409 on daemons without downloads). Folder listings page with `cursor`.
- **Computer** (not built for now, by decision): `GET /sessions/{id}/computer-screenshots` would give the latest
  screenshot (short-lived signed `url`); the design's "X11 :1" display and resolution are not in the API.
