#!/usr/bin/env node
import { parseArgs } from "node:util";
import { readUsageRuntime } from "./usage-runtime.js";

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
  const report = !runtime ? { version: 1, runtime: "missing" } : {
    version: 1,
    generatedAt: new Date().toISOString(),
    timeZone,
    runtime: "recorded",
    refreshing: false,
    scan: { state: "complete", coveredFrom: null, coveredThrough: null, skippedArchives: 0 },
    programs: [
      { program: "claude", tokenUsage: { state: "noData" }, usageLimits: { state: "disabled" } },
      { program: "codex", tokenUsage: { state: "noData" }, usageLimits: { state: "unavailable", reason: "programMissing" } },
    ],
  };
  console.log(JSON.stringify(report));
} catch {
  // Never echo arguments or Host configuration into the response.
  console.error("usage-query: invalid query");
  process.exitCode = 1;
}
