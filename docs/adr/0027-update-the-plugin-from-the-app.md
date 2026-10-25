---
status: accepted
---

# Update the Heeler plugin from the app

A Host's page shows a notice when its Heeler plugin is missing, outdated,
disabled or left beside an old copy, with the commands to run on the Host.
herdr has no request that installs a plugin (`plugin.enable` and
`plugin.disable` exist; installs are CLI only), so running those commands for
the user means running the herdr CLI over SSH exec.

## Decision

The notice's sheet offers an action whenever Heeler can run its commands
itself, typed as `HeelerPluginStep`s rather than shell text:

- **Install or update** runs `herdr plugin install ZingerLittleBee/Heeler
  --ref plugin --yes`, the notice's own command, not `herdr plugin update`.
  0.9.3 has no `update`; `update` keeps the ref recorded at install, so an
  install from before ADR 0026 would stay on `main`, and an install pinned to
  a commit never moves. The command names the Host's session, so herdr's
  protocol check before an install asks the server Heeler uses; a session
  without a server falls back to the shared registry.
- **Remove a leftover legacy id** runs `herdr plugin uninstall <id>` after any
  update.
- **Turn on** sends `plugin.enable` to the Host's own session, so it needs no
  `--session` and works for endpoint Hosts too.

The tap is the confirmation: the sheet shows the exact commands above the
action, and `--yes` answers herdr's own prompt, which needs a terminal anyway.

Steps run in order on a connection the Host page opens for them, as the
preflight does. The Console's connection redials after a timeout and retries
the operation, which would run an install twice. The first failure stops the
action; install comes first, so a failed install never leaves the Host
without the copy it had. The outcome is the plugin list read back over the
same connection, not exit status. An install gets its own 180 s budget
because herdr bounds neither the fetch nor `npm ci`. When the budget runs out,
the sheet says the change may still finish, since it can.

The install inherits the exec's `PATH`, and so does the plugin's `npm ci`
build. A bare `herdr` gets the app's `PATH` prefixes (`HerdrHostPath`); an
endpoint launcher gets none (ADR 0023) and must provide Node.js itself.
A Host whose Node.js only appears in interactive shell setup fails the build,
and the sheet says so with herdr's own output. The user fixes the Host;
Heeler does not fall back to typing the command into a terminal.

No install is offered over a plugin that is not a GitHub install of this
repository: herdr refuses to replace a linked checkout and may refuse an
unknown source, and a fork's install would quietly move to this repository.
Turning such a plugin on, or removing a leftover legacy id, still is. No
action at all is offered on native Windows Hosts (no plugin) or for a plugin
installed under a legacy id. Moving to the current id changes which config
directory Notification Registration uses, and the Console's transport caches
that directory until it reconnects.

## Consequences

- Observed on herdr 0.9.5: a failed fetch or build leaves the previous
  plugin registered and enabled. A connection lost mid-install leaves either
  the old or the new plugin, never a partial registration, plus herdr's
  temporary directories (see [herdr compatibility](../agents/herdr-compatibility.md)).
- Running hooks pick up the new plugin at the next event; the plugin's
  startup hook waits for the next server start.
- A CLI newer than the running server refuses the install until the server
  restarts; the sheet names that cause, as it does for build and download
  failures.
- The installed version can only be as new as the `plugin` branch. An app
  built before its plugin was published still sees an outdated plugin after
  a successful install, and the sheet says the Host still reports it.

## Alternatives

- **Open a Shell Terminal and type the command**: the user's interactive
  shell would find Node.js more often, but it needs a running session,
  takes the Host's one interactive terminal, and leaves a tab behind.
  Reporting the failure was preferred.
- **A detached install polled through a log file**: survives the app being
  suspended, at the cost of log locations, orphan cleanup and polling. A
  plain exec leaves the Host on one version or the other when interrupted,
  and the sheet says the change may still finish when the connection ends
  before the read back.
