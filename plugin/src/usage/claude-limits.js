import { spawn } from "node:child_process";

const unavailable = reason => ({ state: "unavailable", reason });
const failed = reason => ({ state: "error", reason });
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const knownWindows = { five_hour: ["fiveHour", 300], seven_day: ["sevenDay", 10080],
  seven_day_opus: ["sevenDayOpus", 10080], seven_day_sonnet: ["sevenDaySonnet", 10080] };

function readingFrom(body) {
  if (!object(body)) return failed("invalidResponse");
  if (body.rate_limits_available === false) return unavailable("noPlanLimits");
  if (body.rate_limits_available !== true || !object(body.rate_limits)) return failed("invalidResponse");
  const windows = [];
  const add = (id, durationMinutes, window, label) => {
    if (!object(window) || window.utilization == null) return;
    if (!Number.isFinite(window.utilization) || window.utilization < 0) throw new Error("invalid utilization");
    const reset = window.resets_at;
    const milliseconds = reset === null ? null : typeof reset === "string" ? Date.parse(reset)
      : Number.isFinite(reset) ? reset * 1000 : NaN;
    if (milliseconds !== null && !Number.isFinite(new Date(milliseconds).getTime())) throw new Error("invalid reset");
    windows.push({ id, durationMinutes, usedPercent: window.utilization,
      resetsAt: milliseconds === null ? null : new Date(milliseconds).toISOString(), expired: false, ...(label ? { label } : {}) });
  };
  try {
    for (const [key, window] of Object.entries(body.rate_limits)) {
      if (key === "model_scoped" || key === "extra_usage" || key === "spend") continue;
      if (!object(window) || !Object.hasOwn(window, "utilization") || !Object.hasOwn(window, "resets_at")) continue;
      const [id, duration] = knownWindows[key] || [`claude:${key}`, null];
      add(id, duration, window);
    }
    if (Array.isArray(body.rate_limits.model_scoped)) for (const window of body.rate_limits.model_scoped) {
      if (typeof window?.display_name === "string" && window.display_name) add(`claude:model:${window.display_name}`, null, window, window.display_name);
    }
  } catch { return failed("invalidResponse"); }
  return { state: "ok", source: "service", observedAt: new Date().toISOString(),
    ...(typeof body.subscription_type === "string" ? { plan: body.subscription_type } : {}), windows };
}

/** Ask Claude Code to handle its own sign-in. No prompt or user message is sent. */
export async function readClaudeLimits(runtime, directory) {
  if (typeof runtime.claude !== "string" || !runtime.claude.startsWith("/")) return unavailable("programMissing");
  return new Promise(resolve => {
    const child = spawn(runtime.claude, ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
      "--verbose", "--no-session-persistence", "--strict-mcp-config", "--settings", '{"disableAllHooks":true}'], {
      cwd: directory, env: Object.fromEntries(Object.entries(runtime.env).filter(([, value]) => typeof value === "string")),
      stdio: ["pipe", "pipe", "pipe"],
    });
    let result;
    let stage = "init";
    let buffer = "";
    let bytes = 0;
    const finish = value => {
      if (result) return;
      result = value;
      clearTimeout(timer);
      child.stdin.end();
      child.kill("SIGKILL");
    };
    const timer = setTimeout(() => finish(failed("timeout")), 15_000);
    const send = (request_id, request) => child.stdin.write(JSON.stringify({ type: "control_request", request_id, request }) + "\n");
    child.stdin.on("error", () => { /* Exit/error closes the request below. */ });
    child.stderr.resume();
    child.on("error", error => finish(error.code === "ENOENT" || error.code === "EACCES"
      ? unavailable("programMissing") : failed("requestFailed")));
    child.on("close", code => {
      clearTimeout(timer);
      resolve(result || (code === 126 || code === 127 ? unavailable("programMissing") : failed("requestFailed")));
    });
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", chunk => {
      if (result) return;
      bytes += Buffer.byteLength(chunk);
      if (bytes > 1024 * 1024) { finish(failed("invalidResponse")); return; }
      buffer += chunk;
      let end;
      while (!result && (end = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
        let message;
        try { message = JSON.parse(line); } catch { finish(failed("invalidResponse")); break; }
        if (message?.type !== "control_response" || message.response?.request_id !== stage) continue;
        const response = message.response;
        if (response.subtype === "error") {
          finish(typeof response.error === "string" && response.error.startsWith("Unsupported control request subtype")
            ? unavailable("programTooOld") : failed("requestFailed"));
        } else if (response.subtype !== "success") finish(failed("invalidResponse"));
        else if (stage === "init") { stage = "usage"; send(stage, { subtype: "get_usage", skip_behaviors: true }); }
        else finish(readingFrom(response.response));
      }
    });
    send(stage, { subtype: "initialize" });
  });
}

/** Failed requests retain the last good reading while the failure back-off runs. */
export function cacheClaudeLimits(previous, reading, now = Date.now()) {
  const nextAllowedAt = now + (reading.state === "error" ? 300_000 : 60_000);
  const lastGood = reading.state === "ok" ? reading : previous?.lastGood;
  const report = reading.state === "error" && lastGood
    ? { ...lastGood, state: "throttled", reason: reading.reason, retryAt: new Date(nextAllowedAt).toISOString() } : reading;
  return { report, nextAllowedAt, ...(lastGood ? { lastGood } : {}) };
}
