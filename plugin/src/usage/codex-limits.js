import { spawn } from "node:child_process";

const unavailable = reason => ({ state: "unavailable", reason });
const failed = reason => ({ state: "error", reason });
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);

function windowsFrom(group, observedAt) {
  if (!object(group)) return null;
  const windows = [];
  let recognized = false;
  for (const id of ["primary", "secondary"]) {
    if (!Object.hasOwn(group, id)) continue;
    recognized = true;
    const window = group[id];
    if (window === null) continue;
    if (!object(window)) return null;
    const usedPercent = window.usedPercent ?? window.used_percent;
    const durationMinutes = window.windowDurationMins ?? window.window_minutes ?? null;
    if (!Number.isFinite(usedPercent) || usedPercent < 0
        || (durationMinutes !== null && (!Number.isFinite(durationMinutes) || durationMinutes <= 0))) return null;
    const reset = window.resetsAt ?? window.resets_at ?? null;
    let resetMilliseconds = reset === null ? null : Number.isFinite(reset) ? reset * 1000 : NaN;
    if (reset === null && Number.isFinite(window.resets_in_seconds)) resetMilliseconds = Date.parse(observedAt) + window.resets_in_seconds * 1000;
    if (resetMilliseconds !== null && !Number.isFinite(new Date(resetMilliseconds).getTime())) return null;
    windows.push({ id, durationMinutes, usedPercent,
      resetsAt: resetMilliseconds === null ? null : new Date(resetMilliseconds).toISOString(), expired: false });
  }
  return recognized ? windows : null;
}

/** Evaluate expiry for each query, even while a cached service reading is fresh. */
export function expireLimitWindows(reading, now = Date.now()) {
  if (!reading?.windows) return reading;
  return { ...reading, windows: reading.windows.map(window => {
    const expired = window.resetsAt !== null && Date.parse(window.resetsAt) <= now;
    return { ...window, expired, usedPercent: expired ? null : window.usedPercent };
  }) };
}

/** Retain only the default group's allowed fields from a Transcript event. */
export function codexRolloutLimits(line) {
  if (line?.type !== "event_msg" || line.payload?.type !== "token_count") return null;
  const group = line.payload.rate_limits;
  if (!object(group) || (group.limit_id != null && group.limit_id !== "codex")) return null;
  const timestamp = Date.parse(line.timestamp);
  if (!Number.isFinite(timestamp)) return null;
  const observedAt = new Date(timestamp).toISOString();
  const windows = windowsFrom(group, observedAt);
  if (windows === null) return null;
  const plan = group.plan_type ?? group.planType;
  return { state: "ok", source: "lastSession", observedAt, ...(typeof plan === "string" ? { plan } : {}), windows };
}

export function codexLimitsWithFallback(service, fallback) {
  return service.state === "ok" || service.reason === "noPlanLimits" ? service : fallback || service;
}

/** Ask the user's program over its local control protocol; never read its sign-in. */
export async function readCodexLimits(runtime, directory) {
  if (typeof runtime.codex !== "string" || !runtime.codex.startsWith("/")) return unavailable("programMissing");
  return new Promise(resolve => {
    const child = spawn(runtime.codex, ["-s", "read-only", "-a", "never", "app-server"], {
      cwd: directory, env: Object.fromEntries(Object.entries(runtime.env).filter(([, value]) => typeof value === "string")),
      stdio: ["pipe", "pipe", "pipe"],
    });
    let result;
    let plan;
    let stage = 1;
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
    const send = message => child.stdin.write(JSON.stringify(message) + "\n");
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
        const line = buffer.slice(0, end);
        buffer = buffer.slice(end + 1);
        let message;
        try { message = JSON.parse(line); } catch { finish(failed("invalidResponse")); break; }
        if (!object(message) || message.id !== stage) continue;
        if (message.error) {
          finish(message.error.code === -32601 ? unavailable("programTooOld") : failed("requestFailed"));
          break;
        }
        if (!Object.hasOwn(message, "result")) { finish(failed("invalidResponse")); break; }
        if (stage === 1) {
          stage = 2;
          send({ method: "initialized" });
          send({ id: 2, method: "account/read", params: {} });
        } else if (stage === 2) {
          const account = object(message.result) && Object.hasOwn(message.result, "account") ? message.result.account : message.result;
          if (account === null) { finish(unavailable("notSignedIn")); break; }
          if (!object(account) || typeof account.type !== "string") { finish(failed("invalidResponse")); break; }
          if (account.type !== "chatgpt") { finish(unavailable("noPlanLimits")); break; }
          const reportedPlan = account.planType ?? account.plan_type;
          if (typeof reportedPlan === "string") plan = reportedPlan;
          stage = 3;
          send({ id: 3, method: "account/rateLimits/read" });
        } else {
          const observedAt = new Date().toISOString();
          const windows = windowsFrom(message.result?.rateLimits ?? message.result?.rate_limits, observedAt);
          finish(windows === null ? failed("invalidResponse") : {
            state: "ok", source: "service", observedAt, ...(plan ? { plan } : {}), windows,
          });
        }
      }
    });
    send({ id: 1, method: "initialize", params: { clientInfo: { name: "heeler", version: "0.7.0" } } });
  });
}
