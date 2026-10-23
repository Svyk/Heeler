#!/usr/bin/env node
import { parseArgs } from "node:util";
import { appendFileSync, mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { setPriority } from "node:os";
import { readUsageRuntime } from "./usage-runtime.js";
import { cacheDirectory, usageRoots, readJSON, writeJSON, releaseWorker, RETENTION } from "./usage/cache.js";
import { claudeFiles, transcriptLines, claudeContribution } from "./usage/claude-scanner.js";
import { changeBucket } from "./usage/buckets.js";
import { codexFiles, codexLines, ArchiveUnavailableError } from "./usage/codex-files.js";
import { createCodexState, consumeCodexLine, finishCodexRead, codexTotalSignature } from "./usage/codex-scanner.js";

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function run() {
  const { values } = parseArgs({ options: { config: { type: "string" }, "lock-token": { type: "string" } } });
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
    if (readJSON(lockPath)?.token !== lock.token) throw new Error("worker lock lost");
    lock.heartbeat = Date.now();
    writeJSON(lockPath, lock);
  };
  try {
    const now = Date.now();
    const cutoff = now - RETENTION;
    const roots = usageRoots(runtime);
    for (const name of readdirSync(join(runtime.stateDir, "usage"))) {
      const sibling = join(runtime.stateDir, "usage", name);
      if (sibling === directory) continue;
      try { if (statSync(join(sibling, "buckets.json")).mtimeMs < cutoff) rmSync(sibling, { recursive: true, force: true }); }
      catch { /* Incomplete sibling caches are left for their owner. */ }
    }
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    const buckets = new Map();
    const keys = new Map();
    const groups = new Map();
    const keysPath = join(directory, "keys.log");
    writeFileSync(keysPath, "", { mode: 0o600 });
    const errors = {};
    let skippedArchives = 0;
    const snapshot = complete => {
      heartbeat();
      writeJSON(join(directory, "buckets.json"), { generatedAt: new Date().toISOString(), coveredThrough: new Date(now).toISOString(), complete, buckets: [...buckets.values()], errors, skippedArchives });
    };
    snapshot(false);
    let files = [];
    try { files = (await claudeFiles(roots.claude, cutoff)).map(file => ({ ...file, program: "claude" })); }
    catch { errors.claude = "Could not read the Claude Code Transcripts."; }
    try { files.push(...(await codexFiles(roots.codex, cutoff)).map(file => ({ ...file, program: "codex" }))); }
    catch { errors.codex = "Could not read the Codex Transcripts."; }
    files.sort((a, b) => b.mtimeMs - a.mtimeMs || a.path.localeCompare(b.path));
    const threads = new Map();
    const parentTotals = new Map();
    const fileStates = {};
    let pendingPrefix = false;
    const maintainHeartbeat = () => { if (Date.now() - lock.heartbeat >= 1000) heartbeat(); };
    // Old copied forks may be read before their parent in newest-first order.
    // Index headers without loading Transcript content into the query snapshot.
    for (const file of files.filter(file => file.program === "codex")) {
      try {
        for await (const { line } of codexLines(file, runtime, maintainHeartbeat)) {
          if (line?.type === "session_meta" && typeof line.payload?.id === "string" && !threads.has(line.payload.id)) threads.set(line.payload.id, file);
          break;
        }
      } catch { /* The main pass reports unavailable or unreadable archives. */ }
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
        } catch { parentTotals.set(id, null); }
      }
      return parentTotals.get(id);
    };
    let processed = 0;
    for (const file of files) {
      if (file.program === "codex") {
        const carry = createCodexState(file.logicalPath);
        let offset = 0;
        let parent = null;
        const countContributions = contributions => {
          for (const candidate of contributions) {
            if (keys.has(candidate.key)) continue;
            keys.set(candidate.key, candidate);
            changeBucket(buckets, candidate, 1);
            appendFileSync(keysPath, JSON.stringify(candidate) + "\n");
            processed++;
            if (processed % 1000 === 0) snapshot(false);
          }
        };
        try {
          for await (const entry of codexLines(file, runtime, maintainHeartbeat)) {
            offset = entry.offset;
            countContributions(consumeCodexLine(carry, entry.line, offset, cutoff, parent));
            if (carry.parentId && parent === null) parent = await totalsForParent(carry.parentId);
          }
          countContributions(finishCodexRead(carry, Date.now(), parent));
          pendingPrefix ||= carry.pending.length > 0;
          fileStates[file.logicalPath] = { dev: file.dev, ino: file.ino, size: file.size, mtimeMs: file.mtimeMs, offset, carry };
          writeJSON(join(directory, "files.json"), fileStates);
        } catch (error) {
          if (error instanceof ArchiveUnavailableError) skippedArchives++;
          else errors.codex = "Could not read the Codex Transcripts.";
        }
        snapshot(false);
        continue;
      }
      let sessionDirectory;
      try {
        for await (const line of transcriptLines(file.path, () => {
          if (Date.now() - lock.heartbeat >= 1000) heartbeat();
        })) {
          if (typeof line?.cwd === "string") sessionDirectory = line.cwd;
          const candidate = claudeContribution(line, file.path, cutoff, sessionDirectory);
          if (!candidate) continue;
          const peers = groups.get(candidate.group) || new Set();
          groups.set(candidate.group, peers);
          const existing = keys.get(candidate.key);
          if (!peers.has(candidate.key)) {
            peers.add(candidate.key);
            appendFileSync(keysPath, JSON.stringify({ alias: { group: candidate.group, key: candidate.key } }) + "\n");
          }
          const siblings = [...peers].map(key => keys.get(key)).filter(Boolean);
          if (candidate.sidechain && siblings.some(record => !record.sidechain)) continue;
          const collisions = [existing, ...siblings.filter(record => record.sidechain)].filter(Boolean);
          // A stable final comparison makes even equal-size streamed copies order independent.
          const preferred = (a, b) => Number(!a.sidechain) - Number(!b.sidechain) || a.tokens.total - b.tokens.total || JSON.stringify(a).localeCompare(JSON.stringify(b));
          const winner = collisions.reduce((best, record) => preferred(record, best) >= 0 ? record : best, candidate);
          const removed = [...new Set(collisions.filter(record => record !== winner && (winner === candidate || !candidate.sidechain)).map(record => record.key))];
          for (const key of removed) {
            const old = keys.get(key);
            if (old) { changeBucket(buckets, old, -1); keys.delete(key); }
          }
          if (winner !== candidate) {
            if (removed.length) appendFileSync(keysPath, JSON.stringify({ replaces: removed }) + "\n");
            continue;
          }
          keys.set(candidate.key, candidate);
          changeBucket(buckets, candidate, 1);
          appendFileSync(keysPath, JSON.stringify({ ...candidate, replaces: removed }) + "\n");
          processed++;
          if (processed % 1000 === 0) snapshot(false);
        }
      } catch {
        errors.claude = "Could not read the Claude Code Transcripts.";
      }
      snapshot(false);
    }
    snapshot(!pendingPrefix);
  } finally { releaseWorker(directory, values["lock-token"]); }
}
try { await run(); } catch { process.exitCode = 1; }
