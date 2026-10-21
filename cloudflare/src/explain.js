// "What does this line mean": Mercury (Inception's diffusion model, very fast) reads the whole
// song, the line asked about and short artist bios from Wikipedia, and explains the line in the
// app's language: slang, references, wordplay, what it says in the song. With `index: null` it
// says what the whole song is about. Answers and bios are cached in D1 for every install, so a
// line anyone has asked about comes back at once and costs nothing upstream.

const MODEL = "mercury-3";
// Part of the cache key: a new prompt or model gives new answers instead of the old ones.
const PROMPT_VERSION = 1;
const LANGUAGES = {
  ru: "Russian", en: "English", uk: "Ukrainian", de: "German", fr: "French", es: "Spanish", it: "Italian",
  pt: "Portuguese", pl: "Polish", tr: "Turkish", ja: "Japanese", ko: "Korean", "zh-Hans": "Simplified Chinese",
};
const MAX_BODY = 100_000;
const MAX_LINES = 400;
const MAX_LINE = 500;
const MAX_LYRICS = 40_000;
const MAX_FIELD = 300;
const MAX_ARTISTS = 3;
// Uncached answers one network may ask for per hour.
const MISSES_PER_HOUR = 40;
const KEEP_DAYS = 180;
const TOUCH_AFTER = 7 * 86400;
const BIO_DAYS = 30;
// A bio Wikipedia didn't have is asked for again after this long.
const BIO_MISS_DAYS = 7;
const USER_AGENT = "SweetLyrics/1.0 (https://github.com/Sppqq/sweet-lyrics-ios)";
// Words that tell a musician's page from a namesake's, in the wikis the app's languages use.
const MUSIC = /sing|rapper|musician|band|group|duo|trio|songwriter|producer|\bdj\b|composer|music|vocal|hip.hop|rock|pop|певи|певец|рэп|репер|музык|групп|исполнит|песен|продюсер|композитор|дуэт|коллектив|диджей|хип-хоп|рок-|поп-|sänger|chanteu|cantant|cantor|piosenkar|zespół|şarkıcı|歌手|バンド|가수|그룹|歌手|乐队/i;

export async function explain(request, env) {
  if (!env.INCEPTION_API_KEY) return json({ error: "not configured" }, 503);
  if (Number(request.headers.get("content-length") || 0) > MAX_BODY) return json({ error: "too big" }, 413);
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "body" }, 400);
  }
  const language = String(body?.language || "");
  if (!(language in LANGUAGES)) return json({ error: "language" }, 400);
  const title = field(body?.track?.title);
  const album = field(body?.track?.album);
  const artists = (Array.isArray(body?.track?.artists) ? body.track.artists : []).map(field).filter(Boolean).slice(0, MAX_ARTISTS);
  if (!title || !artists.length) return json({ error: "track" }, 400);
  if (!Array.isArray(body?.lines)) return json({ error: "lines" }, 400);
  const lines = body.lines.map((line) => String(line ?? "").trim());
  if (!lines.length || lines.length > MAX_LINES || lines.some((line) => line.length > MAX_LINE)
      || lines.reduce((sum, line) => sum + line.length, 0) > MAX_LYRICS) {
    return json({ error: "lines" }, 400);
  }
  const index = body.index === null || body.index === undefined ? null : Number(body.index);
  if (index !== null && (!Number.isInteger(index) || index < 0 || index >= lines.length || !lines[index])) {
    return json({ error: "index" }, 400);
  }

  const now = Math.floor(Date.now() / 1000);
  const key = "x" + PROMPT_VERSION + ":" + await sha256Hex(JSON.stringify([MODEL, language, title, artists, album, index, lines]), 16);
  const cached = await env.DB.prepare("SELECT body, used_at FROM explanations WHERE key = ?").bind(key).first();
  if (cached) {
    if (cached.used_at < now - TOUCH_AFTER) {
      await env.DB.prepare("UPDATE explanations SET used_at = ? WHERE key = ?").bind(now, key).run();
    }
    return json({ ...JSON.parse(cached.body), cached: true });
  }

  const ipHash = await sha256Hex((request.headers.get("cf-connecting-ip") || "?") + (env.IP_SALT || env.ADMIN_TOKEN || "sl"));
  const used = await env.DB.prepare(
    `INSERT INTO explain_quota (ip_hash, hour, count) VALUES (?, ?, 1)
     ON CONFLICT (ip_hash, hour) DO UPDATE SET count = count + 1 RETURNING count`,
  ).bind(ipHash, Math.floor(now / 3600)).first();
  if ((used?.count || 0) > MISSES_PER_HOUR) return json({ error: "slow down" }, 429);

  const bios = await Promise.all(artists.map((name) => artistBio(name, language, env, now)));
  let answer;
  try {
    answer = await ask(env, { language, title, album, artists, bios, lines, index });
  } catch (error) {
    console.error("explain", String(error));
    return json({ error: "upstream" }, 502);
  }
  const result = {
    ...answer,
    artists: artists.map((name, i) => ({ name, ...(bios[i] || {}) })).filter((artist) => artist.summary),
  };
  await env.DB.prepare("INSERT OR REPLACE INTO explanations (key, body, created_at, used_at) VALUES (?, ?, ?, ?)")
    .bind(key, JSON.stringify(result), now, now).run();
  return json({ ...result, cached: false });
}

/// Nightly: answers nobody asked for in KEEP_DAYS, old bios and hourly counters.
export async function pruneExplanations(env) {
  const now = Math.floor(Date.now() / 1000);
  await env.DB.prepare("DELETE FROM explanations WHERE used_at < ?").bind(now - KEEP_DAYS * 86400).run();
  await env.DB.prepare("DELETE FROM artist_bios WHERE fetched_at < ?").bind(now - BIO_DAYS * 86400).run();
  await env.DB.prepare("DELETE FROM explain_quota WHERE hour < ?").bind(Math.floor(now / 3600) - 48).run();
}

// MARK: The model

async function ask(env, { language, title, album, artists, bios, lines, index }) {
  const output = LANGUAGES[language];
  const song = index === null;
  const numbered = lines.map((line, i) => `${i === index ? ">>> " : ""}${i + 1}. ${line}`).join("\n");
  const about = artists.map((name, i) => bios[i]?.summary ? `${name}: ${bios[i].summary}` : `${name}: (no bio found)`).join("\n\n");
  const system = [
    "You annotate song lyrics for listeners, like a sharp, friendly music journalist.",
    `Always answer in ${output}, whatever language the lyrics are in.`,
    song
      ? "Explain what the whole song is about: its story, mood and the idea behind it, and how it fits the artist."
      : "Explain the one line marked with >>>: what it means in this song (use the lines around it and the whole text), plus any slang, idioms, cultural or historical references, wordplay or double meanings in it.",
    "Use the artist bios for context (their background, scene, style), but only where it really helps.",
    "Be concrete and short. No filler, no praise of the song, no retelling the line word for word.",
    "Never quote more than a few words of the lyrics. Don't invent facts: if a reference is a guess, say it may be one.",
    "Reply with JSON only.",
  ].join(" ");
  const user = [
    `Song: "${title}"${album ? ` from "${album}"` : ""} by ${artists.join(", ")}.`,
    "",
    "Artists:",
    about,
    "",
    "Lyrics:",
    numbered,
    "",
    song ? "Explain the song." : `Explain line ${index + 1}.`,
  ].join("\n");

  const schema = {
    type: "object",
    additionalProperties: false,
    required: ["summary", "meaning", "notes"],
    properties: {
      summary: { type: "string", description: song ? "What the song is about, in one short sentence (max ~12 words)." : "The line's point, in one short sentence (max ~12 words)." },
      meaning: { type: "string", description: song ? "3-5 sentences on the song." : "2-4 sentences on what the line means in the song." },
      notes: {
        type: "array",
        description: song ? "Up to 3 key themes or moments, each tied to a short phrase." : "Up to 3 words or phrases from the line worth a note (slang, references, wordplay). Empty if none.",
        items: {
          type: "object",
          additionalProperties: false,
          required: ["phrase", "note"],
          properties: { phrase: { type: "string" }, note: { type: "string" } },
        },
      },
    },
  };

  const response = await fetch("https://api.inceptionlabs.ai/v1/chat/completions", {
    method: "POST",
    headers: { authorization: `Bearer ${env.INCEPTION_API_KEY}`, "content-type": "application/json" },
    body: JSON.stringify({
      model: MODEL,
      reasoning_effort: "low",
      max_tokens: 2500,
      temperature: 0.4,
      messages: [{ role: "system", content: system }, { role: "user", content: user }],
      response_format: { type: "json_schema", json_schema: { name: "explanation", strict: true, schema } },
    }),
  });
  if (!response.ok) throw new Error(`mercury ${response.status} ${(await response.text()).slice(0, 200)}`);
  const content = (await response.json())?.choices?.[0]?.message?.content;
  if (typeof content !== "string") throw new Error("mercury empty");
  const parsed = JSON.parse(content.replace(/^```(?:json)?\s*|\s*```$/g, ""));
  const text = (value, max) => String(value ?? "").trim().slice(0, max);
  const answer = {
    summary: text(parsed.summary, 300),
    meaning: text(parsed.meaning, 2000),
    notes: (Array.isArray(parsed.notes) ? parsed.notes : [])
      .map((note) => ({ phrase: text(note?.phrase, 120), note: text(note?.note, 600) }))
      .filter((note) => note.phrase && note.note)
      .slice(0, 3),
  };
  if (!answer.meaning) throw new Error("mercury unreadable");
  return answer;
}

// MARK: Artist bios

/// The intro of the artist's Wikipedia page, in the app's language when that wiki has one, else
/// English. Null when neither has a page that looks like a musician's.
async function artistBio(name, language, env, now) {
  const wiki = language === "zh-Hans" ? "zh" : language;
  const key = wiki + ":" + name.toLowerCase();
  const row = await env.DB.prepare("SELECT summary, description, url, fetched_at FROM artist_bios WHERE key = ?").bind(key).first();
  if (row && row.fetched_at > now - (row.summary ? BIO_DAYS : BIO_MISS_DAYS) * 86400) {
    return row.summary ? { summary: row.summary, description: row.description, url: row.url } : null;
  }
  let found = null;
  try {
    // The name as written (a Russian artist in the Russian wiki), else the English page and,
    // through its language link, the same page in the app's language ("Kendrick Lamar" is
    // "Кендрик Ламар" there, which a search for the Latin name doesn't match).
    if (wiki !== "en") found = await searchWikipedia(wiki, name);
    if (!found) {
      const english = await searchWikipedia("en", name, wiki);
      if (english?.link) found = await wikipediaPage(wiki, english.link);
      found = found || english;
    }
  } catch (error) {
    console.error("wikipedia", wiki, String(error));
    // Not Wikipedia's "no such page": don't remember a miss.
    return null;
  }
  if (found) delete found.link;
  await env.DB.prepare("INSERT OR REPLACE INTO artist_bios (key, summary, description, url, fetched_at) VALUES (?, ?, ?, ?, ?)")
    .bind(key, found?.summary || "", found?.description || "", found?.url || "", now).run();
  return found;
}

const PAGE_PROPS = { prop: "extracts|description|pageprops", exintro: "1", explaintext: "1", exchars: "1200", exlimit: "5" };

/// One request: the top search hits with their intros, the first that is about a musician
/// (with the title of the same page in `linkLanguage`'s wiki, when asked for).
async function searchWikipedia(wiki, name, linkLanguage) {
  const extra = linkLanguage && linkLanguage !== wiki ? { prop: PAGE_PROPS.prop + "|langlinks", lllang: linkLanguage, lllimit: "max" } : {};
  const pages = await wikipediaQuery(wiki, { generator: "search", gsrsearch: name, gsrlimit: "5", ...PAGE_PROPS, ...extra });
  const wanted = simplify(name);
  const page = pages
    .filter((page) => !page.pageprops || !("disambiguation" in page.pageprops))
    .sort((a, b) => (a.index ?? 0) - (b.index ?? 0))
    .find((page) => {
      const title = simplify(page.title.replace(/\s*\(.*\)\s*$/, ""));
      const named = title === wanted || title.includes(wanted) || wanted.includes(title);
      return named && isMusician(page);
    });
  return page ? bio(wiki, page) : null;
}

/// A page by its exact title, if it is about a musician.
async function wikipediaPage(wiki, title) {
  const page = (await wikipediaQuery(wiki, { titles: title, ...PAGE_PROPS }))[0];
  return page && !page.missing && isMusician(page) ? bio(wiki, page) : null;
}

async function wikipediaQuery(wiki, query) {
  const params = new URLSearchParams({ action: "query", format: "json", formatversion: "2", redirects: "1", ...query });
  const response = await fetch(`https://${wiki}.wikipedia.org/w/api.php?${params}`, { headers: { "user-agent": USER_AGENT } });
  if (!response.ok) throw new Error(`wikipedia ${response.status}`);
  return (await response.json())?.query?.pages || [];
}

const isMusician = (page) => Boolean(page.extract) && MUSIC.test(`${page.description || ""} ${page.extract.slice(0, 300)}`);

const bio = (wiki, page) => ({
  summary: page.extract.replace(/\s+/g, " ").trim(),
  description: String(page.description || "").slice(0, 200),
  url: `https://${wiki}.wikipedia.org/wiki/${encodeURIComponent(page.title.replaceAll(" ", "_"))}`,
  link: page.langlinks?.[0]?.title,
});

// MARK: Helpers

const simplify = (value) => value.toLowerCase().normalize("NFKD").replace(/\p{M}/gu, "").replace(/[^\p{L}\p{N}]+/gu, "");

const field = (value) => String(value ?? "").trim().slice(0, MAX_FIELD);

async function sha256Hex(value, bytes = 12) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].slice(0, bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

const json = (value, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
