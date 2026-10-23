import { expireLimitWindows } from "./codex-limits.js";

export const zeroTokens = () => ({ input: 0, cacheRead: 0, cacheWrite: 0, output: 0, reasoning: 0, total: 0 });
export function addTokens(target, tokens, multiplier = 1) {
  for (const key of Object.keys(target)) target[key] += (tokens[key] || 0) * multiplier;
}
export function contributionBucket(record) {
  return JSON.stringify([record.bucket, record.program, record.model]);
}
export function changeBucket(buckets, record, multiplier) {
  const key = contributionBucket(record);
  let bucket = buckets.get(key);
  if (!bucket) {
    bucket = { timestamp: record.bucket, program: record.program, model: record.model, tokens: zeroTokens() };
    buckets.set(key, bucket);
  }
  addTokens(bucket.tokens, record.tokens, multiplier);
  if (bucket.tokens.total === 0) buckets.delete(key);
}
export function dayInZone(timestamp, timeZone) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date(timestamp)).map(part => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}
export function reportFromSnapshot(snapshot, timeZone, refreshing, now = Date.now()) {
  const today = dayInZone(now, timeZone);
  const dates = Array.from({ length: 30 }, (_, index) => new Date(Date.parse(today + "T12:00:00Z") - (29 - index) * 86_400_000).toISOString().slice(0, 10));
  const programs = ["claude", "codex"].map(program => {
    const daily = dates.map(date => ({ date, tokens: zeroTokens() }));
    const byDay = new Map(daily.map(day => [day.date, day]));
    let hasData = false;
    for (const bucket of snapshot?.buckets || []) {
      if (bucket.program !== program) continue;
      const day = byDay.get(dayInZone(bucket.timestamp, timeZone));
      if (day) { addTokens(day.tokens, bucket.tokens); hasData = true; }
    }
    const sum = entries => {
      const tokens = zeroTokens();
      for (const entry of entries) addTokens(tokens, entry.tokens);
      return { tokens };
    };
    return { program, tokenUsage: snapshot?.errors?.[program] ? { state: "error", reason: snapshot.errors[program] } : hasData ? {
      state: "ok", totals: { today: sum(daily.slice(-1)), last7Days: sum(daily.slice(-7)), last30Days: sum(daily) }, daily,
    } : { state: "noData" }, usageLimits: program === "claude" ? { state: "disabled" }
      : expireLimitWindows(snapshot?.usageLimits?.codex || { state: "unavailable", reason: "programMissing" }, now) };
  });
  const covered = (snapshot?.buckets || []).map(bucket => dayInZone(bucket.timestamp, timeZone)).filter(date => date >= dates[0] && date <= today).sort()[0] || null;
  return { version: 1, generatedAt: new Date(now).toISOString(), timeZone, runtime: "recorded", refreshing,
    scan: { state: snapshot?.complete ? "complete" : "partial", coveredFrom: covered, coveredThrough: snapshot?.coveredThrough || null, skippedArchives: snapshot?.skippedArchives || 0 }, programs };
}
