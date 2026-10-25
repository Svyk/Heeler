#!/usr/bin/env node
import { parseArgs } from "node:util";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { cacheDirectory, readJSON, writeJSON, activeLock, reserveWorker, releaseWorker, processStart, refreshFailures } from "./usage/cache.js";
import { reportFromSnapshot } from "./usage/buckets.js";
import { checkpointCurrent } from "./usage/checkpoint.js";
import { readUsageRuntime } from "./usage-runtime.js";

/** Start one detached worker unless another holds the lock; true while one runs. */
function startWorker(runtime, directory, claudeLimits) {
  const lock = reserveWorker(directory);
  if (!lock) return true;
  try {
    const worker = spawn(runtime.node, [fileURLToPath(new URL("./usage-worker.js", import.meta.url)), "--config", process.env.HERDR_PLUGIN_CONFIG_DIR, "--lock-token", lock.token, ...(claudeLimits ? ["--claude-limits"] : [])], {
      detached: true, stdio: "ignore", env: Object.fromEntries(Object.entries(runtime.env).filter(([, value]) => typeof value === "string")),
    });
    worker.on("error", () => { try { releaseWorker(directory, lock.token); } catch { /* The lock goes stale. */ } });
    if (!worker.pid) { releaseWorker(directory, lock.token); return false; }
    lock.pid = worker.pid;
    lock.processStart = processStart(worker.pid);
    writeJSON(join(directory, "worker.lock"), lock);
    worker.unref();
    return true;
  } catch {
    // A worker that never sees its pid in the lock exits on its own.
    releaseWorker(directory, lock.token);
    return false;
  }
}

try {
  const { values } = parseArgs({
    options: { tz: { type: "string" }, "claude-limits": { type: "boolean", default: false } },
    allowPositionals: false,
  });
  const timeZone = values.tz;
  if (!timeZone || !/^[A-Za-z_+-]+(?:\/[A-Za-z0-9_+-]+)*$/.test(timeZone)) {
    throw new Error("invalid time zone");
  }
  new Intl.DateTimeFormat("en", { timeZone }).format();
  const runtime = readUsageRuntime(process.env.HERDR_PLUGIN_CONFIG_DIR);
  let report = { version: 1, runtime: "missing" };
  if (runtime) {
    const directory = cacheDirectory(runtime);
    const snapshot = readJSON(join(directory, "buckets.json"));
    const failures = refreshFailures(directory);
    let refreshing = false;
    try {
      refreshing = Boolean(activeLock(directory));
      if (!refreshing && !failures.paused && (!snapshot?.complete || !checkpointCurrent(snapshot?.checkpoint)
          || snapshot?.breakdownsVersion !== 1 || Date.now() - Date.parse(snapshot.generatedAt) > 60_000
          || snapshot.limitsVersion !== 1 || !snapshot.nextLimitsAt || Date.now() >= snapshot.nextLimitsAt
          || (values["claude-limits"] && (!snapshot.nextClaudeLimitsAt || Date.now() >= snapshot.nextClaudeLimitsAt)))) {
        refreshing = startWorker(runtime, directory, values["claude-limits"]);
      }
    } catch {
      // A cache the query cannot write still serves the report it already has.
      refreshing = false;
    }
    // Cached aggregates may be stale without saying so; report the failing
    // refresh instead, keeping a program's own scan error when it has one.
    const failed = "The background refresh failed repeatedly.";
    const served = failures.failing ? { ...snapshot, errors: { claude: failed, codex: failed, ...snapshot?.errors } } : snapshot;
    report = reportFromSnapshot(served, timeZone, refreshing, Date.now(), values["claude-limits"]);
  }
  console.log(JSON.stringify(report));
} catch {
  // Never echo arguments or Host configuration into the response.
  console.error("usage-query: invalid query");
  process.exitCode = 1;
}
