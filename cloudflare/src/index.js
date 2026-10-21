// Sweet Lyrics report collector: the app posts a bug report (log, a note, a few photos), this
// stores it in D1 (text) and R2 (photos). Every report is a thread: the developer (or the bot that
// works through reports, /v1/bot) answers, the app shows the answers and lets the sender reply.
// Status: open → in_progress → closed; a reply from the sender reopens a closed report.
// /admin is a small page for reading, answering and closing them.
// /v1/translate translates lyric lines for the app, with a cache every install shares (translate.js).
// /v1/explain explains a lyric line or a whole song with Mercury (explain.js).
// /v1/config serves the app's request cadence, timeouts and cache lifetimes (RemoteConfig.swift).

import { explain, explainReportsPage, pruneExplanations, reportExplanation } from "./explain.js";
import { pruneTranslations, translate } from "./translate.js";

const MAX_BODY = 8 * 1024 * 1024;
const MAX_LOG = 300_000;
const MAX_MESSAGE = 4_000;
const MAX_FIELD = 200;
const MAX_PHOTOS = 3;
const MAX_PHOTO = 2 * 1024 * 1024;
const RETENTION_DAYS = 90;
// Anonymous endpoint: keep one install or one network from filling the database.
const LIMITS = { installPerHour: 12, ipPerHour: 40, ipPerDay: 200 };
const UUID = /^[0-9a-fA-F-]{36}$/;
const STATUSES = ["open", "in_progress", "closed"];
const MAX_REPLY = 4_000;
// An in-progress report nobody touched for this long goes back to the bot (has the fix been released?).
const RECHECK_DAYS = 2;
// Replies from one install per hour.
const MESSAGES_PER_HOUR = 20;
// What /v1/config serves. These match the app's compiled defaults; to change them for every
// install without a release, set the CLIENT_CONFIG variable (JSON, merged over these), e.g.
// `{"minWebPollInterval": 5, "lookaheadDepth": 0}` while Spotify or the lyrics API struggle.
const CLIENT_CONFIG = {
  lyricsTimeout: 15,
  lookaheadDepth: 2,
  lookaheadDepthSkipping: 6,
  lookaheadDelay: 1.5,
  lyricsCacheDays: 7,
  missCacheHours: 24,
  lrclibCacheHours: 24,
  minWebPollInterval: 0,
  autoReports: true,
  canvas: true,
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/v1/report" && request.method === "POST") return await receive(request, env);
      if (url.pathname === "/v1/translate" && request.method === "POST") return await translate(request, env);
      if (url.pathname === "/v1/explain" && request.method === "POST") return await explain(request, env);
      if (url.pathname === "/v1/explain/report" && request.method === "POST") return await reportExplanation(request, env);
      if (url.pathname === "/v1/config" && request.method === "GET") return clientConfig(env);
      if (url.pathname.startsWith("/v1/threads")) return await threads(request, env, url);
      if (url.pathname.startsWith("/v1/bot/")) return await bot(request, env, url);
      if (url.pathname === "/") return text("Sweet Lyrics reports\n");
      if (url.pathname.startsWith("/admin")) return await admin(request, env, url);
      return text("Not found\n", 404);
    } catch (error) {
      console.error(error);
      return json({ error: "server" }, 500);
    }
  },

  async scheduled(_event, env) {
    const cutoff = Math.floor(Date.now() / 1000) - RETENTION_DAYS * 86400;
    // A thread still being talked in stays: retention counts from its last message.
    const old = await env.DB.prepare(
      "SELECT id, photos, photo_exts FROM reports WHERE MAX(created_at, updated_at) < ?").bind(cutoff).all();
    for (const row of old.results) {
      // A reply may have arrived since the SELECT: the report goes only if it is still old.
      const gone = await env.DB.prepare("DELETE FROM reports WHERE id = ? AND MAX(created_at, updated_at) < ?")
        .bind(row.id, cutoff).run();
      if (!gone.meta?.changes) continue;
      await deletePhotos(env, row);
      await env.DB.prepare("DELETE FROM messages WHERE report_id = ?").bind(row.id).run();
    }
    await pruneTranslations(env);
    await pruneExplanations(env);
  },
};

// The app's remote config: the defaults with CLIENT_CONFIG's keys over them. A broken variable
// is ignored rather than taking the endpoint down; the app checks every key on its own anyway.
function clientConfig(env) {
  let overrides = {};
  try {
    overrides = env.CLIENT_CONFIG ? JSON.parse(env.CLIENT_CONFIG) : {};
  } catch (error) {
    console.error("CLIENT_CONFIG is not JSON", error);
  }
  const body = { ...CLIENT_CONFIG, ...(overrides && typeof overrides === "object" ? overrides : {}) };
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "public, max-age=300" },
  });
}

// MARK: Receiving

async function receive(request, env) {
  const length = Number(request.headers.get("content-length") || 0);
  if (!length) return json({ error: "length" }, 411);
  if (length > MAX_BODY) return json({ error: "too big" }, 413);
  if (!(request.headers.get("content-type") || "").startsWith("multipart/form-data")) return json({ error: "type" }, 415);

  const now = Math.floor(Date.now() / 1000);
  // Its own secret: tied to the admin password, changing that password would reset every limit.
  // ADMIN_TOKEN stays the fallback only for deployments made before IP_SALT existed.
  const ipHash = await sha256Hex((request.headers.get("cf-connecting-ip") || "?") + (env.IP_SALT || env.ADMIN_TOKEN || "sl"));
  const byIp = await env.DB.prepare(
    "SELECT SUM(created_at > ?) AS hour, COUNT(*) AS day FROM reports WHERE ip_hash = ? AND created_at > ?"
  ).bind(now - 3600, ipHash, now - 86400).first();
  if ((byIp?.hour || 0) >= LIMITS.ipPerHour || (byIp?.day || 0) >= LIMITS.ipPerDay) return json({ error: "slow down" }, 429);

  const form = await request.formData();
  let meta;
  try {
    meta = JSON.parse(String(form.get("meta") || "{}"));
  } catch {
    return json({ error: "meta" }, 400);
  }
  if (!meta || typeof meta !== "object" || Array.isArray(meta)) return json({ error: "meta" }, 400);
  const kind = meta.kind === "auto" ? "auto" : meta.kind === "manual" ? "manual" : null;
  const installId = String(meta.installId || "");
  if (!kind || !UUID.test(installId)) return json({ error: "meta" }, 400);

  const perInstall = await env.DB.prepare("SELECT COUNT(*) AS n FROM reports WHERE install_id = ? AND created_at > ?")
    .bind(installId, now - 3600).first();
  if ((perInstall?.n || 0) >= LIMITS.installPerHour) return json({ error: "slow down" }, 429);

  const id = crypto.randomUUID();
  const photos = [];
  for (const file of form.getAll("photo")) {
    if (photos.length >= MAX_PHOTOS) break;
    if (typeof file === "string" || file.size === 0 || file.size > MAX_PHOTO) continue;
    const bytes = new Uint8Array(await file.arrayBuffer());
    const ext = imageExtension(bytes);
    if (!ext) continue;
    await env.PHOTOS.put(`${id}/${photos.length}.${ext}`, bytes, {
      httpMetadata: { contentType: ext === "png" ? "image/png" : "image/jpeg" },
    });
    photos.push(ext);
  }

  const field = (value) => String(value ?? "").slice(0, MAX_FIELD);
  await env.DB.prepare(
    `INSERT INTO reports (id, created_at, updated_at, status, kind, error_kind, message, app_version, build, channel, os,
                          device, locale, install_id, ip_hash, log, photos, photo_exts)
     VALUES (?, ?, ?, 'open', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).bind(
    id, now, now, kind, field(meta.errorKind), String(meta.message ?? "").slice(0, MAX_MESSAGE),
    field(meta.appVersion), field(meta.build), field(meta.channel), field(meta.os), field(meta.device), field(meta.locale),
    installId, ipHash, String(form.get("log") || "").slice(0, MAX_LOG), photos.length, photos.join(","),
  ).run();
  return json({ ok: true, id });
}

function imageExtension(bytes) {
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "jpg";
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return "png";
  return null;
}

async function deletePhotos(env, row) {
  const keys = (row.photo_exts || "").split(",").filter(Boolean).map((ext, i) => `${row.id}/${i}.${ext}`);
  if (keys.length) await env.PHOTOS.delete(keys);
}

// MARK: Threads (the app)

// The sender's side, keyed by their install id (random, only their app knows it).
async function threads(request, env, url) {
  const installId = request.headers.get("x-install-id") || "";
  if (!UUID.test(installId)) return json({ error: "install" }, 400);
  const parts = url.pathname.split("/").filter(Boolean); // v1, threads, id?, messages?

  if (parts.length === 2 && request.method === "GET") {
    const reports = (await env.DB.prepare(
      `SELECT id, created_at, updated_at, status, message FROM reports
       WHERE install_id = ? AND kind = 'manual' ORDER BY created_at DESC LIMIT 30`).bind(installId).all()).results;
    const ids = reports.map((r) => r.id);
    const messages = ids.length ? (await env.DB.prepare(
      `SELECT id, report_id, created_at, author, text FROM messages WHERE report_id IN (${ids.map(() => "?").join(",")}) ORDER BY id`
    ).bind(...ids).all()).results : [];
    return json({
      threads: reports.map((r) => ({
        id: r.id, createdAt: r.created_at, updatedAt: r.updated_at || r.created_at, status: r.status, note: r.message || "",
        messages: messages.filter((m) => m.report_id === r.id)
          .map((m) => ({ id: m.id, createdAt: m.created_at, author: m.author, text: m.text })),
      })),
    });
  }

  if (parts.length === 4 && parts[3] === "messages" && request.method === "POST") {
    const row = await env.DB.prepare("SELECT id FROM reports WHERE id = ? AND install_id = ?").bind(parts[2], installId).first();
    if (!row) return json({ error: "not found" }, 404);
    const now = Math.floor(Date.now() / 1000);
    const recent = await env.DB.prepare(
      `SELECT COUNT(*) AS n FROM messages m JOIN reports r ON r.id = m.report_id
       WHERE r.install_id = ? AND m.author = 'user' AND m.created_at > ?`).bind(installId, now - 3600).first();
    if ((recent?.n || 0) >= MESSAGES_PER_HOUR) return json({ error: "slow down" }, 429);
    if (Number(request.headers.get("content-length") || 0) > 3 * MAX_REPLY * 4) return json({ error: "too big" }, 413);
    let body;
    try { body = await request.json(); } catch { return json({ error: "body" }, 400); }
    const value = String(body?.text || "").trim().slice(0, MAX_REPLY);
    if (!value) return json({ error: "empty" }, 400);
    await env.DB.prepare("INSERT INTO messages (report_id, created_at, author, text) VALUES (?, ?, 'user', ?)")
      .bind(row.id, now, value).run();
    // A reply to a closed report opens it again: it needs looking at.
    await env.DB.prepare(
      "UPDATE reports SET updated_at = ?, status = CASE WHEN status = 'closed' THEN 'open' ELSE status END WHERE id = ?")
      .bind(now, row.id).run();
    return json({ ok: true });
  }
  return json({ error: "not found" }, 404);
}

// MARK: Bot (works through the reports every hour)

async function bot(request, env, url) {
  if (!(await bearer(request, env.BOT_TOKEN))) return json({ error: "auth" }, 401);
  const parts = url.pathname.split("/").filter(Boolean); // v1, bot, ...

  // What needs a look: open reports whose last word is not the developer's, in-progress ones the
  // sender wrote to, and in-progress ones untouched for RECHECK_DAYS (is the fix out yet?).
  // Setting a status touches the report, which starts that wait again. Filtered in SQL, before the LIMIT.
  if (parts[2] === "inbox" && request.method === "GET") {
    const recheck = Math.floor(Date.now() / 1000) - RECHECK_DAYS * 86400;
    const rows = (await env.DB.prepare(
      `SELECT * FROM (
         SELECT r.id, r.created_at, r.updated_at, r.status, r.kind, r.error_kind, r.message, r.app_version, r.build,
                r.channel, r.os, r.device, r.locale, r.photos,
                (SELECT author FROM messages m WHERE m.report_id = r.id ORDER BY m.id DESC LIMIT 1) AS last_author
         FROM reports r WHERE r.status != 'closed')
       WHERE (status = 'open' AND COALESCE(last_author, '') != 'dev')
          OR (status = 'in_progress' AND (last_author = 'user' OR MAX(created_at, updated_at) < ?))
       ORDER BY created_at LIMIT 100`).bind(recheck).all()).results;
    return json({ reports: rows });
  }

  const row = parts[2] === "report" && parts[3]
    ? await env.DB.prepare("SELECT * FROM reports WHERE id = ?").bind(parts[3]).first() : null;
  if (!row) return json({ error: "not found" }, 404);

  if (!parts[4] && request.method === "GET") {
    const thread = (await env.DB.prepare("SELECT id, created_at, author, text FROM messages WHERE report_id = ? ORDER BY id")
      .bind(row.id).all()).results;
    const { ip_hash, install_id, ...report } = row;
    const photos = (row.photo_exts || "").split(",").filter(Boolean).map((_, i) => `${url.origin}/v1/bot/report/${row.id}/photo/${i}`);
    return json({ report, thread, photos });
  }
  if (parts[4] === "photo" && request.method === "GET") {
    const index = Number(parts[5]);
    const ext = (row.photo_exts || "").split(",").filter(Boolean)[index];
    const object = ext ? await env.PHOTOS.get(`${row.id}/${index}.${ext}`) : null;
    if (!object) return json({ error: "not found" }, 404);
    return new Response(object.body, { headers: { "content-type": ext === "png" ? "image/png" : "image/jpeg" } });
  }
  if (request.method === "POST" && (parts[4] === "reply" || parts[4] === "status")) {
    let body;
    try { body = await request.json(); } catch { return json({ error: "body" }, 400); }
    if (body?.expect_user_revision !== undefined) {
      const revision = body.expect_user_revision;
      if (!Number.isSafeInteger(revision) || revision < 0 || !STATUSES.includes(body.status)) {
        return json({ error: "condition" }, 400);
      }
      const message = String(body.text || "").trim().slice(0, MAX_REPLY);
      if (parts[4] === "reply" && !message) return json({ error: "empty" }, 400);
      // D1 batch is transactional: a user message cannot slip between the conditional
      // reply and status update. Message IDs also detect arrivals within the same second.
      const guard = `EXISTS (SELECT 1 FROM reports WHERE id = ?)
        AND COALESCE((SELECT MAX(id) FROM messages WHERE report_id = ? AND author = 'user'), 0) = ?`;
      const now = Math.floor(Date.now() / 1000);
      const statements = [];
      if (parts[4] === "reply") {
        statements.push(env.DB.prepare(`INSERT INTO messages (report_id, created_at, author, text)
          SELECT ?, ?, 'dev', ? WHERE ${guard}`).bind(row.id, now, message, row.id, row.id, revision));
      }
      statements.push(env.DB.prepare(`UPDATE reports SET status = ?, updated_at = ?
        WHERE id = ? AND ${guard}`).bind(body.status, now, row.id, row.id, row.id, revision));
      const results = await env.DB.batch(statements);
      if (!results[results.length - 1].meta.changes) return json({ error: "stale report" }, 409);
      return json({ ok: true });
    }
    if (parts[4] === "reply") {
      if (!String(body?.text || "").trim()) return json({ error: "empty" }, 400);
      await addDevMessage(env, row.id, body.text, body.status);
    } else if (!(await setStatus(env, row.id, body?.status))) {
      return json({ error: "status" }, 400);
    }
    return json({ ok: true });
  }
  return json({ error: "not found" }, 404);
}

async function addDevMessage(env, id, value, status) {
  const message = String(value || "").trim().slice(0, MAX_REPLY);
  if (!message) return;
  const now = Math.floor(Date.now() / 1000);
  await env.DB.prepare("INSERT INTO messages (report_id, created_at, author, text) VALUES (?, ?, 'dev', ?)").bind(id, now, message).run();
  await env.DB.prepare("UPDATE reports SET updated_at = ? WHERE id = ?").bind(now, id).run();
  if (status) await setStatus(env, id, String(status));
}

async function setStatus(env, id, status) {
  if (!STATUSES.includes(status)) return false;
  await env.DB.prepare("UPDATE reports SET status = ?, updated_at = ? WHERE id = ?")
    .bind(status, Math.floor(Date.now() / 1000), id).run();
  return true;
}

async function bearer(request, token) {
  if (!token) return false;
  const header = request.headers.get("authorization") || "";
  if (!header.startsWith("Bearer ")) return false;
  const [a, b] = await Promise.all([sha256(header.slice(7)), sha256(token)]);
  return crypto.subtle.timingSafeEqual(a, b);
}

// MARK: Admin

async function admin(request, env, url) {
  if (!(await authorized(request, env))) {
    return new Response("Sign in", { status: 401, headers: { "www-authenticate": 'Basic realm="Sweet Lyrics reports"' } });
  }
  const parts = url.pathname.split("/").filter(Boolean); // admin, r|p, id, ...
  if (parts[1] === "ai") return page("AI answer complaints", await explainReportsPage(env, esc));

  if (parts.length === 1) {
    const kind = url.searchParams.get("kind");
    const status = url.searchParams.get("status");
    const pageIndex = Math.max(0, Number(url.searchParams.get("page")) || 0);
    const where = [], binds = [];
    if (kind) { where.push("kind = ?"); binds.push(kind); }
    if (status) { where.push("status = ?"); binds.push(status); }
    const rows = await env.DB.prepare(
      `SELECT id, created_at, status, kind, error_kind, message, app_version, build, channel, os, device, photos,
              (SELECT COUNT(*) FROM messages m WHERE m.report_id = reports.id) AS messages
       FROM reports ${where.length ? "WHERE " + where.join(" AND ") : ""}
       ORDER BY MAX(created_at, updated_at) DESC LIMIT 100 OFFSET ?`
    ).bind(...binds, pageIndex * 100).all();
    const query = (extra) => "?" + new URLSearchParams({ ...(kind ? { kind } : {}), ...(status ? { status } : {}), ...extra });
    const pager = (pageIndex ? `<a href="/admin${query({ page: pageIndex - 1 })}">← newer</a> ` : "") +
      (rows.results.length === 100 ? `<a href="/admin${query({ page: pageIndex + 1 })}">older →</a>` : "");
    const body = rows.results.map((r) =>
      `<tr><td><a href="/admin/r/${r.id}">${esc(when(r.created_at))}</a></td>` +
      `<td>${esc(r.status)}${r.messages ? " · " + r.messages + " msg" : ""}</td><td>${esc(r.kind)}</td>` +
      `<td>${esc(r.app_version)} ${esc(r.channel)} (${esc(r.build)})</td><td>${esc(r.os)}</td><td>${esc(r.device)}</td>` +
      `<td>${r.photos ? "photos: " + r.photos : ""}</td><td>${esc(r.error_kind || "")} ${esc((r.message || "").slice(0, 120))}</td></tr>`
    ).join("");
    return page("Reports",
      `<p><a href="/admin">all</a> · <a href="/admin?kind=manual">manual</a> · <a href="/admin?kind=auto">auto</a> · ` +
      STATUSES.map((s) => `<a href="/admin?status=${s}">${s}</a>`).join(" · ") + ` · <a href="/admin/ai">AI answer complaints</a></p>` +
      `<table><tr><th>When</th><th>Status</th><th>Kind</th><th>App</th><th>iOS</th><th>Device</th><th></th><th>Note / error</th></tr>${body}</table><p>${pager}</p>`);
  }

  if (parts[1] === "r" && parts[2]) {
    const row = await env.DB.prepare("SELECT * FROM reports WHERE id = ?").bind(parts[2]).first();
    if (!row) return text("Not found\n", 404);
    if (parts[3] === "log.txt") {
      return new Response(row.log || "", { headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });
    }
    if (parts[3] === "delete" && request.method === "POST") {
      if (request.headers.get("origin") !== url.origin) return text("Forbidden\n", 403);
      await deletePhotos(env, row);
      await env.DB.prepare("DELETE FROM messages WHERE report_id = ?").bind(row.id).run();
      await env.DB.prepare("DELETE FROM reports WHERE id = ?").bind(row.id).run();
      return Response.redirect(url.origin + "/admin", 303);
    }
    if ((parts[3] === "reply" || parts[3] === "status") && request.method === "POST") {
      if (request.headers.get("origin") !== url.origin) return text("Forbidden\n", 403);
      const form = await request.formData();
      if (parts[3] === "reply") await addDevMessage(env, row.id, String(form.get("text") || ""), form.get("status"));
      else await setStatus(env, row.id, String(form.get("status") || ""));
      return Response.redirect(`${url.origin}/admin/r/${row.id}`, 303);
    }
    const thread = (await env.DB.prepare("SELECT * FROM messages WHERE report_id = ? ORDER BY id").bind(row.id).all()).results;
    const exts = (row.photo_exts || "").split(",").filter(Boolean);
    const images = exts.map((_, i) =>
      `<a href="/admin/p/${row.id}/${i}"><img src="/admin/p/${row.id}/${i}" style="max-width:320px;margin:4px"></a>`).join("");
    return page("Report",
      `<p><a href="/admin">← all</a></p>` +
      `<p><b>${esc(when(row.created_at))}</b> · ${esc(row.kind)} ${esc(row.error_kind || "")}</p>` +
      `<p>${esc(row.app_version)} ${esc(row.channel)} (${esc(row.build)}) · iOS ${esc(row.os)} · ${esc(row.device)} · ${esc(row.locale)}` +
      `<br>install ${esc(row.install_id)}</p>` +
      `<p>Status: <b>${esc(row.status)}</b> ` +
      STATUSES.filter((s) => s !== row.status).map((s) =>
        `<form method="post" action="/admin/r/${row.id}/status" style="display:inline">` +
        `<input type="hidden" name="status" value="${s}"><button>${s}</button></form>`).join(" ") + `</p>` +
      (row.message ? `<h3>Note</h3><pre>${esc(row.message)}</pre>` : "") +
      (thread.length ? `<h3>Thread</h3>` + thread.map((m) =>
        `<p><b>${m.author === "dev" ? "Developer" : "Sender"}</b> · ${esc(when(m.created_at))}</p><pre>${esc(m.text)}</pre>`).join("") : "") +
      `<form method="post" action="/admin/r/${row.id}/reply"><textarea name="text" rows="4" style="width:100%;max-width:640px" required></textarea><br>` +
      `<select name="status"><option value="">keep status</option>${STATUSES.map((s) => `<option>${s}</option>`).join("")}</select> ` +
      `<button>Reply</button></form>` +
      (images ? `<h3>Photos</h3>${images}` : "") +
      `<h3>Log</h3><p><a href="/admin/r/${row.id}/log.txt">log.txt</a></p><pre>${esc(row.log || "")}</pre>` +
      `<form method="post" action="/admin/r/${row.id}/delete" onsubmit="return confirm('Delete this report?')"><button>Delete</button></form>`);
  }

  if (parts[1] === "p" && parts[2] && parts[3]) {
    const row = await env.DB.prepare("SELECT photo_exts FROM reports WHERE id = ?").bind(parts[2]).first();
    const index = Number(parts[3]);
    const ext = (row?.photo_exts || "").split(",").filter(Boolean)[index];
    if (!ext) return text("Not found\n", 404);
    const object = await env.PHOTOS.get(`${parts[2]}/${index}.${ext}`);
    if (!object) return text("Not found\n", 404);
    return new Response(object.body, {
      headers: { "content-type": ext === "png" ? "image/png" : "image/jpeg", "cache-control": "private, max-age=3600" },
    });
  }
  return text("Not found\n", 404);
}

async function authorized(request, env) {
  if (!env.ADMIN_TOKEN) return false;
  const header = request.headers.get("authorization") || "";
  if (!header.startsWith("Basic ")) return false;
  let password = "";
  try {
    password = atob(header.slice(6)).split(":").slice(1).join(":");
  } catch {
    return false;
  }
  const [a, b] = await Promise.all([sha256(password), sha256(env.ADMIN_TOKEN)]);
  return crypto.subtle.timingSafeEqual(a, b);
}

// MARK: Helpers

async function sha256(value) {
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
}

async function sha256Hex(value) {
  return [...new Uint8Array(await sha256(value))].slice(0, 12).map((b) => b.toString(16).padStart(2, "0")).join("");
}

const ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (c) => ESCAPES[c]);
const when = (seconds) => new Date(seconds * 1000).toISOString().replace("T", " ").slice(0, 19) + " UTC";

function page(title, body) {
  return new Response(
    `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${esc(title)}</title>` +
      `<style>body{font:14px system-ui;margin:16px}table{border-collapse:collapse}td,th{padding:4px 10px;border-bottom:1px solid #8884;` +
      `text-align:left;vertical-align:top}pre{white-space:pre-wrap;word-break:break-word;font-size:12px;background:#8881;padding:8px}</style>${body}`,
    {
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
        "x-robots-tag": "noindex",
        "content-security-policy": "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; form-action 'self'; script-src 'unsafe-inline'; frame-ancestors 'none'",
        "x-frame-options": "DENY",
      },
    },
  );
}

const json = (value, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
const text = (value, status = 200) =>
  new Response(value, { status, headers: { "content-type": "text/plain; charset=utf-8" } });
