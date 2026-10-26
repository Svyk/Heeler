#!/usr/bin/env node
import { readUsageRuntime } from "./usage-runtime.js";
import { cacheDirectory } from "./usage/cache.js";
import { answerClaudeLimitsRequest } from "./usage/claude-limits.js";

// The usage worker invokes this action through herdr, so Claude Code runs in
// the server's session, where macOS lets it use the login keychain.
try {
  const runtime = readUsageRuntime(process.env.HERDR_PLUGIN_CONFIG_DIR);
  if (runtime) await answerClaudeLimitsRequest(runtime, cacheDirectory(runtime));
} catch {
  process.exitCode = 1;
}
