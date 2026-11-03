# API_NOTES — M0 feasibility results

Tested with a Full-permission personal API key against the test environment (hosts anonymized below; the key is never stored in the repo).

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
1. **Org selection.** `/me` carries no org. `/orgs` lists all orgs the user belongs to, even with one key. Plan: after validating, call `/orgs`, let the user pick (default: first) and store it with the key. Needs confirming whether a key is really single-org in production.
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
