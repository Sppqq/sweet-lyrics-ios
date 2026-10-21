// "What does this line mean": Mercury (Inception's diffusion model, very fast) reads the whole
// song, the line asked about, what Genius knows about the song (its description and the line's
// annotations), the artists' bios and whatever it chose to look up, and explains the line in the
// app's language: slang, references, wordplay, what it says in the song. With `index: null` it
// says what the whole song is about. Answers and bios are cached in D1 for every install, so a
// line anyone has asked about comes back at once and costs nothing upstream.
//
// POST /v1/explain/report: a listener says an answer is wrong; it is kept for /admin/ai, and a
// wrong or wrong-language answer leaves the cache so the next listener gets a new one.

const MODEL = "mercury-3";
// Part of the cache key: a new prompt or model gives new answers instead of the old ones.
const PROMPT_VERSION = 2;
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
const REPORTS_PER_HOUR = 20;
const REPORT_REASONS = ["wrong", "language", "offensive", "other"];
const KEEP_DAYS = 180;
const TOUCH_AFTER = 7 * 86400;
const BIO_DAYS = 30;
// A bio or a Genius page that wasn't there is asked for again after this long.
const MISS_DAYS = 7;
// Searches the model may ask for before it answers.
const MAX_QUERIES = 3;
const USER_AGENT = "SweetLyrics/1.0 (https://github.com/Sppqq/sweet-lyrics-ios)";
// Words that tell a musician's page from a namesake's, in the wikis the app's languages use.
const MUSIC = /sing|rapper|musician|band|group|duo|trio|songwriter|producer|\bdj\b|composer|music|vocal|hip.hop|rock|pop|певи|певец|рэп|репер|музык|групп|исполнит|песен|продюсер|композитор|дуэт|коллектив|диджей|хип-хоп|рок-|поп-|sänger|chanteu|cantant|cantor|piosenkar|zespół|şarkıcı|歌手|バンド|가수|그룹|乐队/i;

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
    return json({ ...JSON.parse(cached.body), id: key, cached: true });
  }

  const ipHash = await ipHashOf(request, env);
  const used = await env.DB.prepare(
    `INSERT INTO explain_quota (ip_hash, hour, count) VALUES (?, ?, 1)
     ON CONFLICT (ip_hash, hour) DO UPDATE SET count = count + 1 RETURNING count`,
  ).bind(ipHash, Math.floor(now / 3600)).first();
  if ((used?.count || 0) > MISSES_PER_HOUR) return json({ error: "slow down" }, 429);

  const song = { language, title, album, artists, lines, index };
  // Wikipedia and Genius at the same time; neither failing stops the answer.
  const [bios, genius] = await Promise.all([
    Promise.all(artists.map((name) => artistBio(name, language, env, now))),
    geniusSong(title, artists, env, now).catch((error) => (console.error("genius", String(error)), null)),
  ]);
  let answer;
  try {
    const context = { bios, genius };
    context.found = await research(env, song, context).catch((error) => (console.error("research", String(error)), []));
    answer = await ask(env, song, context);
  } catch (error) {
    console.error("explain", String(error));
    return json({ error: "upstream" }, 502);
  }
  const result = {
    ...answer,
    artists: artists.map((name, i) => {
      // Wikipedia first; an artist only Genius knows still gets a card.
      const bio = bios[i] || (genius?.artist && sameName(genius.artist.name, name) && genius.artist.summary
        ? { summary: genius.artist.summary, description: "Genius", url: genius.artist.url } : null);
      return { name, ...(bio || {}) };
    }).filter((artist) => artist.summary),
  };
  await env.DB.prepare("INSERT OR REPLACE INTO explanations (key, body, created_at, used_at) VALUES (?, ?, ?, ?)")
    .bind(key, JSON.stringify(result), now, now).run();
  return json({ ...result, id: key, cached: false });
}

/// A listener's complaint about an answer: `{"id", "reason", "comment"}`.
export async function reportExplanation(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "body" }, 400);
  }
  const key = String(body?.id || "");
  const reason = String(body?.reason || "");
  const comment = String(body?.comment || "").trim().slice(0, 1000);
  if (!/^x\d+:[0-9a-f]{32}$/.test(key) || !REPORT_REASONS.includes(reason)) return json({ error: "report" }, 400);
  const now = Math.floor(Date.now() / 1000);
  const ipHash = await ipHashOf(request, env);
  const recent = await env.DB.prepare("SELECT COUNT(*) AS n FROM explain_reports WHERE ip_hash = ? AND created_at > ?")
    .bind(ipHash, now - 3600).first();
  if ((recent?.n || 0) >= REPORTS_PER_HOUR) return json({ error: "slow down" }, 429);
  const answer = await env.DB.prepare("SELECT body FROM explanations WHERE key = ?").bind(key).first();
  await env.DB.prepare(
    "INSERT INTO explain_reports (key, reason, comment, answer, install_id, ip_hash, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
  ).bind(key, reason, comment, answer?.body || "", String(request.headers.get("x-install-id") || "").slice(0, 64), ipHash, now).run();
  // Untrue or in the wrong language: the next listener gets a fresh answer.
  if (reason === "wrong" || reason === "language") {
    await env.DB.prepare("DELETE FROM explanations WHERE key = ?").bind(key).run();
  }
  return json({ ok: true });
}

/// /admin/ai: the latest complaints with the answers they were about.
export async function explainReportsPage(env, esc) {
  const rows = (await env.DB.prepare("SELECT * FROM explain_reports ORDER BY id DESC LIMIT 200").all()).results;
  const items = rows.map((row) => {
    let answer = {};
    try { answer = JSON.parse(row.answer || "{}"); } catch {}
    return `<tr><td>${esc(new Date(row.created_at * 1000).toISOString().replace("T", " ").slice(0, 16))}</td>` +
      `<td><b>${esc(row.reason)}</b>${row.comment ? "<br>" + esc(row.comment) : ""}</td>` +
      `<td>${esc(answer.summary || "(answer no longer stored)")}<br><small>${esc((answer.meaning || "").slice(0, 400))}</small></td></tr>`;
  }).join("");
  return `<p><a href="/admin">← reports</a></p><table><tr><th>When</th><th>Complaint</th><th>Answer</th></tr>${items}</table>`;
}

/// Nightly: answers nobody asked for in KEEP_DAYS, old bios, Genius pages, complaints and counters.
export async function pruneExplanations(env) {
  const now = Math.floor(Date.now() / 1000);
  await env.DB.prepare("DELETE FROM explanations WHERE used_at < ?").bind(now - KEEP_DAYS * 86400).run();
  await env.DB.prepare("DELETE FROM artist_bios WHERE fetched_at < ?").bind(now - BIO_DAYS * 86400).run();
  await env.DB.prepare("DELETE FROM genius_songs WHERE fetched_at < ?").bind(now - BIO_DAYS * 86400).run();
  await env.DB.prepare("DELETE FROM explain_reports WHERE created_at < ?").bind(now - KEEP_DAYS * 86400).run();
  await env.DB.prepare("DELETE FROM explain_quota WHERE hour < ?").bind(Math.floor(now / 3600) - 48).run();
}

// MARK: The model

/// Before answering, the model says what it doesn't know (a name, a brand, a slang word), and
/// gets up to three searches through Genius and Wikipedia.
async function research(env, song, context) {
  const content = await mercury(env, {
    reasoning_effort: "instant",
    max_tokens: 400,
    messages: [
      { role: "system", content: "You prepare to explain song lyrics. List what you'd need to look up to understand them: unfamiliar names, nicknames, brands, places, slang or references in the song or its title that the notes below don't already explain. Reply with JSON only." },
      { role: "user", content: prompt(song, context) + `\n\nWhat do you need to look up (at most ${MAX_QUERIES} short search queries; none if everything is clear)?` },
    ],
    schema: {
      type: "object", additionalProperties: false, required: ["queries"],
      properties: { queries: { type: "array", items: { type: "string" } } },
    },
  });
  const queries = (JSON.parse(content).queries || []).map((query) => String(query).trim().slice(0, 120)).filter(Boolean).slice(0, MAX_QUERIES);
  const wiki = song.language === "zh-Hans" ? "zh" : song.language;
  const results = await Promise.all(queries.map(async (query) => {
    const [own, english, genius] = await Promise.all([
      searchWikipedia(wiki, query).catch(() => []),
      wiki === "en" ? [] : searchWikipedia("en", query).catch(() => []),
      searchGenius(query).catch(() => []),
    ]);
    const found = [...own, ...english, ...genius].slice(0, 4);
    return found.length ? `Search "${query}":\n${found.map((item) => "- " + item).join("\n")}` : "";
  }));
  return results.filter(Boolean);
}

async function ask(env, song, context) {
  const output = LANGUAGES[song.language];
  const whole = song.index === null;
  const system = [
    "You annotate song lyrics for listeners, like a sharp, friendly music journalist.",
    `Write every field in ${output}, whatever language the lyrics, the notes or the search results are in. Quote lyrics only in "phrase".`,
    whole
      ? "Explain what the whole song is about: its story, mood and the idea behind it, and how it fits the artist."
      : "Explain the one line marked with >>>: what it means in this song (use the lines around it and the whole text), plus any slang, idioms, names, brands, cultural or historical references, wordplay or double meanings in it.",
    "Use the notes from Genius, the artist bios and the search results where they help; they are often the only way to know what a name or a title refers to.",
    "Be concrete and short. No filler, no praise of the song, no retelling the line word for word.",
    "Never quote more than a few words of the lyrics. Don't invent facts: if a reference is a guess, say it may be one.",
    "Reply with JSON only.",
  ].join(" ");
  const user = prompt(song, context) + "\n\n" +
    (whole ? "Explain the song." : `Explain line ${song.index + 1}.`) + ` Answer in ${output}.`;
  const schema = {
    type: "object",
    additionalProperties: false,
    required: ["summary", "meaning", "notes"],
    properties: {
      summary: { type: "string", description: whole ? "What the song is about, in one short sentence (max ~12 words)." : "The line's point, in one short sentence (max ~12 words)." },
      meaning: { type: "string", description: whole ? "3-5 sentences on the song." : "2-4 sentences on what the line means in the song." },
      notes: {
        type: "array",
        description: whole ? "Up to 3 key themes or moments, each tied to a short phrase." : "Up to 3 words or phrases from the line worth a note (slang, names, references, wordplay). Empty if none.",
        items: {
          type: "object",
          additionalProperties: false,
          required: ["phrase", "note"],
          properties: { phrase: { type: "string" }, note: { type: "string" } },
        },
      },
    },
  };
  const messages = [{ role: "system", content: system }, { role: "user", content: user }];
  let answer = readAnswer(await mercury(env, { messages, schema }));
  // The model sometimes follows the lyrics' language: once more, told plainly.
  if (!inLanguage(answer.summary + " " + answer.meaning, song.language)) {
    messages.push({ role: "assistant", content: JSON.stringify(answer) });
    messages.push({ role: "user", content: `That is not in ${output}. Write the same answer again, every field in ${output} (keep the quoted lyrics in "phrase" as they are).` });
    const retry = readAnswer(await mercury(env, { messages, schema }));
    if (inLanguage(retry.summary + " " + retry.meaning, song.language)) answer = retry;
  }
  return answer;
}

/// Everything the model gets about the song.
function prompt(song, { bios, genius, found }) {
  const { title, album, artists, lines, index } = song;
  const numbered = lines.map((line, i) => `${i === index ? ">>> " : ""}${i + 1}. ${line}`).join("\n");
  const about = artists.map((name, i) => {
    const bio = bios[i]?.summary || (genius?.artist && sameName(genius.artist.name, name) ? genius.artist.summary : "");
    return `${name}: ${bio || "(no bio found)"}`;
  }).join("\n\n");
  const parts = [`Song: "${title}"${album ? ` from "${album}"` : ""} by ${artists.join(", ")}.`, "", "Artists:", about];
  if (genius?.description) parts.push("", "About the song (Genius):", genius.description);
  const notes = (genius?.annotations || []).filter((note) => index === null || overlaps(note.fragment, lines[index]));
  if (notes.length) {
    parts.push("", "Genius annotations:", ...notes.slice(0, 6).map((note) => `- "${note.fragment}": ${note.body}`));
  }
  if (found?.length) parts.push("", "Search results:", ...found);
  parts.push("", "Lyrics:", numbered);
  return parts.join("\n");
}

async function mercury(env, { messages, schema, reasoning_effort = "low", max_tokens = 2500 }) {
  const response = await fetch("https://api.inceptionlabs.ai/v1/chat/completions", {
    method: "POST",
    headers: { authorization: `Bearer ${env.INCEPTION_API_KEY}`, "content-type": "application/json" },
    body: JSON.stringify({
      model: MODEL,
      reasoning_effort,
      max_tokens,
      temperature: 0.4,
      messages,
      response_format: { type: "json_schema", json_schema: { name: "answer", strict: true, schema } },
    }),
  });
  if (!response.ok) throw new Error(`mercury ${response.status} ${(await response.text()).slice(0, 200)}`);
  const content = (await response.json())?.choices?.[0]?.message?.content;
  if (typeof content !== "string") throw new Error("mercury empty");
  return content.replace(/^```(?:json)?\s*|\s*```$/g, "");
}

function readAnswer(content) {
  const parsed = JSON.parse(content);
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

/// Most of the letters are in the language's script (Latin for the European ones).
function inLanguage(text, language) {
  const letters = text.match(/\p{L}/gu) || [];
  if (letters.length < 10) return true;
  const scripts = {
    ru: /\p{Script=Cyrillic}/u, uk: /\p{Script=Cyrillic}/u, ja: /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}]/u,
    ko: /\p{Script=Hangul}/u, "zh-Hans": /\p{Script=Han}/u,
  };
  const script = scripts[language] || /\p{Script=Latin}/u;
  return letters.filter((letter) => script.test(letter)).length / letters.length > 0.6;
}

// MARK: Genius

/// The song's Genius page: its description, its annotations and its main artist's bio. Cached
/// for a month; a song Genius doesn't have is asked for again after a week.
async function geniusSong(title, artists, env, now) {
  const key = (artists[0] + " – " + title).toLowerCase().slice(0, 300);
  const row = await env.DB.prepare("SELECT body, fetched_at FROM genius_songs WHERE key = ?").bind(key).first();
  if (row && row.fetched_at > now - (row.body ? BIO_DAYS : MISS_DAYS) * 86400) return row.body ? JSON.parse(row.body) : null;

  const hits = await geniusSearch(`${artists[0]} ${title}`);
  const wantedTitle = simplify(title.replace(/\s*[([].*$/, ""));
  const song = hits
    .filter((hit) => hit.type === "song")
    .map((hit) => hit.result)
    .find((result) => {
      const songTitle = simplify(String(result.title || "").replace(/\s*[([].*$/, ""));
      const titled = songTitle && (songTitle === wantedTitle || songTitle.includes(wantedTitle) || wantedTitle.includes(songTitle));
      const byArtist = artists.some((name) => sameName(result.primary_artist?.name || "", name)
        || String(result.artist_names || "").toLowerCase().includes(name.toLowerCase()));
      return titled && byArtist;
    });
  let found = null;
  if (song?.id) {
    const [details, referents] = await Promise.all([
      geniusGet(`/songs/${song.id}?text_format=plain`),
      geniusGet(`/referents?song_id=${song.id}&text_format=plain&per_page=50`).catch(() => null),
    ]);
    const info = details?.song || {};
    const artist = info.primary_artist?.id ? (await geniusGet(`/artists/${info.primary_artist.id}?text_format=plain`).catch(() => null))?.artist : null;
    found = {
      description: cleanGenius(info.description?.plain).slice(0, 1500),
      annotations: (referents?.referents || [])
        .map((ref) => ({ fragment: String(ref.fragment || "").slice(0, 200), body: cleanGenius(ref.annotations?.[0]?.body?.plain).slice(0, 600) }))
        .filter((note) => note.fragment && note.body)
        .slice(0, 30),
      artist: artist ? { name: String(artist.name || ""), summary: cleanGenius(artist.description?.plain).slice(0, 1200), url: String(artist.url || "") } : null,
    };
    if (!found.description && !found.annotations.length && !found.artist?.summary) found = null;
  }
  await env.DB.prepare("INSERT OR REPLACE INTO genius_songs (key, body, fetched_at) VALUES (?, ?, ?)")
    .bind(key, found ? JSON.stringify(found) : "", now).run();
  return found;
}

/// Genius search hits for a query the model asked for, as one line each.
async function searchGenius(query) {
  const hits = await geniusSearch(query);
  return hits
    .filter((hit) => hit.type === "song" || hit.type === "artist")
    .slice(0, 3)
    .map((hit) => hit.type === "song"
      ? `Genius song: ${hit.result.full_title || hit.result.title}${hit.result.release_date_for_display ? ` (${hit.result.release_date_for_display})` : ""}`
      : `Genius artist: ${hit.result.name}`);
}

async function geniusSearch(query) {
  const response = await geniusGet(`/search/multi?q=${encodeURIComponent(query)}`);
  const sections = response?.sections || [];
  return sections.filter((section) => section.type === "top_hit" || section.type === "song" || section.type === "artist")
    .flatMap((section) => section.hits.map((hit) => ({ type: hit.type, result: hit.result })));
}

async function geniusGet(path) {
  const response = await fetch(`https://genius.com/api${path}`, { headers: { "user-agent": USER_AGENT, accept: "application/json" } });
  if (!response.ok) throw new Error(`genius ${response.status}`);
  return (await response.json())?.response;
}

/// Genius' plain text keeps link lists and blank lines; one paragraph of what matters.
function cleanGenius(text) {
  return String(text || "").split(/\n+/).map((line) => line.trim()).filter((line) => line && line !== "?" && line.length > 25)
    .join(" ").replace(/\s+/g, " ").trim();
}

/// An annotation is about the asked line when they share a run of words.
function overlaps(fragment, line) {
  const a = simplifyWords(fragment), b = simplifyWords(line || "");
  if (!a.length || !b.length) return false;
  const joinedA = a.join(" "), joinedB = b.join(" ");
  return joinedA.includes(joinedB) || joinedB.includes(joinedA)
    || b.filter((word) => word.length > 3 && a.includes(word)).length >= Math.min(3, Math.ceil(b.length / 2));
}

// MARK: Wikipedia

/// The intro of the artist's Wikipedia page, in the app's language when that wiki has one, else
/// English. Null when neither has a page that looks like a musician's.
async function artistBio(name, language, env, now) {
  const wiki = language === "zh-Hans" ? "zh" : language;
  const key = wiki + ":" + name.toLowerCase();
  const row = await env.DB.prepare("SELECT summary, description, url, fetched_at FROM artist_bios WHERE key = ?").bind(key).first();
  if (row && row.fetched_at > now - (row.summary ? BIO_DAYS : MISS_DAYS) * 86400) {
    return row.summary ? { summary: row.summary, description: row.description, url: row.url } : null;
  }
  let found = null;
  try {
    // The name as written (a Russian artist in the Russian wiki), else the English page and,
    // through its language link, the same page in the app's language ("Kendrick Lamar" is
    // "Кендрик Ламар" there, which a search for the Latin name doesn't match).
    if (wiki !== "en") found = await musicianPage(wiki, name);
    if (!found) {
      const english = await musicianPage("en", name, wiki);
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
async function musicianPage(wiki, name, linkLanguage) {
  const extra = linkLanguage && linkLanguage !== wiki ? { prop: PAGE_PROPS.prop + "|langlinks", lllang: linkLanguage, lllimit: "max" } : {};
  const pages = await wikipediaQuery(wiki, { generator: "search", gsrsearch: name, gsrlimit: "5", ...PAGE_PROPS, ...extra });
  const page = pages
    .filter((page) => !page.pageprops || !("disambiguation" in page.pageprops))
    .sort((a, b) => (a.index ?? 0) - (b.index ?? 0))
    .find((page) => sameName(page.title.replace(/\s*\(.*\)\s*$/, ""), name) && isMusician(page));
  return page ? bio(wiki, page) : null;
}

/// A page by its exact title, if it is about a musician.
async function wikipediaPage(wiki, title) {
  const page = (await wikipediaQuery(wiki, { titles: title, ...PAGE_PROPS }))[0];
  return page && !page.missing && isMusician(page) ? bio(wiki, page) : null;
}

/// The first sentences of the top pages for a query the model asked for, one line each.
async function searchWikipedia(wiki, query) {
  const pages = await wikipediaQuery(wiki, {
    generator: "search", gsrsearch: query, gsrlimit: "2",
    prop: "extracts|pageprops", exintro: "1", explaintext: "1", exchars: "400", exlimit: "2",
  });
  return pages
    .filter((page) => page.extract && (!page.pageprops || !("disambiguation" in page.pageprops)))
    .sort((a, b) => (a.index ?? 0) - (b.index ?? 0))
    .map((page) => `Wikipedia (${wiki}) "${page.title}": ${page.extract.replace(/\s+/g, " ").trim()}`);
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

const simplifyWords = (value) => value.toLowerCase().normalize("NFKD").replace(/\p{M}/gu, "").split(/[^\p{L}\p{N}]+/u).filter(Boolean);

/// The same name, give or take spaces, case, accents and punctuation.
function sameName(a, b) {
  const x = simplify(a), y = simplify(b);
  return Boolean(x && y) && (x === y || x.includes(y) || y.includes(x));
}

const field = (value) => String(value ?? "").trim().slice(0, MAX_FIELD);

async function ipHashOf(request, env) {
  return sha256Hex((request.headers.get("cf-connecting-ip") || "?") + (env.IP_SALT || env.ADMIN_TOKEN || "sl"));
}

async function sha256Hex(value, bytes = 12) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].slice(0, bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

const json = (value, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
