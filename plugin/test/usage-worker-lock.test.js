import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, existsSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { reserveWorker, releaseWorker, startTimeFromStat } from "../src/usage/cache.js";

const plugin = fileURLToPath(new URL("..", import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };

// A Host without `ps` or procfs: every start-time lookup fails as it would there.
const withoutProcessStart = `
import { createRequire, syncBuiltinESMExports } from "node:module";
const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const fs = require("node:fs");
const { spawnSync } = childProcess;
const { readFileSync } = fs;
const missing = () => Object.assign(new Error("ENOENT"), { code: "ENOENT" });
childProcess.spawnSync = (file, ...rest) => /(^|\\/)ps$/.test(String(file))
  ? { pid: 0, output: [], stdout: "", stderr: "", status: null, signal: null, error: missing() } : spawnSync(file, ...rest);
fs.readFileSync = (file, ...rest) => { if (String(file).startsWith("/proc/")) throw missing(); return readFileSync(file, ...rest); };
syncBuiltinESMExports();
`;

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "heeler-worker-lock-"));
  const env = { PATH: "/usr/bin:/bin", HOME: join(root, "home"), CLAUDE_CONFIG_DIR: join(root, "claude"),
    HERDR_PLUGIN_CONFIG_DIR: join(root, "config"), HERDR_PLUGIN_STATE_DIR: join(root, "state"), HERDR_BIN_PATH: "/missing" };
  const preload = join(root, "without-process-start.mjs");
  writeFileSync(preload, withoutProcessStart);
  const launches = join(root, "codex-launches");
  const spawned = [];
  assert.equal(spawnSync(process.execPath, [join(plugin, "src", "sidebar-hook.js")], { env, encoding: "utf8" }).status, 0);
  const runtimePath = join(env.HERDR_PLUGIN_CONFIG_DIR, "runtime.json");
  /** Record each Codex launch; the first one stays in its limits read for `hang` ms. */
  const codexStub = hang => {
    const executable = join(root, "codex-stub");
    writeFileSync(executable, `#!${process.execPath}
const fs = require('node:fs');
const first = !fs.existsSync(${JSON.stringify(launches)});
fs.appendFileSync(${JSON.stringify(launches)}, process.pid + '\\n');
setTimeout(() => process.exit(1), first ? ${hang} : 0);
`, { mode: 0o755 });
    const runtime = JSON.parse(readFileSync(runtimePath, "utf8"));
    runtime.codex = executable;
    writeFileSync(runtimePath, JSON.stringify(runtime));
  };
  const codexLaunches = () => existsSync(launches) ? readFileSync(launches, "utf8").trim().split("\n").map(Number) : [];
  const query = ({ processStart = true } = {}) => {
    const result = spawnSync(process.execPath, [...(processStart ? [] : ["--import", preload]), join(plugin, "src", "usage-query.js"), "--tz", "UTC"],
      { env, encoding: "utf8", timeout: 10_000 });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  };
  const cache = () => join(env.HERDR_PLUGIN_STATE_DIR, "usage", readdirSync(join(env.HERDR_PLUGIN_STATE_DIR, "usage"))[0]);
  const lock = () => { try { return JSON.parse(readFileSync(join(cache(), "worker.lock"), "utf8")); } catch { return null; } };
  const finish = async options => {
    for (let i = 0; i < 300; i++) {
      const report = query(options);
      if (!report.refreshing) return report;
      await sleep(20);
    }
    assert.fail("worker did not finish");
  };
  const stale = () => {
    const path = join(cache(), "buckets.json");
    const snapshot = JSON.parse(readFileSync(path, "utf8"));
    snapshot.generatedAt = new Date(Date.now() - 61_000).toISOString();
    writeFileSync(path, JSON.stringify(snapshot));
  };
  /** A long-lived process that stands in for a running owner. */
  const sleeper = () => {
    const child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
    spawned.push(child.pid);
    return child.pid;
  };
  t.after(() => {
    for (const pid of [...spawned, ...codexLaunches(), lock()?.pid]) {
      if (pid && pid !== process.pid && alive(pid)) try { process.kill(pid, "SIGKILL"); } catch { /* Already gone. */ }
    }
    rmSync(root, { recursive: true, force: true });
  });
  return { root, env, query, cache, lock, finish, stale, sleeper, codexStub, codexLaunches };
}

test("the Linux start time is field 22 even when the command name holds spaces and parentheses", () => {
  const fields = ["S", "1", "4242", "4242", "0", "-1", "4194560", "120", "0", "0", "0", "10", "5", "0", "0", "20", "0", "11", "0", "987654", "123456"];
  assert.equal(startTimeFromStat(`4242 (node) ${fields.join(" ")} 789\n`), "987654");
  assert.equal(startTimeFromStat(`4242 (a) b (c) ) ${fields.join(" ")}\n`), "987654");
  assert.equal(startTimeFromStat("4242 (zombie) Z 1"), null);
  assert.equal(startTimeFromStat("not a stat line"), null);
});

test("without any start-time source a running worker keeps its lock and no second worker starts", async t => {
  const f = fixture(t);
  f.codexStub(1500);
  assert.equal(f.query({ processStart: false }).refreshing, true);
  for (let i = 0; i < 300 && f.codexLaunches().length === 0; i++) await sleep(10);
  const first = f.lock();
  assert.ok(first, "the worker holds its lock during the limits read");
  assert.equal(first.processStart, null);
  assert.notEqual(first.pid, process.pid);
  for (let i = 0; i < 3; i++) {
    assert.equal(f.query({ processStart: false }).refreshing, true);
    const current = f.lock();
    assert.equal(current?.token, first.token);
    assert.equal(current?.pid, first.pid);
    await sleep(50);
  }
  assert.equal((await f.finish({ processStart: false })).refreshing, false);
  assert.equal(f.codexLaunches().length, 1);
});

test("without any start-time source a dead or silent worker's lock is still reclaimed", async t => {
  const f = fixture(t);
  await f.finish();
  const path = join(f.cache(), "worker.lock");
  const owner = f.sleeper();
  const lock = { pid: owner, processStart: null, token: "no-start-time", heartbeat: Date.now() };
  for (const changes of [{ pid: 99999999 }, { heartbeat: Date.now() - 11 * 60_000 }]) {
    f.stale();
    writeFileSync(path, JSON.stringify({ ...lock, ...changes }));
    assert.equal(f.query({ processStart: false }).refreshing, true);
    assert.notEqual(f.lock()?.token, lock.token);
    assert.equal((await f.finish({ processStart: false })).scan.state, "complete");
  }
  f.stale();
  writeFileSync(path, JSON.stringify(lock));
  assert.equal(f.query({ processStart: false }).refreshing, true);
  assert.equal(f.lock()?.token, lock.token);
  rmSync(path);
});

test("an abandoned admission without a start time is reclaimed by pid or age", t => {
  const f = fixture(t);
  const directory = join(f.root, "admission");
  mkdirSync(directory);
  const admissionPath = join(directory, "worker-start.lock");
  const admission = changes => writeFileSync(admissionPath, JSON.stringify({ pid: 99999999, processStart: null, token: "abandoned", heartbeat: Date.now(), ...changes }));
  const reclaim = () => {
    assert.equal(reserveWorker(directory), null);
    assert.equal(existsSync(admissionPath), false);
    const lock = reserveWorker(directory);
    assert.ok(lock);
    releaseWorker(directory, lock.token);
  };
  admission();
  reclaim();
  // A live owner holds admission only briefly; past ten seconds it is abandoned too.
  admission({ pid: f.sleeper() });
  assert.equal(reserveWorker(directory), null);
  assert.equal(existsSync(admissionPath), true);
  const old = (Date.now() - 11_000) / 1000;
  utimesSync(admissionPath, old, old);
  reclaim();
});

test("a worker that dies during the Codex limits read leaves the read throttled", async t => {
  const f = fixture(t);
  f.codexStub(30_000);
  assert.equal(f.query().refreshing, true);
  for (let i = 0; i < 300 && f.codexLaunches().length === 0; i++) await sleep(10);
  assert.equal(f.codexLaunches().length, 1);
  const worker = f.lock().pid;
  process.kill(worker, "SIGKILL");
  process.kill(f.codexLaunches()[0], "SIGKILL");
  for (let i = 0; i < 300 && alive(worker); i++) await sleep(10);
  const report = await f.finish();
  assert.equal(f.codexLaunches().length, 1);
  assert.equal(report.programs.find(program => program.program === "codex").usageLimits.state, "error");
});
