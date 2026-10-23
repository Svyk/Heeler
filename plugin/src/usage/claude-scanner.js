import { createReadStream } from "node:fs";
import { readdir, realpath, stat } from "node:fs/promises";
import { join, sep } from "node:path";

export async function claudeFiles(roots, cutoff) {
  const files = [];
  const seenDirectories = new Set();
  const seenFiles = new Set();
  async function visit(path) {
    let actual;
    try { actual = await realpath(path); } catch (error) { if (error.code === "ENOENT") return; throw error; }
    if (seenDirectories.has(actual)) return;
    seenDirectories.add(actual);
    const entries = await readdir(actual, { withFileTypes: true });
    for (const entry of entries) {
      const child = join(actual, entry.name);
      if (entry.isDirectory()) await visit(child);
      else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
        const metadata = await stat(child);
        if (metadata.mtimeMs < cutoff || seenFiles.has(child)) continue;
        seenFiles.add(child);
        files.push({ path: child, ...metadata });
      }
    }
  }
  for (const root of roots) await visit(join(root, "projects"));
  return files.sort((a, b) => b.mtimeMs - a.mtimeMs || a.path.localeCompare(b.path));
}
export async function* transcriptLines(path, onChunk = () => {}) {
  let carry = "";
  for await (const chunk of createReadStream(path, { encoding: "utf8" })) {
    onChunk();
    carry += chunk;
    let newline;
    while ((newline = carry.indexOf("\n")) >= 0) {
      const line = carry.slice(0, newline);
      carry = carry.slice(newline + 1);
      try { yield JSON.parse(line); } catch { /* Torn or unrelated malformed records are skipped. */ }
    }
  }
  // An incomplete final line belongs to the next refresh.
}
const count = value => Number.isFinite(value) && value >= 0 ? value : 0;
export function claudeContribution(line, path, cutoff, sessionDirectory) {
  if (line?.type !== "assistant" || !line.message?.usage || line.message.model === "<synthetic>" || typeof line.message.id !== "string") return null;
  const timestamp = typeof line.timestamp === "string" ? Date.parse(line.timestamp) : NaN;
  if (!Number.isFinite(timestamp) || timestamp < cutoff) return null;
  const usage = line.message.usage;
  const split = usage.cache_creation;
  const hasSplit = Number.isFinite(split?.ephemeral_5m_input_tokens) || Number.isFinite(split?.ephemeral_1h_input_tokens);
  const write5m = hasSplit ? count(split.ephemeral_5m_input_tokens) : count(usage.cache_creation_input_tokens);
  const write1h = hasSplit ? count(split.ephemeral_1h_input_tokens) : 0;
  const tokens = { input: count(usage.input_tokens), cacheRead: count(usage.cache_read_input_tokens), cacheWrite: write5m + write1h, output: count(usage.output_tokens), reasoning: 0 };
  tokens.total = tokens.input + tokens.cacheRead + tokens.cacheWrite + tokens.output;
  const sessionId = typeof line.sessionId === "string" ? line.sessionId : "";
  const requestId = typeof line.requestId === "string" && line.requestId ? line.requestId : null;
  const components = path.split(sep);
  const project = components[components.lastIndexOf("projects") + 1] || "unknown";
  const directory = typeof line.cwd === "string" ? line.cwd : sessionDirectory || project.replaceAll("-", "/");
  return {
    key: JSON.stringify(requestId ? ["claude", line.message.id, requestId] : ["claude", line.message.id, sessionId, line.timestamp]),
    group: JSON.stringify([line.message.id, sessionId]), sessionId, sidechain: line.isSidechain === true,
    program: "claude", model: typeof line.message.model === "string" ? line.message.model : "unknown", directory,
    timestamp, bucket: Math.floor(timestamp / 900_000) * 900_000, tokens, write5m, write1h, speed: usage.speed === "fast" ? "fast" : "standard",
  };
}
