---
status: proposed
---

# The plugin collects Agent usage on the Host

Heeler shows Usage Limits and Token Usage for Claude Code and Codex. The data
lives on the Host: Transcripts that can run to gigabytes, and sign-in
credentials that only the programs themselves should hold. Users configure
their status lines differently, and most have no usage tool installed.

## Decision

The Heeler herdr plugin computes both on the Host and the app reads a small
JSON document from it with one bounded SSH exec per query
([design](../design/agent-usage.md)).

- The app runs `node <plugin_root>/src/usage-query.js` through
  `runBoundedScript`. The plugin's startup hook writes a `runtime.json` from
  herdr's environment: the `node` to run, the Agents' data roots, and
  `HERDR_PLUGIN_STATE_DIR`, under which the cache lives, so a Herdr Endpoint
  never shares a cache with the user's own herdr. Without that file the query
  reports that herdr needs a restart instead of guessing.
  No SFTP, no listening port, no herdr plugin action.
- The query never blocks on work. It returns the cached snapshot and spawns a
  single detached worker that scans Transcripts incrementally and reads Usage
  Limits.
- Credentials never leave the Host and are never written, refreshed, logged
  or passed on a command line. Codex limits come from Codex's own
  `app-server`, which owns its credentials; Claude Code limits are opt-in per
  Host because they use Claude Code's sign-in against an undocumented
  endpoint.
- The plugin keeps no history of its own. Token Usage covers at most 30 days,
  bounded by the Transcripts still on the Host, and its cache can always be
  rebuilt from them.
- Prices come from a bundled, versioned table; nothing is fetched at runtime
  for Token Usage.

## Considered Options

- **Read Transcripts from the app over SFTP**: rejected. It moves gigabytes
  over the user's mobile link, and the app would repeat the deduplication on
  every device.
- **Require an existing usage CLI on the Host**: rejected. Users don't have
  one, and pinning someone else's output format makes it a wire contract.
- **Read the program's status line output**: rejected. Every user configures
  it differently, and it only reports while a session runs.
- **`plugin.action.invoke`**: rejected. It is asynchronous, so stdout is only
  available by polling capped logs, and the action would appear in every
  user's herdr palette.
- **A startup-hook poller**: rejected. One would run per herdr session, and it
  would call the services when nobody is looking.
- **Copy credentials to the device and call the services from iOS**:
  rejected. It moves secrets off the Host and is what Anthropic's terms
  forbid most clearly.
- **Persist long-term history in the plugin**: rejected for scope. Thirty
  days, as long as the Transcripts last, is enough, and a cache that is never
  authoritative can always be deleted safely.

## Consequences

- The usage contract (`usage` v1, shared vector in `plugin/test-vectors/`) is
  a cross-implementation contract. Changing it means a version bump honored
  by both the plugin and the app.
- The feature needs the plugin and Node.js on the Host, so it is unavailable
  on native Windows Hosts.
- The plugin, not herdr, becomes the owner of how Claude Code and Codex
  records are counted. Changes in either program's Transcript format become
  plugin updates.
- This deviates from the Transcript being read only by the app: the plugin now
  reads Transcripts on the Host as well, still read-only.
