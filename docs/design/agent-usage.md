# Agent Usage

Status: Proposed (#494; tickets #495–#503). Not implemented. Decisions are
recorded in [ADR 0026](../adr/0026-plugin-collects-agent-usage-on-the-host.md);
terms are defined in [CONTEXT.md](../../CONTEXT.md) (**Usage Limits**,
**Token Usage**, **Transcript**).

## Summary

Heeler shows, per Host, how much of each Claude Code and Codex account's
Usage Limits is used and when each window resets, beside the Token Usage those
programs recorded on the Host over the last 30 days with an estimated API cost.

All collection happens on the Host inside the Heeler herdr plugin. The plugin
reads Transcripts locally, asks Codex and Claude Code themselves for their
Usage Limits, and answers the app with a small, filtered JSON document. The
app reaches the plugin with one bounded SSH exec per query. No SFTP, no new
port, the plugin never reads a credential, and the user installs nothing
beyond the plugin.

## Goals

- Usage Limits for Claude Code and Codex: each window's used percentage and
  reset time, with the source and age of the reading.
- Token Usage for Claude Code and Codex: today, the last 7 days and the last
  30 days; a 30-day daily series; a per-model split; the top 10 working
  directories over 30 days. Each with an estimated API cost where the model is
  priced.
- Correct counting: no double counting of repeated, copied, replayed or
  cumulative records.
- Fast queries over SSH: a query never waits for a log scan or a network call.

## Non-goals

- Usage per Agent or per session (later).
- Usage across Hosts, on the Console, or on Agent detail (later).
- History beyond 30 days. The plugin keeps no history of its own; what it
  shows is bounded by the Transcripts still on the Host.
- A local estimate of a rolling 5-hour window. Windows come only from Usage
  Limits, so a local guess is never mistaken for the account's real limit.
- Billing. The estimated cost is what the tokens would cost at API list
  prices; it is not a subscription invoice or a credit balance.
- Native Windows Hosts. The plugin supports Linux and macOS only.
- Agent programs other than Claude Code and Codex.
- Codex limit groups other than the default one. Codex can report several
  limit groups (`rateLimitsByLimitId`); the first version shows only the
  default group's two windows and says so on the Usage page.

## Architecture

```mermaid
sequenceDiagram
    participant App as Heeler app
    participant SSH as SSH exec (/bin/sh -s)
    participant Query as usage-query.js
    participant Cache as Usage cache (Host)
    participant Worker as usage-worker.js
    participant Logs as Transcripts (Host)
    participant Svc as codex app-server / claude get_usage

    App->>SSH: bounded script (tz, flags)
    SSH->>SSH: herdr plugin config-dir heeler → runtime.json → node, state dir
    SSH->>Query: node <plugin_root>/src/usage-query.js
    Query->>Cache: read snapshot
    Query-->>Worker: spawn detached if stale and lock free
    Query-->>App: usage v1 JSON (refreshing: true while the worker runs)
    Worker->>Logs: incremental scan from saved offsets
    Worker->>Svc: Usage Limits (throttled)
    Worker->>Cache: write snapshot atomically
    App->>SSH: re-query every 3 s until refreshing is false
```

### Components on the Host

| Component | Runs in | Role |
| --- | --- | --- |
| Runtime recorder (in the existing startup hook and `pane.agent_status_changed` hook) | herdr's environment | Writes `runtime.json` to the plugin config directory |
| `src/usage-query.js` | the app's SSH exec | Reads the cache, spawns the worker when needed, prints the contract |
| `src/usage-worker.js` | detached from the query | Scans Transcripts, reads Usage Limits, writes the cache |
| `src/usage/claude-*.js`, `src/usage/codex-*.js` | worker | Per-program Transcript scanners and limit readers |
| `src/usage/pricing.json` | worker | Bundled, versioned price table |

### Why the runtime file exists

herdr runs the plugin with its own environment; the app's SSH exec has a
different, non-login one. Agents read `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and
`XDG_CONFIG_HOME` from herdr's environment, and `node` may only be on herdr's
`PATH` (nvm, fnm, volta, or a Herdr Endpoint launcher with no `PATH` at all).
Plugin hooks run in herdr's environment, so they record:

```json
{
  "version": 1,
  "recordedAt": "2026-10-23T12:00:00Z",
  "node": "/Users/u/.nvm/versions/node/v22.11.0/bin/node",
  "codex": "/Users/u/.nvm/versions/node/v22.11.0/bin/codex",
  "claude": "/Users/u/.local/bin/claude",
  "env": {
    "PATH": "/Users/u/.nvm/versions/node/v22.11.0/bin:/opt/homebrew/bin:/usr/bin:/bin",
    "CLAUDE_CONFIG_DIR": null,
    "CODEX_HOME": null,
    "XDG_CONFIG_HOME": null
  },
  "stateDir": "/Users/u/.local/state/herdr/plugins/heeler"
}
```

- `node` is `process.execPath`; `codex` and `claude` are the first
  executables of those names on herdr's `PATH`, or `null`.
- `env.PATH` is herdr's `PATH`. The worker runs `codex` and `claude` with it:
  an npm-installed `codex` is a `#!/usr/bin/env node` script, which exits 127
  under sshd's minimal `PATH`.
- `stateDir` is `HERDR_PLUGIN_STATE_DIR`, which herdr gives every plugin
  command, startup hooks included, since 0.7.5. herdr derives it only from
  `XDG_STATE_HOME`, so named sessions share it, and a Herdr Endpoint shares it
  unless its launcher also sets `XDG_STATE_HOME` (ADR 0023 isolates only
  `XDG_CONFIG_HOME`). The usage cache therefore lives in
  `<stateDir>/usage/<rootsKey>/`, where `rootsKey` is a short hash of the
  resolved Transcript roots (below). The cache is a function of those roots,
  so two instances share a cache exactly when they read the same Transcripts.
- The startup hook writes the file at server start and live handoff. herdr
  does not run startup hooks when a plugin is installed, linked, enabled or
  updated, so the existing `pane.agent_status_changed` hook also computes the
  record and rewrites the file when it is missing or a field other than
  `recordedAt` differs. Named sessions on one config home share the file; if
  their environments differ, the most recent writer wins.
- The file is written atomically (temp file and rename), mode 0600, and holds
  no secret.
- When the file is missing (plugin just installed, no Agent has changed
  status since), the query cannot know the state directory or the right
  roots, so it does not guess: the script reports `runtime: "missing"`, no
  worker runs, and the app asks the user to use any Agent on the computer
  once, or to restart herdr.

## App to plugin channel

One query is one `runBoundedScript` exec (`/bin/sh -s`, remote watchdog,
ordinary-session channel, never cancelled once dispatched), with a 10-second
deadline and a 1 MiB `head -c` cap on output. The script, fixed text from the
app with only validated arguments interpolated:

1. Exports `HerdrHostPath.pathExport` (or uses the Host's Herdr Endpoint
   launcher) and runs `herdr plugin config-dir heeler`.
2. Reads `runtime.json` from that directory. When it is missing, prints the
   `runtime: "missing"` result and stops.
3. Runs `<runtime.node> <plugin_root>/src/usage-query.js --tz <IANA>
   [--claude-limits]` and prints its stdout between nonce markers.

`plugin_root` comes from `plugin.list`; the app's `PluginListResult` decoder
gains `plugin_root`. The time zone is validated against the device's IANA
identifier set before interpolation. A recorded `node` that no longer runs
(exit 126 or 127) maps to the same state as a missing file, since the next
hook run records the current one.

`plugin.action.invoke` was rejected: it is asynchronous (stdout only via
polling `plugin.log.list`), its log output is capped, and every action is
visible in the user's herdr command palette.

## Token Usage

### Sources

- **Claude Code**: every `*.jsonl` under `projects/` of each root:
  `CLAUDE_CONFIG_DIR` as one path (Claude Code does not split it; the
  comma-separated list is a ccusage convention), `~/.claude`, and the legacy
  `${XDG_CONFIG_HOME:-~/.config}/claude` when it exists, deduplicated by real
  path. This includes subagent and workflow files under
  `<project>/<session>/subagents/`.
- **Codex**: `${CODEX_HOME:-~/.codex}/sessions/YYYY/MM/DD/rollout-*.jsonl`
  and `archived_sessions/`, plain or `.jsonl.zst`. Codex compresses cold
  rollouts in the background and keeps their mtime
  (`codex-rs/rollout/src/compression.rs`); on one development machine, 333 of
  the 399 rollouts modified in the last 30 days were `.jsonl.zst`
  (2026-10-23). A rollout and its `.zst` are one logical file, keyed by the
  path without `.zst`, and the plain file wins while both exist; `sessions/`
  wins over `archived_sessions/`. `.zst` files are streamed through
  `zlib.createZstdDecompress` (Node 22.15.0 and 23.8.0, experimental), else
  through `zstd -dc` found on the recorded `PATH`, else counted in
  `scan.skippedArchives` and the app says so.

Multiple roots per program are merged into one total for that program.
`rootsKey` hashes the resolved real paths of all roots of both programs.

### Counting rules: Claude Code

The record shapes are documented in
[Claude Code transcripts](../research/claude-code-transcript-format.md).

- Count `type: "assistant"` records with `message.usage`; skip
  `message.model == "<synthetic>"`.
- One API response is written as several records that share `message.id`
  and `requestId` and repeat `usage`. Claude Code also copies responses into
  other transcripts. Deduplicate globally (across files and sessions) on
  `message.id + requestId`; without `requestId`, on
  `message.id + sessionId + timestamp`.
- On collision keep the non-sidechain record, then the larger token total
  (streamed snapshots of one response can undercount output). `speed` is no
  tie-breaker: 2.1.309 writes it on nearly every record (`standard` or
  `fast`).
- Drop sidechain replays that re-copy a parent message: same `message.id` in
  the same session with a different `requestId` (subagent logs such as
  `/btw` replay the parent this way). Sidechain records were 84% of the
  assistant records in a three-day sample on one development machine, so
  these rules decide most of the total.
- `usage.speed == "fast"` selects Fast pricing.
- Advisor iterations (`usage.iterations[type == "advisor_message"]`) are not
  added in this version. Whether the parent `usage` already includes them is
  undocumented, and Claude Code itself does not add them; a fixture from a
  real advisor run settles it first.
- Cache writes are `cache_creation.ephemeral_5m_input_tokens` and
  `ephemeral_1h_input_tokens`; when the split is missing, all of
  `cache_creation_input_tokens` is treated as 5-minute writes.
- Directory: the session's `cwd`, else the decoded project directory name.

### Counting rules: Codex

The record shapes are documented in
[Codex rollouts](../research/codex-rollout-format.md). The rules below were
checked against Codex source at `2839ed76` (2026-10-23, CLI 0.164.0). A
file's own thread id is `session_meta.payload.id`.

- **Per-response records (Codex 0.153.0 and later).** Every completed or
  incomplete response, compaction responses included, writes one top-level
  `token_usage_record` with `thread_id`, `response_id`, `usage`,
  `turn_token_usage` and `thread_token_usage`
  (`record_response_token_usage` in `codex-rs/core/src/session/mod.rs`, its
  only writer). Count `usage` once per `response_id`, globally across files.
  A record whose `thread_id` is not the file's own id was copied from another
  thread (a copied fork keeps the parent's records verbatim) and is not
  counted from this file. Compaction needs no rule of its own.
- **`token_count` (all versions).** Usage also appears as `event_msg`
  `token_count` with `info`. If `total_token_usage` equals the previous
  event's, skip it as a duplicate. Otherwise the delta is `last_token_usage`,
  or the total minus the previous total when `last_token_usage` is absent.
  Drop all-zero deltas. An advance adds its delta only when the file has
  read no own-thread `token_usage_record` since the previous `token_count`;
  otherwise the records already counted it. Files from before 0.153.0 count
  by `token_count`, newer ones by records, and a file resumed across the
  upgrade switches at its first record.
- **Inherited prefixes.** A copied fork (`forked_from_id` without
  `history_base`) and a subagent (`session_id` differs from `id`) start with
  the parent's events, `token_count` included. Subagents inherit no
  `token_usage_record` (`codex-rs/core/src/agent/control/spawn.rs`). Codex
  ends the copied prefix with a `thread_settings_applied` naming the child's
  own thread, while copied snapshots keep their original owner's `thread_id`
  (`ThreadSettingsAppliedEvent` in `codex-rs/protocol/src/protocol.rs`).
  `token_count` events before the first own-thread `thread_settings_applied`
  are not counted. Files written before that event carried a `thread_id`
  fall back to the earlier rules: match a fork against its parent, else skip
  the leading burst of events no more than 1000 ms apart; for multi-agent
  children count only after the `inter_agent_communication_metadata` (or
  `inter_agent_communication`) marker with `trigger_turn: true`. Detect by
  markers, never by `cli_version`.
- **Referenced history.** A file whose `session_meta` carries `history_base`
  (a referenced fork or a revert) holds only its own events, so nothing is
  excluded. The base file keeps counting its own usage, including turns that
  were later rolled back, because they were used.
- The model is the latest `turn_context.model` or
  `thread_settings_applied.thread_settings.model` before the usage. The
  service tier comes from `thread_settings_applied`: `priority` or `fast`
  means Fast pricing, `flex` means Flex pricing.
- Directory: `session_meta.cwd`.

### Normalized tokens

Both programs map to one shape:

| Field | Claude Code | Codex |
| --- | --- | --- |
| `input` | `input_tokens` | `input_tokens - cached_input_tokens` |
| `cacheRead` | `cache_read_input_tokens` | `cached_input_tokens` |
| `cacheWrite` | 5m + 1h cache creation | `cache_write_input_tokens` (0 when absent) |
| `output` | `output_tokens` | `output_tokens` (includes reasoning) |
| `reasoning` | 0 | `reasoning_output_tokens`, informative, not added to `total` |
| `total` | input + cacheRead + cacheWrite + output | same |

### Estimated cost

`src/usage/pricing.json` is generated by `scripts/generate-usage-pricing.mjs`
from LiteLLM's `model_prices_and_context_window.json` (MIT; its source URL
lives in the script), trimmed to Claude and GPT model families, reviewed as a
diff, and regenerated before each plugin release. models.dev (MIT) is the
fallback source; OpenRouter's terms forbid automated copying. The table
carries a `pricingVersion` date. The plugin never fetches prices at runtime.

Each model entry carries input, output, cache read and cache write
(5-minute) rates, optional Fast and Flex rates, and an optional
`longContext` tier: an input threshold with its own full rate set. The
table, not the code, decides which models have tiers. On 2026-10-23, Claude
4.6 and later models were priced flat across their 1M window except Haiku
5.5 (a tier above 100K), and GPT models with a long-context price switched
above 272K input tokens. Cost is computed **per request** when the request is
scanned, then added to its bucket, because tiers depend on one request's
size:

- A request's context is `input + cacheRead + cacheWrite`; both providers
  measure the threshold on input that includes cached tokens. When the model
  has a `longContext` tier and the context exceeds its threshold, every token
  of that request (input, cache read, cache write, output) uses the tier's
  rates; otherwise every token uses the base rates. Never split one request
  across tiers.
- Claude: `input × input + cacheRead × cacheRead + write5m × cacheWrite +
  write1h × (input × 2) + output × output`, with the rates of the chosen tier.
  A `speed: "fast"` request uses the model's Fast rates, which apply to the
  whole context and stack with the cache multipliers.
- Codex: `input × input + cacheRead × (cacheRead, else input) + output ×
  output`; reasoning is already inside output. The Fast (`priority`) and Flex
  service tiers use the model's Fast or Flex rates.
- Regional price uplifts are ignored.
- A model with no price adds its tokens to `unpricedTokens` and nothing to
  cost; it is reported with `priced: false` and `estimatedCostUSD: null`,
  never 0.

### Buckets, window and cache

- Usage is aggregated into 15-minute UTC buckets per program × model, plus
  per program × directory, each holding normalized tokens, estimated cost and
  unpriced tokens. 15 minutes makes any IANA offset (+5:30, +5:45) exact when
  the query folds buckets into the device's calendar days.
- The window is the last 30 days of the device's calendar. The worker does
  not know the device's time zone, so it prunes buckets and dedupe keys older
  than 31 days, which keeps the 30th day complete for any offset. The plugin
  keeps no history of its own: when a Transcript is deleted its usage leaves
  the cache (by age, or with a rebuild, below), and `scan.coveredFrom`
  reports the earliest day actually covered.
- The cache directory (`<stateDir>/usage/<rootsKey>/`) holds:
  - `files.json`: per logical file `{dev, ino, size, mtimeMs, offset,
    carry}`, where `carry` is per-file parser state (previous Codex total,
    current model and tier, own thread id, whether the inherited prefix has
    ended, whether a record arrived since the last `token_count`).
  - `buckets.json`: the 31-day buckets. This is the only file the query
    reads, so it stays small.
  - `keys.log`: Claude and Codex dedupe keys with their day, appended as
    files are scanned and rewritten only when pruning drops days or a rebuild
    starts. A heavy user's keys run to tens of megabytes, too large to
    rewrite after every batch.
  - `limits.json`: the last Usage Limits readings (percentages, reset times,
    errors, `nextAllowedAt`); never credentials.
  - `worker.lock`: `O_EXCL` lockfile with pid and start time; stale after 10
    minutes or when the pid is gone.
- Appends stay incremental: a file whose `dev/ino` match and whose size grew
  (same or newer `mtimeMs`) is read from `offset` up to the last complete
  line; a partial last line is left for the next run.
- Changes that need no rebuild:
  - A file deleted when its recorded `mtimeMs` was already older than 31
    days. All its records are outside the window. With the default
    `cleanupPeriodDays` of 30, Claude Code's cleanup deletes only such files
    (a project directory whose newest file is older than the period); a user
    who sets it below 31 gets a rebuild after each cleanup.
  - The same `dev/ino` at a new path, such as a rollout archived from
    `sessions/` to `archived_sessions/`. Its state moves with it.
  - A plain rollout replaced by its `.jsonl.zst`. Codex compresses only cold
    rollouts, so the logical file keeps its state and is not read again.
  - A file that falls outside the window is pruned by bucket age.
- Anything else rebuilds the whole cache from the Transcripts: a file deleted
  while it held in-window records, a file that shrank, a new inode at the
  same path, or an `mtimeMs` change without growth. Global deduplication
  means a record skipped in one file may have been counted from another, so
  removing one file's share cannot be done locally; a rebuild is slower but
  always correct. It is also expensive: one development machine held 6.6 GB
  of Claude Code Transcripts, 766 MB of plain Codex rollouts and 393 MB of
  `.jsonl.zst` (a sample decompressed to 2.5 times its size) modified in the
  last 30 days, so rebuilds must stay rare. The rebuild runs in the
  background like a first scan, and the previous snapshot is served, marked
  `refreshing`, until it finishes.
- Deleting the cache directory is always safe: the next query starts a full
  rebuild.

### Worker scheduling

- The query spawns the worker (detached in its own session, `stdio:
  "ignore"`, `nice` where available) when the cache is older than 60 seconds,
  a rebuild is pending, or Usage Limits are due, and the lock is free. The
  worker must hold no descriptor of the SSH exec, so the exec ends while the
  worker keeps running, and its own session puts it outside the bounded
  script's watchdog process group.
- One worker run is one refresh: scan (incremental or rebuild), then Usage
  Limits. The query reports `refreshing: true` from the moment it spawns the
  worker, or finds it running, until the run has written its final snapshot,
  so the app keeps polling through the limit requests too.
- A full scan processes files newest first, so the recent days fill in first;
  `scan.state` is `partial` until every file in the window is done, then
  `complete`.
- The worker writes the cache atomically after each batch of files, so a
  query mid-scan returns partial, correctly labeled data.
- Files whose `mtime` is older than the window are skipped without reading.

## Usage Limits

### Codex

1. **Primary:** `codex -s read-only -a never app-server` over stdio JSON-RPC,
   using the `codex` and `PATH` recorded in `runtime.json`:
   `initialize` → `initialized` → `account/read` →
   `account/rateLimits/read` with no params. The method exists since
   `rust-v0.53.0`. Older versions typed its params differently, so no params
   is the portable call; it costs Codex one extra reset-credit lookup. On
   0.164.0 the whole exchange took 2.1 to 4.4 seconds including startup, and
   Codex answered without `initialized`, which is still sent. The process is
   killed after the response or 15 seconds. Codex owns its credentials and
   their refresh; the plugin never reads `auth.json`. `account/read` returns
   the account email, which the plugin drops. Only the default `rateLimits`
   group (limit id `codex`) is used.
2. **Windows:** `primary` and `secondary` keep those ids, but neither id
   implies a length. On 0.164.0 one account reported `primary` with
   `windowDurationMins: 10080` and no `secondary`. Either may be null, and
   the app labels each window by `durationMinutes`.
3. **Fallback:** when `codex` is missing, the method is unknown (older
   Codex), or the account is not signed in with ChatGPT, use the newest
   `token_count.rate_limits` seen during the scan whose `limit_id` is `codex`
   or absent, reported with `source: "lastSession"` and its `observedAt`.
   `resets_at` is in epoch seconds; Codex releases from 2025-09-24 to
   2025-10-17 wrote `resets_in_seconds`, relative to the record's
   `timestamp`; older snapshots carry no reset time (`resetsAt: null`).

A window whose `resetsAt` has passed, from either source, is reported with
`expired: true` and `usedPercent: null`. The app shows it as expired, current
usage unknown, and never infers the new window's usage.

The plugin does not call the ChatGPT web backend directly.

### Claude Code

Off unless the app passes `--claude-limits` (the per-Host toggle). The
plugin asks Claude Code itself, as it asks Codex.

- The worker runs the `claude` recorded in `runtime.json` with the recorded
  environment and the cache directory as its working directory:
  `claude -p --input-format stream-json --output-format stream-json
  --verbose --no-session-persistence --strict-mcp-config --settings
  '{"disableAllHooks":true}'`. It sends the `control_request` `initialize`,
  then `get_usage` with `skip_behaviors: true`, and ends the process after
  the response or 15 seconds. `skip_behaviors` skips Claude Code's own
  Transcript scan; its schema describes the flag as meant for "a usage
  meter".
- No user message is sent, so no model request runs. The flags keep the
  user's hooks and MCP servers from starting and leave no session file.
  Observed with 2.1.309 on 2026-10-23: about 1.1 seconds, no hook, no
  Transcript. Without the flags, the user's `SessionStart` hooks ran.
- Claude Code reads and refreshes its own sign-in, including the keychain
  item whose service name gains a hash suffix when `CLAUDE_CONFIG_DIR` is
  set. The plugin never reads `.credentials.json` or the keychain, and no
  token passes through it.
- The answer carries `subscription_type` (the plan), `rate_limits_available`
  and `rate_limits`. `rate_limits_available: false` means plan limits do not
  apply (in its schema's words: API key, Bedrock, Vertex, or missing profile
  scope) and maps to `unavailable` with `noPlanLimits`. An unknown
  `get_usage` subtype maps to `programTooOld`.
- Windows read: `five_hour`, `seven_day`, `seven_day_opus`,
  `seven_day_sonnet`, any other non-null object with a numeric `utilization`
  and a `resets_at` as `claude:<key>`, and each `model_scoped[]` entry as
  `claude:model:<display_name>` with its `display_name` as label.
  `utilization` is a percentage and `resets_at` is ISO 8601 in this answer;
  the reader also accepts epoch seconds. Spend and `extra_usage` fields are
  not shown.
- Throttle: at most one `get_usage` per 60 seconds. Claude Code backs off
  its own rate-limited requests. Any other failure (an error answer, a
  timeout, or no `rate_limits` while `rate_limits_available` is true) backs
  the plugin off for 5 minutes through `limits.json`'s `nextAllowedAt`;
  until then the state is `throttled` with the last good reading when one
  exists, else `error`.

The plugin does not call `api.anthropic.com` itself. Reading the stored
OAuth token and calling `/api/oauth/usage` directly was rejected (ADR 0026).

> [!WARNING]
> `get_usage` is an undocumented part of Claude Code's stream-json control
> protocol, so the plugin feature-detects it. Anthropic's terms say OAuth
> sign-in "is designed to support ordinary use of Claude Code and other
> native Anthropic applications" and that developers "may not collect,
> store, or intermediate Claude.ai credentials or session tokens". Asking
> the user's own unmodified Claude Code keeps the plugin away from the
> credentials, but it is still automated use of the subscription. Claude
> Usage Limits therefore stay opt-in per Host, and the toggle's explanation
> names the risk. Revisit before release.

## Contract: `usage` v1

The query prints exactly one JSON object. Unknown fields are ignored by the
app; a `version` with an unknown major tells the user to update Heeler. A
shared vector at `plugin/test-vectors/usage-v1.json` is produced by the Node
tests and decoded by the Swift tests.

```json
{
  "version": 1,
  "generatedAt": "2026-10-23T12:34:56Z",
  "timeZone": "Asia/Shanghai",
  "runtime": "recorded",
  "refreshing": false,
  "pricingVersion": "2026-10-20",
  "scan": {
    "state": "complete",
    "coveredFrom": "2026-09-24",
    "coveredThrough": "2026-10-23T12:34:00Z",
    "skippedArchives": 0
  },
  "programs": [
    {
      "program": "claude",
      "tokenUsage": {
        "state": "ok",
        "totals": {
          "today": {
            "tokens": { "input": 1200, "cacheRead": 830000, "cacheWrite": 41000, "output": 9800, "reasoning": 0, "total": 882000 },
            "estimatedCostUSD": 1.92,
            "unpricedTokens": 0
          },
          "last7Days": { "tokens": { "...": 0 }, "estimatedCostUSD": 12.4, "unpricedTokens": 0 },
          "last30Days": { "tokens": { "...": 0 }, "estimatedCostUSD": 51.0, "unpricedTokens": 0 }
        },
        "daily": [
          { "date": "2026-10-23", "tokens": { "...": 0 }, "estimatedCostUSD": 1.92 }
        ],
        "models": [
          { "model": "claude-opus-4-5", "priced": true, "tokens": { "...": 0 }, "estimatedCostUSD": 40.1 }
        ],
        "directories": [
          { "path": "/Users/u/src/app", "tokens": { "...": 0 }, "estimatedCostUSD": 22.3 }
        ]
      },
      "usageLimits": {
        "state": "disabled"
      }
    },
    {
      "program": "codex",
      "tokenUsage": { "state": "ok", "...": "same shape as above" },
      "usageLimits": {
        "state": "ok",
        "source": "service",
        "observedAt": "2026-10-23T12:34:50Z",
        "plan": "plus",
        "windows": [
          { "id": "primary", "durationMinutes": 10080, "usedPercent": 18, "resetsAt": "2026-10-28T00:00:00Z", "expired": false }
        ]
      }
    }
  ]
}
```

- `runtime`: `recorded`, or `missing` (no `runtime.json`; the result carries
  nothing else).
- `refreshing`: true while a worker run (scan and Usage Limits) is in
  progress, including the run this query just started.
- `scan.state`: `partial` (a full scan or rebuild has not reached every file
  in the window yet) or `complete`.
- `tokenUsage.state`: `ok`, `noData` (program never used on this Host),
  `error` with `reason`.
- `usageLimits.state`: `ok`, `disabled` (Claude toggle off, or this query
  did not pass `--claude-limits`; a reading another device's query cached is
  never shown then), `unavailable` with `reason` (`programMissing`;
  `programTooOld` and `noPlanLimits` for Claude Code; `notSignedIn` and
  `apiKeyAccount` for Codex), `throttled` with `retryAt` and the last good
  reading, `error` with `reason`.
- `source`: `service` (live reading) or `lastSession` (Codex rollout
  snapshot).
- A window with `expired: true` has `usedPercent: null`: its reading is from
  before `resetsAt`, and the current window's usage is unknown.
- Window `id`s: Claude `fiveHour`, `sevenDay`, `sevenDayOpus`,
  `sevenDaySonnet`, others as `claude:<key>` and
  `claude:model:<display_name>`; Codex `primary`, `secondary` of the default
  limit group only, either of which may be absent. A window may carry a
  `label` from the program (a Claude model bucket's display name) and has a
  nullable `durationMinutes`. The app labels Claude's known ids by name, a
  window with a `label` by that label, and every other window, Codex's
  included, by `durationMinutes` ("5-hour", "Weekly"), never by id.
- `daily` always has one entry per day in the window, zero-filled.
- `directories` holds at most 10 entries over 30 days, by total tokens.
- Never present: prompts, outputs, session titles, file contents, account
  emails, tokens or credential paths.

## App

- **Feature gate:** `HeelerPluginFeature.usage` with the minimum version of
  the plugin release that ships it (0.7.0 planned). Older plugins show the
  feature's requirement note; native Windows Hosts show "Not supported on
  Windows" as other plugin features do.
- **Transport:** `Transport.readAgentUsage(timeZone:claudeLimits:)` returning a
  decoded `AgentUsageReport`; POSIX only via `requirePOSIXHost`.
- **State:** an `AgentUsageStore` per Host owns the report, its freshness, and
  the refreshing re-query loop.
- **Toggle:** "Claude Code limits" per Host, stored on the device, default
  off, with an explanation that the plugin asks Claude Code on the computer
  for its plan limits, that neither the plugin nor Heeler ever handles the
  sign-in, and that this use is not officially supported.
- **Surfaces:**
  - Host detail gains a Usage section: per program, a bar for each Usage
    Limits window with its reset time and source age; below, today and 30-day
    Token Usage with estimated cost.
  - Tapping it opens the Usage page: today / 7 days / 30 days totals, a 30-day
    daily chart, per-model split, top 10 directories, the coverage note
    (`coveredFrom`, skipped archives), the price table date, and a note that
    Codex shows its default limit group only.
- **Refresh:** query when the section or page appears, on pull to refresh, and
  every 3 seconds while `refreshing` is true, which covers the scan and the
  Usage Limits requests; polling stops when it turns false. One "Refreshing"
  indicator covers the whole run. No timers otherwise.
- **Copy rules:** cost is always "Estimated API cost"; Token Usage never
  claims to be the account's usage; a `lastSession` reading shows "as of
  <time>"; an expired window shows "Expired · current usage unknown"; windows
  are named by length, not by id; `runtime: "missing"` asks the user to use
  any Agent on the computer once, or to restart herdr; no other product
  names.

## Security and privacy

- The plugin never reads a credential. Codex and Claude Code read, refresh
  and send their own sign-in when the plugin asks them for Usage Limits.
- Nothing is sent anywhere for Token Usage; the plugin reads local files only.
- The app receives aggregates and directory paths, which it can already see
  through the Agent's `cwd`.
- The cache holds token counts, model names, directory paths and limit
  percentages, under the plugin's state directory with 0700 permissions.

## Failure modes

| Situation | Result |
| --- | --- |
| Plugin missing or older than the feature | Requirement note, no exec |
| Native Windows Host | "Not supported on Windows" |
| `runtime.json` missing | `runtime: "missing"`; the app asks the user to use any Agent once or restart herdr |
| Recorded `node` no longer runs | Same state as a missing `runtime.json` |
| First scan or rebuild in progress | Partial data, "Refreshing", 3-second re-query |
| Transcript deleted with in-window records, truncated or rewritten | Background rebuild; previous snapshot shown meanwhile |
| Old Transcript deleted, rollout archived or compressed | No rebuild |
| `.zst` rollout with neither Node zstd nor `zstd` on `PATH` | Counted in `skippedArchives`; coverage note |
| Worker crashed | Stale lock reclaimed; next query restarts it |
| Codex too old for `account/rateLimits/read` | `lastSession` fallback |
| Reset time of a reading has passed | Window shown expired, usage unknown |
| Claude Code too old for `get_usage` | `unavailable`, `programTooOld` |
| Claude sign-in without plan limits | `unavailable`, `noPlanLimits` |
| `get_usage` fails or times out | `throttled` with last good reading, retry after 5 minutes |
| Unknown model | Tokens shown, cost marked unpriced |
| Query exceeds 10 s | Bounded-script timeout; shown as a failed request |

## Testing

- **Plugin (`npm test`):** run the hooks, the query and the worker as real
  child processes against fixture Transcripts:
  - Claude: duplicate records, a streamed snapshot with a smaller total,
    sidechain replays, a record with `speed: "fast"`, and an advisor
    iteration that adds nothing.
  - Codex: duplicate totals, missing `last_token_usage`; a response counted
    once from its `token_usage_record` while its `token_count` adds nothing,
    including a compaction response; a file resumed across 0.153.0 that
    switches from `token_count` to records; a copied fork whose parent
    records and `token_count` prefix are excluded, with and without the
    parent file; a subagent whose inherited `token_count` prefix ends at its
    own `thread_settings_applied`; an old fork using the 1000 ms fallback; a
    `history_base` file with nothing excluded.
  - Files: incremental append and partial line; a `.zst` read through Node
    and through a stub `zstd`, and skipped with neither; rebuild on
    truncation, inode change and deletion of a file with in-window records,
    including a record duplicated in two files where the counted copy's file
    is deleted; no rebuild for deleting an out-of-window file, archiving a
    rollout, or replacing it with its `.zst`.
  - Time and price: folding into +5:45 and DST days; per-request
    long-context pricing just below and above a threshold, flat-priced,
    Fast, Flex and unpriced models.
  - Limits: a stub `codex` (an npm-style `#!/usr/bin/env node` script, so
    it only runs with the recorded `PATH`) that replays app-server JSON-RPC
    and asserts no params; a weekly-only `primary`; rollout snapshots with
    `resets_at`, `resets_in_seconds`, and another `limit_id`; a stub `claude`
    that speaks the stream-json control protocol and asserts the flags,
    `skip_behaviors` and that no user message arrives, including
    `rate_limits_available: false`, an unknown subtype, a failure with and
    without a last good reading, and readings past their reset time; a query
    without `--claude-limits` that hides a cached Claude reading.
  - Runtime: the event hook writes a missing `runtime.json` and leaves an
    identical one alone; `runtime: "missing"`; `refreshing` staying true
    until the limit requests finish; the shared `usage-v1.json` vector.
- **App:** decoding the shared vector, unknown fields and window ids,
  windows labeled by length, feature gating, store re-query loop, toggle
  plumbing, and the bounded script's quoting.
- **Real Host:** the Linux/field lane runs the query against a seeded
  `CLAUDE_CONFIG_DIR` and `CODEX_HOME`, and checks that the exec returns
  while the worker it started is still running.
- **Real data:** before release, compare Claude Code totals on a real Host
  with ccusage for the same days, since sidechain rules decide most of the
  total.

## Rollout

Tracked under #494 as vertical slices:

1. #495 — Plugin channel tracer bullet (`runtime.json`, `usage` v1 skeleton and
   shared vector, `plugin_root` decoder, `HeelerPluginFeature.usage`, bounded
   script Transport call, `AgentUsageStore`, Host detail section states).
2. #496 — Claude Code Token Usage via the background worker
   (`<stateDir>/usage/<rootsKey>` cache, lockfile, `refreshing` loop,
   15-minute UTC buckets and time-zone day folding).
3. #497 — Codex Token Usage (per-response records with a `token_count`
   fallback, inherited-prefix exclusion for forks and subagents, archives,
   `.zst` decoding and skip count).
4. #498 — Incremental Transcript scanning from saved offsets; moves,
   compression and out-of-window deletions without a rebuild, background
   rebuilds for the rest.
5. #499 — Estimated API cost from the bundled, versioned price table.
6. #500 — Full Usage page (daily chart, per-model split, top 10 directories,
   coverage and price-table notes).
7. #501 — Codex Usage Limits via `codex app-server` with rollout-snapshot
   fallback, windows labeled by length and expired-window handling.
8. #502 — Opt-in per-Host Claude Code Usage Limits (`--claude-limits`,
   Claude Code's `get_usage`, 60-second throttle and failure back-off).
9. #503 — `CHANGELOG.md` Unreleased entry, plugin README section, and
   `docs/agents/navigation.md` source map row.

## Open questions

- Whether Claude Code started from an SSH session on an unlocked Mac can read
  its keychain item: verify on a real Host. A failure surfaces as a
  `get_usage` failure.
- The first Claude Code version with `get_usage` and `skip_behaviors`:
  feature-detect.
- Whether Claude's parent `usage` includes advisor iterations: decide from a
  real advisor Transcript before counting them.
- Anthropic's position on automated use of a subscription through Claude
  Code: re-check the terms before shipping the Claude toggle.

Settled on 2026-10-23: herdr gives startup hooks `HERDR_PLUGIN_STATE_DIR`
since 0.7.5; `account/rateLimits/read` exists since Codex `rust-v0.53.0` and
0.164.0 does not require `initialized`; Node ships zstd in 22.15.0 and 23.8.0
(experimental) and not in 20.x.
