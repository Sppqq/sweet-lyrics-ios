// Lyric translations for the app: Google's free web endpoint (Yandex when Google refuses) behind
// a cache in D1 shared by every install. A line anyone has had translated comes back at once and
// costs no request upstream; only lines nobody asked for yet count against a network's limit.

const LANGUAGES = new Set(["ru", "en", "uk", "de", "fr", "es", "it", "pt", "pl", "tr", "ja", "ko", "zh-Hans"]);
const MAX_LINES = 300;
const MAX_LINE = 500;
const MAX_BODY = 200_000;
// Characters of uncached lines one network may have translated per hour.
const MISS_CHARS_PER_HOUR = 60_000;
// A cached line nobody asked for in this long is dropped (nightly cron).
const KEEP_DAYS = 180;
// `used_at` is refreshed at most this often, so a hit is not a write every time.
const TOUCH_AFTER = 7 * 86400;
// Workers allow 50 subrequests per call; leave room for the rest.
const UPSTREAM_BUDGET = 40;
// D1 binds at most 100 values per statement.
const LOOKUP_CHUNK = 90;

export async function translate(request, env) {
  if (Number(request.headers.get("content-length") || 0) > MAX_BODY) return json({ error: "too big" }, 413);
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "body" }, 400);
  }
  const target = String(body?.target || "");
  if (!LANGUAGES.has(target)) return json({ error: "language" }, 400);
  if (!Array.isArray(body?.lines)) return json({ error: "lines" }, 400);
  // Exactly as sent: the app looks the answers up by the text it sent.
  const lines = [...new Set(body.lines.map((line) => String(line ?? "")).filter((line) => line.trim()))];
  if (!lines.length || lines.length > MAX_LINES || lines.some((line) => line.length > MAX_LINE)) {
    return json({ error: "lines" }, 400);
  }

  const now = Math.floor(Date.now() / 1000);
  const keys = await Promise.all(lines.map((line) => cacheKey(target, line)));
  const result = {};
  const stale = [];
  for (let i = 0; i < keys.length; i += LOOKUP_CHUNK) {
    const part = keys.slice(i, i + LOOKUP_CHUNK);
    const rows = (await env.DB.prepare(
      `SELECT key, text, translation, used_at FROM translations WHERE key IN (${part.map(() => "?").join(",")})`,
    ).bind(...part).all()).results;
    for (const row of rows) {
      result[row.text] = row.translation;
      if (row.used_at < now - TOUCH_AFTER) stale.push(row.key);
    }
  }
  const hits = Object.keys(result).length;

  let missing = lines.filter((line) => !(line in result));
  let limited = false;
  if (missing.length) {
    const chars = missing.reduce((sum, line) => sum + line.length, 0);
    const ipHash = await sha256Hex((request.headers.get("cf-connecting-ip") || "?") + (env.IP_SALT || env.ADMIN_TOKEN || "sl"));
    const hour = Math.floor(now / 3600);
    const used = await env.DB.prepare(
      `INSERT INTO translate_quota (ip_hash, hour, chars) VALUES (?, ?, ?)
       ON CONFLICT (ip_hash, hour) DO UPDATE SET chars = chars + excluded.chars RETURNING chars`,
    ).bind(ipHash, hour, chars).first();
    if ((used?.chars || 0) > MISS_CHARS_PER_HOUR) {
      limited = true;
      missing = [];
    }
  }

  let failure = null;
  const fresh = {};
  if (missing.length) {
    const budget = { left: UPSTREAM_BUDGET, error: null };
    Object.assign(fresh, await google(missing, target, budget));
    const left = missing.filter((line) => !(line in fresh));
    if (left.length && budget.left > 0) Object.assign(fresh, await yandex(left, target, budget));
    failure = budget.error;
    const statements = [];
    for (const [text, translation] of Object.entries(fresh)) {
      if (typeof translation !== "string" || !translation.trim()) continue;
      result[text] = translation;
      statements.push(env.DB.prepare(
        `INSERT OR REPLACE INTO translations (key, target, text, translation, created_at, used_at) VALUES (?, ?, ?, ?, ?, ?)`,
      ).bind(await cacheKey(target, text), target, text, translation, now, now));
    }
    for (let i = 0; i < statements.length; i += 50) await env.DB.batch(statements.slice(i, i + 50));
  }
  for (let i = 0; i < stale.length; i += LOOKUP_CHUNK) {
    const part = stale.slice(i, i + LOOKUP_CHUNK);
    await env.DB.prepare(`UPDATE translations SET used_at = ? WHERE key IN (${part.map(() => "?").join(",")})`)
      .bind(now, ...part).run();
  }

  // Nothing at all to give back: say why, so the app shows it and tries again later.
  if (!Object.keys(result).length) {
    if (limited) return json({ error: "slow down" }, 429);
    if (failure) {
      console.error("translate", String(failure));
      return json({ error: "upstream" }, 502);
    }
  }
  return json({ translations: result, cached: hits, limited });
}

/// Nightly: lines nobody asked for in KEEP_DAYS, and old hourly counters.
export async function pruneTranslations(env) {
  const now = Math.floor(Date.now() / 1000);
  await env.DB.prepare("DELETE FROM translations WHERE used_at < ?").bind(now - KEEP_DAYS * 86400).run();
  await env.DB.prepare("DELETE FROM translate_quota WHERE hour < ?").bind(Math.floor(now / 3600) - 48).run();
}

// MARK: Google

/// What it managed before an error (kept in `budget.error`) or the end of the budget.
async function google(lines, target, budget) {
  const result = {};
  try {
    for (const chunk of chunks(lines, 3500, 80)) {
      if (budget.left <= 0) break;
      // One request per chunk, a line per row; if the rows don't come back one for one, ask
      // for each line on its own.
      const rows = await googleRequest(chunk.join("\n"), target, budget);
      if (rows.length === chunk.length) {
        chunk.forEach((text, i) => { result[text] = rows[i]; });
      } else {
        for (const text of chunk) {
          if (budget.left <= 0) break;
          result[text] = (await googleRequest(text, target, budget)).join(" ");
        }
      }
    }
  } catch (error) {
    budget.error = error;
  }
  return result;
}

async function googleRequest(text, target, budget) {
  budget.left -= 1;
  const params = new URLSearchParams({ client: "gtx", sl: "auto", tl: target === "zh-Hans" ? "zh-CN" : target, dt: "t" });
  const response = await fetch(`https://translate.googleapis.com/translate_a/single?${params}`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded;charset=utf-8" },
    body: new URLSearchParams({ q: text }),
  });
  if (!response.ok) throw new Error(`google ${response.status}`);
  // [[["перевод\n", "original\n", …], …], …]: the translated pieces, in order.
  const root = await response.json();
  if (!Array.isArray(root) || !Array.isArray(root[0])) throw new Error("google unreadable");
  const joined = root[0].map((piece) => (Array.isArray(piece) && typeof piece[0] === "string" ? piece[0] : "")).join("");
  return joined.split("\n").map((row) => row.trim());
}

// MARK: Yandex

/// Lines Google left; an answer from here clears Google's error.
async function yandex(lines, target, budget) {
  const session = crypto.randomUUID().replaceAll("-", "");
  const result = {};
  try {
    await yandexChunks(lines, target, budget, session, result);
    budget.error = null;
  } catch (error) {
    budget.error = budget.error || error;
  }
  return result;
}

async function yandexChunks(lines, target, budget, session, result) {
  for (const chunk of chunks(lines, 4000, 60)) {
    if (budget.left <= 0) break;
    budget.left -= 1;
    const params = new URLSearchParams({ id: `${session}-0-0`, srv: "android" });
    const form = new URLSearchParams({ lang: target === "zh-Hans" ? "zh" : target });
    for (const text of chunk) form.append("text", text);
    const response = await fetch(`https://translate.yandex.net/api/v1/tr.json/translate?${params}`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded;charset=utf-8" },
      body: form,
    });
    if (!response.ok) throw new Error(`yandex ${response.status}`);
    const object = await response.json();
    if (!Array.isArray(object?.text) || object.text.length !== chunk.length) throw new Error("yandex unreadable");
    chunk.forEach((text, i) => { result[text] = String(object.text[i]); });
  }
}

// MARK: Helpers

/// Batches of at most `count` lines and about `characters` characters.
function chunks(lines, characters, count) {
  const result = [];
  let current = [];
  let length = 0;
  for (const line of lines) {
    if (current.length && (current.length >= count || length + line.length > characters)) {
      result.push(current);
      current = [];
      length = 0;
    }
    current.push(line);
    length += line.length + 1;
  }
  if (current.length) result.push(current);
  return result;
}

async function cacheKey(target, text) {
  return target + ":" + await sha256Hex(target + "\n" + text, 16);
}

async function sha256Hex(value, bytes = 12) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].slice(0, bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

const json = (value, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
