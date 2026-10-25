#!/usr/bin/env node
import { parseArgs } from "node:util";
import { appendFileSync, lstatSync, mkdirSync, readdirSync, rmSync, statSync } from "node:fs";
import { join, sep } from "node:path";
import { setPriority } from "node:os";
import { readUsageRuntime } from "./usage-runtime.js";
import { cacheDirectory, usageRoots, readJSON, writeJSON, releaseWorker, activeLock, recordFailure, clearFailures, RETENTION } from "./usage/cache.js";
import { claudeFiles, transcriptEntries, claudeContribution } from "./usage/claude-scanner.js";
import { loadCheckpoint, startLog, saveCheckpoint, matchFiles } from "./usage/checkpoint.js";
import { changeBucket } from "./usage/buckets.js";
import { priceContribution, pricingVersion } from "./usage/pricing.js";
import { codexFiles, codexLines, ArchiveUnavailableError } from "./usage/codex-files.js";
import { createCodexState, consumeCodexLine, finishCodexRead, codexTotalSignature } from "./usage/codex-scanner.js";
import { readCodexLimits, codexRolloutLimits, codexLimitsWithFallback } from "./usage/codex-limits.js";
import { readClaudeLimits, cacheClaudeLimits } from "./usage/claude-limits.js";

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
class LockLostError extends Error {}
/** The cache or lock could not be written: the run fails, unlike one unreadable Transcript. */
class CacheWriteError extends Error {}
const cacheWrite = write => {
  try { return write(); } catch (error) { throw new CacheWriteError("Could not write the usage cache.", { cause: error }); }
};
const runFailure = error => error instanceof LockLostError || error instanceof CacheWriteError;
/** A cache's last write: its snapshot, or, before a first commit, its newest entry. */
function lastWritten(directory) {
  try { return statSync(join(directory, "buckets.json")).mtimeMs; }
  catch (error) { if (error.code !== "ENOENT") throw error; }
  let newest = lstatSync(directory).mtimeMs;
  for (const name of readdirSync(directory)) newest = Math.max(newest, lstatSync(join(directory, name)).mtimeMs);
  return newest;
}
async function run() {
  const { values } = parseArgs({ options: { config: { type: "string" }, "lock-token": { type: "string" }, "claude-limits": { type: "boolean", default: false } } });
  try { setPriority(10); } catch { /* Lower priority is best effort on the Host. */ }
  const runtime = readUsageRuntime(values.config);
  if (!runtime) return;
  const directory = cacheDirectory(runtime);
  const lockPath = join(directory, "worker.lock");
  let lock;
  for (let i = 0; i < 100; i++) {
    lock = readJSON(lockPath);
    if (lock?.token !== values["lock-token"]) return;
    if (lock.pid === process.pid) break;
    await sleep(10);
  }
  if (lock?.pid !== process.pid) return;
  const heartbeat = () => {
    if (readJSON(lockPath)?.token !== lock.token) throw new LockLostError("worker lock lost");
    lock.heartbeat = Date.now();
    cacheWrite(() => writeJSON(lockPath, lock));
  };
  try {
    const now = Date.now();
    const cutoff = now - RETENTION;
    const roots = usageRoots(runtime);
    for (const name of readdirSync(join(runtime.stateDir, "usage"))) {
      const sibling = join(runtime.stateDir, "usage", name);
      if (sibling === directory) continue;
      try { if (lastWritten(sibling) < cutoff && !activeLock(sibling)) rmSync(sibling, { recursive: true, force: true }); }
      catch { /* An unreadable sibling is left for its owner. */ }
    }
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    const previousSnapshot = readJSON(join(directory, "buckets.json"));
    const limits = readJSON(join(directory, "limits.json")) || {};
    const maintainHeartbeat = () => { if (Date.now() - lock.heartbeat >= 1000) heartbeat(); };
    const previous = await loadCheckpoint(directory, previousSnapshot, maintainHeartbeat);
    const errors = {};
    const files = [];
    const unlistedPaths = [];
    const failedPrograms = new Set();
    // One unreadable entry is skipped and counted; only a root that cannot be
    // listed hides its program. Neither makes its known files look deleted.
    for (const [program, list, programRoots, reason] of [
      ["claude", claudeFiles, roots.claude, "Could not read the Claude Code Transcripts."],
      ["codex", codexFiles, roots.codex, "Could not read the Codex Transcripts."],
    ]) {
      let listing;
      try { listing = await list(programRoots, cutoff); } catch { listing = { files: [], unreadable: [], rootFailed: true }; }
      files.push(...listing.files.map(file => ({ ...file, program })));
      unlistedPaths.push(...listing.unreadable);
      if (listing.rootFailed) { failedPrograms.add(program); errors[program] = reason; }
    }
    files.sort((a, b) => b.mtimeMs - a.mtimeMs || a.path.localeCompare(b.path));
    const match = matchFiles(files, previous?.files || {}, now, (path, state) => failedPrograms.has(state.program)
      || unlistedPaths.some(unlisted => path === unlisted || path.startsWith(unlisted + sep)));
    const rebuilding = !previous || match.rebuild || previousSnapshot?.limitsVersion !== 1;
    const preserveSnapshot = previousSnapshot !== null && (rebuilding || previousSnapshot.rebuilding);
    const buckets = rebuilding ? new Map() : previous.buckets;
    const keys = rebuilding ? new Map() : previous.keys;
    const groups = rebuilding ? new Map() : previous.groups;
    const keysPath = join(directory, "keys.log");
    const generation = rebuilding || previous.expired ? startLog(keysPath, keys, groups) : previous.generation;
    const fileStates = rebuilding ? {} : match.states;
    const snapshot = complete => {
      heartbeat();
      // Commit parser progress even when a rebuild is still resolving a burst.
      // The query keeps the old aggregates; the next worker resumes the new log.
      const progress = { generatedAt: new Date().toISOString(), coveredThrough: new Date(now).toISOString(),
        complete, pricingVersion, breakdownsVersion: 1, buckets: [...buckets.values()], errors,
        limitsVersion: 1, usageLimits: { codex: limits.codex?.report, claude: limits.claude?.report },
        nextLimitsAt: limits.codex?.nextAllowedAt, nextClaudeLimitsAt: limits.claude?.nextAllowedAt,
        skippedArchives: Object.values(fileStates).filter(file => file.skipped).length,
        unreadableFiles: unlistedPaths.length + files.filter(file => fileStates[file.logicalPath || file.path]?.unreadable).length };
      cacheWrite(() => saveCheckpoint(directory, fileStates, generation, preserveSnapshot && !complete
        ? { ...previousSnapshot, complete: false, rebuilding: true, limitsVersion: 1,
          usageLimits: progress.usageLimits, nextLimitsAt: progress.nextLimitsAt, nextClaudeLimitsAt: progress.nextClaudeLimitsAt }
        : { ...progress, rebuilding: false }));
    };
    const appendKey = record => cacheWrite(() => appendFileSync(keysPath, JSON.stringify(record) + "\n"));
    const threads = new Map();
    const parentTotals = new Map();
    let pendingPrefix = false;
    // Old copied forks may be read before their parent in newest-first order.
    // Index headers without loading Transcript content into the query snapshot.
    for (const file of files.filter(file => file.program === "codex")) {
      const saved = fileStates[file.logicalPath];
      if (saved?.carry.threadId || saved?.finished) {
        if (saved.carry.threadId && !threads.has(saved.carry.threadId)) threads.set(saved.carry.threadId, file);
        continue;
      }
      try {
        for await (const { line } of codexLines(file, runtime, maintainHeartbeat)) {
          if (line?.type === "session_meta" && typeof line.payload?.id === "string" && !threads.has(line.payload.id)) threads.set(line.payload.id, file);
          break;
        }
      } catch (error) { if (runFailure(error)) throw error; /* The main pass reports unavailable or unreadable archives. */ }
    }
    const totalsForParent = async id => {
      if (!id || !threads.has(id)) return null;
      if (!parentTotals.has(id)) {
        const totals = [];
        try {
          for await (const { line } of codexLines(threads.get(id), runtime, maintainHeartbeat)) {
            if (line?.type === "event_msg" && line.payload?.type === "token_count" && line.payload.info?.total_token_usage) totals.push(codexTotalSignature(line.payload.info.total_token_usage));
          }
          parentTotals.set(id, totals);
        } catch (error) { if (runFailure(error)) throw error; parentTotals.set(id, null); }
      }
      return parentTotals.get(id);
    };
    let processed = 0;
    for (const file of files) {
      const logicalPath = file.logicalPath || file.path;
      const state = fileStates[logicalPath] ||= { dev: file.dev, ino: file.ino, size: file.size, mtimeMs: file.mtimeMs,
        program: file.program, compressed: Boolean(file.compressed), offset: 0, finished: false,
        carry: file.program === "codex" ? createCodexState(logicalPath) : {} };
      if (state.finished && !state.carry.pending?.length) continue;
      if (file.program === "codex") {
        const carry = state.carry;
        let parent = carry.parentId && !carry.inheritedEnded ? await totalsForParent(carry.parentId) : null;
        const countContributions = contributions => {
          let due = false;
          for (const contribution of contributions) {
            const candidate = priceContribution(contribution);
            if (keys.has(candidate.key)) continue;
            keys.set(candidate.key, candidate);
            changeBucket(buckets, candidate, 1);
            appendKey(candidate);
            processed++;
            due ||= processed % 1000 === 0;
          }
          // The offset already points past this line: commit only at a line boundary.
          if (due) snapshot(false);
        };
        try {
          if (!state.finished) for await (const entry of codexLines(file, runtime, maintainHeartbeat, state.offset)) {
            state.offset = entry.offset;
            const reading = codexRolloutLimits(entry.line);
            if (reading && (!carry.latestLimits || reading.observedAt >= carry.latestLimits.observedAt)) carry.latestLimits = reading;
            countContributions(consumeCodexLine(carry, entry.line, state.offset, cutoff, parent));
            if (carry.parentId && parent === null) parent = await totalsForParent(carry.parentId);
          }
          countContributions(finishCodexRead(carry, Date.now(), parent));
          pendingPrefix ||= carry.pending.length > 0;
          state.finished = true;
          state.skipped = false;
          state.unreadable = false;
        } catch (error) {
          if (runFailure(error)) throw error;
          // The file stays unfinished and is retried by the next run.
          if (error instanceof ArchiveUnavailableError) state.skipped = true;
          else state.unreadable = true;
        }
        snapshot(false);
        continue;
      }
      try {
        if (!state.finished) for await (const { line, offset } of transcriptEntries(file.path, maintainHeartbeat, state.offset)) {
          state.offset = offset;
          if (typeof line?.cwd === "string") state.carry.directory = line.cwd;
          const contribution = claudeContribution(line, file.path, cutoff, state.carry.directory);
          if (!contribution) continue;
          const candidate = priceContribution(contribution);
          const peers = groups.get(candidate.group) || new Set();
          groups.set(candidate.group, peers);
          const existing = keys.get(candidate.key);
          if (!peers.has(candidate.key)) {
            peers.add(candidate.key);
            appendKey({ alias: { group: candidate.group, key: candidate.key } });
          }
          const siblings = [...peers].map(key => keys.get(key)).filter(Boolean);
          if (candidate.sidechain && siblings.some(record => !record.sidechain)) continue;
          const collisions = [existing, ...siblings.filter(record => record.sidechain)].filter(Boolean);
          // A stable final comparison makes even equal-size streamed copies order independent.
          const collisionFields = ({ estimatedCostUSD, unpricedTokens, ...record }) => JSON.stringify(record);
          const preferred = (a, b) => Number(!a.sidechain) - Number(!b.sidechain) || a.tokens.total - b.tokens.total || collisionFields(a).localeCompare(collisionFields(b));
          const winner = collisions.reduce((best, record) => preferred(record, best) >= 0 ? record : best, candidate);
          const removed = [...new Set(collisions.filter(record => record !== winner && (winner === candidate || !candidate.sidechain)).map(record => record.key))];
          for (const key of removed) {
            const old = keys.get(key);
            if (old) { changeBucket(buckets, old, -1); keys.delete(key); }
          }
          if (winner !== candidate) {
            if (removed.length) appendKey({ replaces: removed });
            continue;
          }
          keys.set(candidate.key, candidate);
          changeBucket(buckets, candidate, 1);
          appendKey({ ...candidate, replaces: removed });
          processed++;
          if (processed % 1000 === 0) snapshot(false);
        }
        state.finished = true;
        state.unreadable = false;
      } catch (error) {
        if (runFailure(error)) throw error;
        state.unreadable = true;
      }
      snapshot(false);
    }
    snapshot(!pendingPrefix);
    // Reserve each program's cadence before starting it, so a worker that dies
    // mid-read still throttles the next one.
    if (!limits.codex || !Number.isFinite(limits.codex.nextAllowedAt) || Date.now() >= limits.codex.nextAllowedAt) {
      limits.codex = { ...limits.codex, nextAllowedAt: Date.now() + 60_000 };
      writeJSON(join(directory, "limits.json"), limits);
      limits.codex = { service: await readCodexLimits(runtime, directory), nextAllowedAt: Date.now() + 60_000 };
      heartbeat();
    }
    if (values["claude-limits"] && (!limits.claude || !Number.isFinite(limits.claude.nextAllowedAt) || Date.now() >= limits.claude.nextAllowedAt)) {
      limits.claude = { ...limits.claude, nextAllowedAt: Date.now() + 60_000 };
      writeJSON(join(directory, "limits.json"), limits);
      limits.claude = cacheClaudeLimits(limits.claude, await readClaudeLimits(runtime, directory));
      heartbeat();
    }
    const fallback = Object.values(fileStates).map(file => file.carry.latestLimits).filter(Boolean)
      .sort((a, b) => b.observedAt.localeCompare(a.observedAt))[0];
    // A reservation whose read never finished has no reading of its own.
    limits.codex.report = codexLimitsWithFallback(limits.codex.service || limits.codex.report
      || { state: "error", reason: "requestFailed" }, fallback);
    writeJSON(join(directory, "limits.json"), limits);
    snapshot(!pendingPrefix);
    clearFailures(directory);
  } catch (error) {
    // A displaced worker did not fail; its successor owns the refresh.
    if (!(error instanceof LockLostError)) {
      try { recordFailure(directory); } catch { /* The query's own writes fail too. */ }
    }
    throw error;
  } finally { releaseWorker(directory, values["lock-token"]); }
}
try { await run(); } catch { process.exitCode = 1; }
