# Report collector, translation cache and line explanations (Cloudflare Worker)

Receives the reports the app sends (Settings → Error Reports): a note, up to three photos and the sync
log. Text goes to D1, photos to R2. Every report is a thread: the developer (or the bot) answers, the
app shows the answers and the sender can reply. A report is deleted 90 days after its last message or
status change (nightly cron), so a thread still being talked in stays.

- `POST /v1/report`: multipart form: `meta` (JSON), `log` (text), `photo` (up to 3 JPEG/PNG, 2 MB each).
  Limits: 8 MB per request, 12 reports per hour per install, 40 per hour / 200 per day per network.
- `GET /v1/threads`, `POST /v1/threads/{id}/messages`: the sender's side, header `X-Install-Id`.
- `/v1/bot/…` (`inbox`, `report/{id}`, `reply`, `status`): private report processing, `Authorization: Bearer
  $BOT_TOKEN`. The scheduled processor runs on the server; see [`server/report-bot`](../server/report-bot/README.md).
- `POST /v1/translate`: lyric translations for the app. JSON `{"target": "ru", "lines": ["…"]}` (up to 300 lines
  of 500 characters) → `{"translations": {"line": "перевод"}, "cached": n, "limited": false}`. Google's free endpoint,
  Yandex when Google refuses; every answer goes into D1 (`translations`), shared by all installs, so a line anyone
  has had translated costs no request upstream. Only uncached lines count against a network's limit (60 000
  characters an hour); over it, the cached lines still come back (`limited: true`). Lines nobody asked for in
  180 days are dropped by the nightly cron.
- `POST /v1/explain`: "what does this line mean". JSON `{"track": {"title", "artists": [..], "album"}, "lines": [the
  whole text], "index": 4, "language": "ru"}` (`index: null` explains the whole song) → `{"summary", "meaning",
  "notes": [{"phrase", "note"}], "artists": [{"name", "summary", "description", "url"}], "cached"}`. The model
  (`mercury-3` from [Inception](https://docs.inceptionlabs.ai/), secret `INCEPTION_API_KEY`) gets the whole song with
  the line marked, what Genius has on the song (its description, the line's annotations and the artist's bio, kept in
  `genius_songs` for 30 days), up to three searches through Genius and Wikipedia that the model asks for itself, and the
  artists' Wikipedia intros (the app's language when that wiki has the page, else English;
  kept in `artist_bios` for 30 days). Answers are kept in `explanations`, shared by all installs; 40 uncached answers
  per network per hour. Without the secret the endpoint answers 503 and the app says explanations are unavailable. Every answer is in the app's language: one that isn't (checked by script) is asked for once more.
- `POST /v1/explain/report`: `{"id": "<the answer's id>", "reason": "wrong|language|offensive|other", "comment"}`, header
  `X-Install-Id`. Kept in `explain_reports` with the answer as it was (20 per network per hour); a wrong or wrong-language
  answer also leaves the cache, so the next listener gets a new one. Read them at `/admin/ai`.
- `GET /v1/config`: the app's remote config (`RemoteConfig.swift`): lyrics timeout, queue look-ahead, cache
  lifetimes, a floor for Web API polling, and kill switches for auto reports and Canvas. The defaults live in
  `CLIENT_CONFIG` in `src/index.js`; to change them for every install without a release, set the `CLIENT_CONFIG`
  variable to JSON (merged over them), e.g. `{"minWebPollInterval": 5, "lookaheadDepth": 0}`.
- `/admin`: the list, a report with its photos and log, answer, set the status, delete. HTTP Basic: any user name, the password
  is the `ADMIN_TOKEN` secret.

Only a random per-install id, the app and iOS version and the phone model are stored with a report. The
network address is stored only as a salted hash (salt: the `IP_SALT` secret), for the limits above.
Without `IP_SALT` the admin password is the salt, and changing it resets the limits.

## Set up

```sh
cd cloudflare
npx wrangler login
npx wrangler d1 create sweet-lyrics-reports          # put the id in wrangler.toml
npx wrangler r2 bucket create sweet-lyrics-report-photos
npx wrangler d1 execute sweet-lyrics-reports --remote --file=schema.sql
npx wrangler secret put ADMIN_TOKEN                  # the admin password
npx wrangler secret put IP_SALT                      # any long random string, never changed
npx wrangler secret put BOT_TOKEN                    # the report bot's password (see below)
npx wrangler secret put INCEPTION_API_KEY            # Mercury, for /v1/explain
npx wrangler deploy
```

`schema.sql` is the whole current schema: run it alone on a new database. `migrations/` only brings a
database made before threads existed up to date (`wrangler d1 execute … --file=migrations/0001_threads.sql`);
never run it on a database made from the current `schema.sql` (the columns already exist).
`migrations/0002_translations.sql` (the translation cache) `0003_explanations.sql` (explanations) and `0004_explain_reports.sql` (Genius pages and complaints) are safe on any database:

```sh
npx wrangler d1 execute sweet-lyrics-reports --remote --file=migrations/0002_translations.sql
npx wrangler d1 execute sweet-lyrics-reports --remote --file=migrations/0003_explanations.sql
npx wrangler d1 execute sweet-lyrics-reports --remote --file=migrations/0004_explain_reports.sql
```

For local runs put the key in `.dev.vars` (`INCEPTION_API_KEY=...`, git-ignored).

After the first setup, GitHub Actions deploys the Worker (`.github/workflows/cloudflare-worker.yml`):
pull requests that touch `cloudflare/` or `server/report-bot/` get a check (syntax, report bot tests,
`wrangler deploy --dry-run`), and every such push to `main` is deployed. It needs two repository
secrets: `CLOUDFLARE_API_TOKEN` (the "Edit Cloudflare Workers" template, with D1 and R2 edit added)
and `CLOUDFLARE_ACCOUNT_ID`. Schema changes are not applied automatically: run them by hand before
merging the Worker that needs them.

## Report bot

Report processing runs on the private server through the Codex CLI in an isolated container. The
server stores feature requests and private analysis locally before replying. Fixes are proposed in
draft pull requests and are never merged automatically. The scheduled GitHub Actions workflow is
retired.

The app posts to the URL in `SpicyLyrics/Support/ReportService.swift` (`endpoint`).
