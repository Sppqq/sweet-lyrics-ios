import copy
import json
import argparse
import io
import re
import shutil
import sqlite3
import sys
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch

import report_bot as bot


class ReportBotTests(unittest.TestCase):
    def setUp(self):
        self.report = {"report": {"id": "abc", "kind": "manual", "message": "cache", "status": "open", "updated_at": 0}, "thread": []}
        self.result = {"kind": "feature", "title": "Cache size", "analysis": "Add size display",
                       "reply": "Спасибо!", "status": "closed", "fix": False, "validation": "Not implemented"}

    def test_feature_is_durable_before_reply(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = bot.database(Path(tmp))
            result = bot.validate_result(self.result)
            bot.save_task(db, self.report, result, "")
            db.close()
            db = bot.database(Path(tmp))
            row = db.execute("SELECT * FROM tasks").fetchone()
            self.assertEqual(row["status"], "in_progress")
            self.assertIn("списке задач", row["reply"])
            self.assertEqual(row["delivered"], 0)
            db.close()

    def test_user_reply_changes_fingerprint_but_dev_reply_does_not(self):
        original = bot.fingerprint(self.report)
        self.report["report"].update(status="closed", updated_at=40)
        self.report["thread"].append({"author": "dev", "text": "hello"})
        self.assertEqual(original, bot.fingerprint(self.report))
        self.report["thread"].append({"author": "user", "text": "clarification"})
        self.assertNotEqual(original, bot.fingerprint(self.report))

    def test_reject_workflow_and_hidden_file_edits(self):
        for name in (".github/workflows/build.yml", "SpicyLyrics/.claude/settings.js", "cloudflare/src/package.json"):
            with self.assertRaises(ValueError):
                bot.changed_files({}, {name: "modified"})
        self.assertEqual(bot.changed_files({"SpicyLyrics/Cache.swift": "old"}, {"SpicyLyrics/Cache.swift": "new"}), ["SpicyLyrics/Cache.swift"])

    def test_invalid_claim_and_result_types(self):
        bad = dict(self.result, fix="yes")
        with self.assertRaises(ValueError):
            bot.validate_result(bad)
        with self.assertRaises(ValueError):
            bot.validate_result(dict(self.result, fix=True, validation=""))

    def test_auto_reports_have_no_reply(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = bot.database(Path(tmp))
            self.report["report"]["kind"] = "auto"
            bot.save_task(db, self.report, bot.validate_result(self.result), "")
            self.assertEqual(db.execute("SELECT reply FROM tasks").fetchone()[0], "")
            db.close()

    def test_crash_retry_does_not_send_duplicate(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = bot.database(Path(tmp))
            bot.save_task(db, self.report, bot.validate_result(self.result), "")
            row = db.execute("SELECT * FROM tasks").fetchone()
            current = copy.deepcopy(self.report)
            current["thread"].append({"author": "dev", "text": row["reply"]})
            with patch.dict(bot.os.environ, {"BOT_TOKEN": "test"}), patch.object(bot, "request", side_effect=[current, {"ok": True}]) as req:
                bot.deliver(db, row)
            self.assertTrue(req.call_args_list[1].args[0].endswith("/status"))
            self.assertEqual(db.execute("SELECT delivered FROM tasks").fetchone()[0], 1)
            db.close()

    def test_photos_use_container_paths_and_pending_repair_resumes(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            (state / "auth.json").write_text('{}')
            report = copy.deepcopy(self.report)
            report["photos"] = [bot.BASE + "/v1/bot/report/abc/photo/0"]
            result = dict(self.result, kind="bug", fix=True, status="in_progress")
            response = MagicMock()
            response.__enter__.return_value = response
            response.headers.get_content_type.return_value = "image/png"
            response.read.return_value = b"photo"

            def command(args, *unused, **kwargs):
                if args[:2] == ["git", "clone"]:
                    source = Path(args[-1])
                    (source / ".git").mkdir(parents=True)
                    (source / "SpicyLyrics").mkdir()
                    (source / "SpicyLyrics/Fix.swift").write_text("before")
                return "a" * 40

            def run(args, **kwargs):
                if args[:2] == ["docker", "run"]:
                    self.assertEqual(args[args.index("--image") + 1], "/input/photo-0.png")
                    mounts = [args[i + 1] for i, value in enumerate(args) if value == "-v"]
                    source = Path(next(m.rsplit(":/work:", 1)[0] for m in mounts if ":/work:" in m))
                    output = Path(next(m.rsplit(":/output:", 1)[0] for m in mounts if ":/output:" in m))
                    (source / "SpicyLyrics/Fix.swift").write_text("after")
                    (output / "result.json").write_text(json.dumps(result))
                return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

            with patch.dict(bot.os.environ, BOT_TOKEN="test"), \
                    patch.object(bot.os, "getuid", return_value=1000, create=True), \
                    patch.object(bot.os, "getgid", return_value=1000, create=True), \
                    patch.object(bot, "command", side_effect=command) as cmd, \
                    patch.object(bot, "github", return_value=[{"title": "Existing repair", "html_url": "pr", "head": {
                        "ref": "bot/report-abc", "repo": {"full_name": bot.REPO}}}]), \
                    patch.object(bot.urllib.request, "urlopen", return_value=response), \
                    patch.object(bot.subprocess, "run", side_effect=run), \
                    patch.object(bot, "publish", side_effect=RuntimeError("uncertain publication")):
                with self.assertRaises(RuntimeError):
                    bot.analyze(state, report, None)
            self.assertTrue(any(call.args[0] == ["git", "checkout", "--detach", "FETCH_HEAD"] for call in cmd.call_args_list))
            self.assertEqual(len(list(state.glob("job-*/repair.json"))), 1)
            # A restart must reuse the reviewed source and result without launching Codex.
            with patch.object(bot, "publish", return_value="https://github.com/test/pr/1") as publish, \
                    patch.object(bot.subprocess, "run") as run:
                recovered, pr = bot.analyze(state, report, None)
            run.assert_not_called()
            self.assertTrue(recovered["fix"])
            self.assertEqual(pr, "https://github.com/test/pr/1")
            self.assertEqual(publish.call_args.args[2], ["SpicyLyrics/Fix.swift"])

    def test_existing_open_pr_is_reused_without_push(self):
        pr = {"state": "open", "base": {"ref": "main"},
              "head": {"ref": "bot/report-abc", "sha": "a" * 40, "repo": {"full_name": bot.REPO}},
              "html_url": "https://github.com/test/pr/1"}
        with tempfile.TemporaryDirectory() as tmp:
            job = Path(tmp)
            (job / "publication-commit").write_text("a" * 40)
            with patch.object(bot, "github", return_value=[pr]), patch.object(bot, "command") as cmd:
                self.assertEqual(bot.publish(job, job, [], self.result, self.report), pr["html_url"])
                cmd.assert_not_called()
                pr["state"] = "closed"
                with self.assertRaises(ValueError):
                    bot.publish(job, job, [], self.result, self.report)

    def test_retry_after_push_reuses_persisted_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            job = Path(tmp)
            (job / "publish").mkdir()
            (job / "publication-commit").write_text("a" * 40)
            pr = {"head": {"ref": "bot/report-abc"}, "base": {"ref": "main"}, "html_url": "pr"}
            with patch.object(bot, "github", side_effect=[[], pr]), \
                    patch.object(bot, "command", side_effect=[bot.public_title(self.result, "abc"), "", ""]) as cmd:
                self.assertEqual(bot.publish(job, job / "source", [], self.result, self.report), "pr")
            self.assertEqual(cmd.call_count, 3)
            self.assertEqual(cmd.call_args.args[0][-1], "a" * 40 + ":refs/heads/bot/report-abc")

    def test_missing_report_retires_outbox_but_transient_errors_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = bot.database(Path(tmp))
            bot.save_task(db, self.report, bot.validate_result(self.result), "")
            row = db.execute("SELECT * FROM tasks").fetchone()
            with patch.dict(bot.os.environ, BOT_TOKEN="test"), \
                    patch.object(bot, "request", side_effect=bot.RequestError("example", 503)):
                with self.assertRaises(bot.RequestError):
                    bot.deliver(db, row)
            self.assertEqual(db.execute("SELECT delivered FROM tasks").fetchone()[0], 0)
            with patch.dict(bot.os.environ, BOT_TOKEN="test"), \
                    patch.object(bot, "request", side_effect=bot.RequestError("example", 404)):
                bot.deliver(db, row)
            self.assertEqual(db.execute("SELECT delivered FROM tasks").fetchone()[0], 1)
            db.close()

    def test_one_failed_delivery_and_report_do_not_block_queue(self):
        self.check_queue([RuntimeError("bad report"), None], 2)

    def test_manual_review_noops_do_not_block_new_inbox_items(self):
        self.check_queue([False] * 8 + [None] * 9, 16)

    def check_queue(self, outcomes, expected_calls):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            db = bot.database(state)
            bot.save_task(db, self.report, bot.validate_result(self.result), "")
            db.close()
            args = argparse.Namespace(action="run", state=state, dry_run=False)
            run_db = bot.database(state)
            with patch.dict(bot.os.environ, BOT_TOKEN="test"), \
                    patch.object(bot, "database", return_value=run_db), \
                    patch.object(bot.argparse.ArgumentParser, "parse_args", return_value=args), \
                    patch.object(bot.Path, "home", return_value=state), \
                    patch.object(bot, "deliver", side_effect=RuntimeError("retry")), \
                    patch.object(bot, "request", return_value={"reports": [{"id": str(i)} for i in range(len(outcomes))]}), \
                    patch.object(bot, "process_report", side_effect=outcomes) as process, \
                    patch.dict(sys.modules, {"fcntl": MagicMock()}), \
                    patch("sys.stderr", new_callable=io.StringIO):
                bot.main()
            run_db.close()
            self.assertEqual(process.call_count, expected_calls)
            self.assertEqual(process.call_args.args[2], {"id": str(expected_calls - 1)})

    def test_public_title_ignores_model_text_and_private_diff_is_rejected(self):
        result = dict(self.result, title='Contact person@example.invalid @sender +7 999 123-45-67')
        self.assertEqual(bot.public_title(result, "abc"), "Fix: feature report abc")
        cases = [
            ("person@example.invalid", "PERSON@example.invalid"),
            ("+7 (999) 123-45-67", "+79991234567"),
            ("Bearer abcDEF1234567890", "abcDEF1234567890"),
            ('api_key="short-secret"', "short-secret"),
            ("ghp_1234567890abcdef1234567890abcdef", "ghp_1234567890abcdef1234567890abcdef"),
            ("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ", "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
        ]
        for original, published in cases:
            with self.subTest(original=original):
                report = copy.deepcopy(self.report)
                report["thread"].append({"author": "user", "text": original})
                with self.assertRaisesRegex(ValueError, "private report data"):
                    bot.check_private_diff('+let value = "' + published + '"', report)
                bot.check_private_diff('+let value = "safe"', report)

    def test_publish_uses_safe_title_updates_old_pr_and_blocks_private_data(self):
        # Exercise the real publication preparation, including the pre-commit privacy gate.
        for existing, leak in ((False, False), (True, False), (False, True)):
            with self.subTest(existing=existing, leak=leak), tempfile.TemporaryDirectory() as tmp:
                job = Path(tmp)
                source = job / "source"
                (source / "SpicyLyrics").mkdir(parents=True)
                (source / "SpicyLyrics/Fix.swift").write_text("safe")
                (job / "commit").write_text("b" * 40)  # Current PR head for a new fingerprint.
                report = copy.deepcopy(self.report)
                report["report"]["message"] = "person@example.invalid"
                result = dict(self.result, title="person@example.invalid", fix=True)
                pr = {"state": "open", "base": {"ref": "main"}, "head": {
                    "ref": "bot/report-abc", "sha": "b" * 40, "repo": {"full_name": bot.REPO}}, "html_url": "pr"}
                calls = []

                def command(args, *unused, **kwargs):
                    calls.append(args)
                    if args[:2] == ["git", "clone"]:
                        Path(args[-1]).mkdir()
                    if args[:3] == ["git", "rev-parse", "HEAD"]:
                        return "a" * 40
                    if args[:4] == ["git", "show", "-s", "--format=%s"]:
                        return "Fix: feature report abc"
                    if "--cached" in args and leak:
                        return '+let note = "person@example.invalid"'
                    return ""

                with patch.object(bot, "github", side_effect=([[pr]] if existing else [[], pr])) as gh, \
                        patch.object(bot, "command", side_effect=command):
                    if leak:
                        with self.assertRaisesRegex(ValueError, "private report data"):
                            bot.publish(job, source, ["SpicyLyrics/Fix.swift"], result, report)
                        self.assertFalse(any("commit" in args or "push" in args for args in calls))
                        self.assertEqual(gh.call_count, 1)
                        continue
                    self.assertEqual(bot.publish(job, source, ["SpicyLyrics/Fix.swift"], result, report), "pr")
                commit = next(args for args in calls if "commit" in args)
                self.assertEqual(commit[-1], "Fix: feature report abc")
                self.assertTrue(any(args[-1] == "a" * 40 + ":refs/heads/bot/report-abc" for args in calls))
                self.assertFalse(any("--force" in args for args in calls))
                self.assertIn(["git", "checkout", "-b", "bot/report-abc", "b" * 40], calls)
                if not existing:
                    self.assertEqual(gh.call_args.args[1]["title"], "Fix: feature report abc")
                else:
                    self.assertEqual(gh.call_count, 1)  # Update the same PR, do not open another.

    def test_persisted_repair_is_privacy_checked_before_retry_push(self):
        with tempfile.TemporaryDirectory() as tmp:
            job = Path(tmp)
            (job / "publication-commit").write_text("a" * 40)
            report = copy.deepcopy(self.report)
            report["report"]["log"] = "Bearer abcDEF1234567890"
            with patch.object(bot, "github", return_value=[]), patch.object(bot, "command", side_effect=[
                    "Fix: feature report abc", "+abcDEF1234567890"]) as cmd:
                with self.assertRaisesRegex(ValueError, "private report data"):
                    bot.publish(job, job, [], self.result, report)
                self.assertFalse(any("push" in call.args[0] for call in cmd.call_args_list))

    def test_stale_outbox_and_post_race_return_task_to_analysis(self):
        for race in (False, True):
            with self.subTest(race=race), tempfile.TemporaryDirectory() as tmp:
                db = bot.database(Path(tmp))
                bot.save_task(db, self.report, dict(self.result, kind="expected", status="closed"), "")
                row = db.execute("SELECT * FROM tasks").fetchone()
                current = copy.deepcopy(self.report)
                if not race:
                    current["thread"].append({"id": 1, "author": "user", "text": "It crashes"})
                effects = [current, bot.RequestError("test", 409)] if race else [current]
                with patch.dict(bot.os.environ, BOT_TOKEN="test"), patch.object(bot, "request", side_effect=effects) as req:
                    bot.deliver(db, row)
                saved = db.execute("SELECT * FROM tasks").fetchone()
                self.assertEqual(saved["fingerprint"], "")
                self.assertEqual(saved["reply"], "")
                self.assertEqual(saved["status"], "open")
                self.assertEqual(saved["delivered"], 1)
                self.assertEqual(req.call_count, 2 if race else 1)
                if race:
                    self.assertEqual(req.call_args.args[2]["expect_user_revision"], 0)
                # The invalidated fingerprint must bypass the old-task recheck shortcut.
                current["report"]["id"] = "00000000-0000-4000-8000-000000000001"
                db.execute("UPDATE tasks SET report_id=?", (current["report"]["id"],))
                db.commit()
                with patch.dict(bot.os.environ, BOT_TOKEN="test"), patch.object(bot, "request", return_value=current), \
                        patch.object(bot, "analyze", return_value=(None, "")) as analyze:
                    bot.process_report(db, argparse.Namespace(dry_run=False, state=Path(tmp)), current["report"])
                    analyze.assert_called_once()
                db.close()

    def test_closed_unmerged_pr_becomes_manual_review_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = bot.database(Path(tmp))
            report = copy.deepcopy(self.report)
            report["report"]["id"] = "00000000-0000-4000-8000-000000000001"
            bot.save_task(db, report, dict(self.result, kind="bug", status="in_progress"),
                          "https://github.com/" + bot.REPO + "/pull/1")
            with patch.dict(bot.os.environ, BOT_TOKEN="test"), \
                    patch.object(bot, "request", side_effect=[report, report, {}, report]) as req, \
                    patch.object(bot, "github", return_value={"state": "closed", "merged_at": None}) as gh, \
                    patch.object(bot, "analyze") as analyze:
                bot.process_report(db, argparse.Namespace(dry_run=False, state=Path(tmp)), report["report"])
                first = dict(db.execute("SELECT * FROM tasks").fetchone())
                bot.process_report(db, argparse.Namespace(dry_run=False, state=Path(tmp)), report["report"])
                self.assertEqual(dict(db.execute("SELECT * FROM tasks").fetchone()), first)
            row = db.execute("SELECT * FROM tasks").fetchone()
            self.assertEqual(row["status"], "open")
            self.assertEqual(row["kind"], "question")
            self.assertIn("manual review required", row["analysis"])
            self.assertNotIn("подготовлено", row["reply"])
            posts = [call for call in req.call_args_list if len(call.args) == 3]
            self.assertEqual(len(posts), 1)
            self.assertEqual(posts[0].args[2]["status"], "open")
            self.assertEqual(row["manual_review"], 1)
            self.assertEqual(row["delivered"], 1)
            gh.assert_called_once()
            analyze.assert_not_called()
            db.close()

    def test_manual_review_retries_only_pending_delivery_and_reanalyzes_new_input(self):
        for kind in ("manual", "auto"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                db = bot.database(Path(tmp))
                report = copy.deepcopy(self.report)
                report["report"].update(id="00000000-0000-4000-8000-000000000001", kind=kind)
                args = argparse.Namespace(dry_run=False, state=Path(tmp))
                bot.save_task(db, report, dict(self.result, kind="question", status="open"),
                              "https://github.com/" + bot.REPO + "/pull/1", manual_review=True)
                # Persist the marker even when the first delivery fails, including across restart.
                db.close()
                db = bot.database(Path(tmp))
                original_analysis = db.execute("SELECT analysis FROM tasks").fetchone()[0]
                with patch.dict(bot.os.environ, BOT_TOKEN="test"), \
                        patch.object(bot, "request", return_value=report), \
                        patch.object(bot, "github") as gh, patch.object(bot, "analyze") as analyze:
                    with patch.object(bot, "deliver", side_effect=RuntimeError("temporary failure")) as delivery:
                        with self.assertRaises(RuntimeError):
                            bot.process_report(db, args, report["report"])
                        delivery.assert_called_once()
                    # Retry the real outbox delivery, then do nothing on the next identical pass.
                    with patch.object(bot, "request", side_effect=[report, report, {}, report]) as req:
                        bot.process_report(db, args, report["report"])
                        bot.process_report(db, args, report["report"])
                    self.assertEqual(len([c for c in req.call_args_list if len(c.args) == 3]), 1)
                    gh.assert_not_called()
                    analyze.assert_not_called()
                self.assertEqual(db.execute("SELECT analysis FROM tasks").fetchone()[0], original_analysis)
                updated = copy.deepcopy(report)
                updated["thread"].append({"id": 1, "author": "user", "text": "New clarification"})
                with patch.dict(bot.os.environ, BOT_TOKEN="test"), patch.object(bot, "request", return_value=updated), \
                        patch.object(bot, "analyze", return_value=(dict(self.result, kind="question", status="open"), "")) as analyze:
                    bot.process_report(db, args, updated["report"])
                    analyze.assert_called_once()
                self.assertEqual(db.execute("SELECT manual_review FROM tasks").fetchone()[0], 0)
                db.close()

    def test_final_reply_limit_matches_worker_and_retry_deduplicates(self):
        worker = (bot.HERE.parents[1] / "cloudflare/src/index.js").read_text(encoding="utf-8")
        limit = int(re.search(r"const MAX_REPLY = ([\d_]+)", worker)[1].replace("_", ""))
        self.assertEqual(bot.MAX_REPLY, limit)
        self.assertEqual(bot.bounded_reply("\ufeff hello \ufeff"), "hello")
        for text in ("x" * 6000, "😀" * 3000, "x" * 3999 + " " + "tail", "\ufeffhello"):
            with self.subTest(text_length=len(text)), tempfile.TemporaryDirectory() as tmp:
                db = bot.database(Path(tmp))
                bot.save_task(db, self.report, dict(self.result, reply=text, fix=True), "pr")
                row = db.execute("SELECT * FROM tasks").fetchone()
                self.assertLessEqual(len(row["reply"].encode("utf-16-le")) // 2, limit)
                self.assertEqual(row["reply"], row["reply"].strip())
                current = copy.deepcopy(self.report)
                current["thread"].append({"author": "dev", "text": row["reply"]})
                with patch.dict(bot.os.environ, BOT_TOKEN="test"), patch.object(bot, "request", side_effect=[current, {}]) as req:
                    bot.deliver(db, row)
                self.assertTrue(req.call_args.args[0].endswith("/status"))
                db.close()

    @unittest.skipUnless(shutil.which("node"), "Node.js is required to exercise the Worker")
    def test_worker_conditional_delivery_sql_rejects_same_second_user_message(self):
        # Run the real Worker route, capture its D1 batch, then execute that exact SQL
        # in SQLite. The user arrives after the route's initial SELECT, in the same second.
        script = r'''
import {pathToFileURL} from 'node:url';
import {webcrypto, timingSafeEqual} from 'node:crypto';
// Cloudflare's extension is absent from Node's Web Crypto API.
webcrypto.subtle.timingSafeEqual = (a, b) => timingSafeEqual(Buffer.from(a), Buffer.from(b));
Object.defineProperty(globalThis, 'crypto', {value: webcrypto});
console.error = error => process.stderr.write(String(error) + '\n');
// From its own path, so its imports of sibling modules (translate.js) resolve.
const worker = (await import(pathToFileURL(process.argv[1]).href)).default;
const expected = Number(process.argv[2]), actual = 1, endpoint = process.argv[3];
let batch;
const DB = {
  prepare(sql) { return {sql, bind(...args) { this.args = args; return this; },
    async first() { return {id: 'abc', status: 'open', updated_at: 100}; }}; },
  async batch(statements) { batch = statements.map(s => ({sql: s.sql, args: s.args}));
    return statements.map(() => ({meta: {changes: Number(expected === actual)}})); }
};
const response = await worker.fetch(new Request('https://test/v1/bot/report/abc/' + endpoint, {
  method: 'POST', headers: {Authorization: 'Bearer test', 'Content-Type': 'application/json'},
  body: JSON.stringify({text: 'reply', status: 'closed', expect_user_revision: expected})
}), {BOT_TOKEN: 'test', DB});
console.log(JSON.stringify({status: response.status, batch}));
'''
        for expected in (0, 1):
            for endpoint in ("reply", "status"):
                with self.subTest(expected=expected, endpoint=endpoint):
                    run = subprocess.run([shutil.which("node"), "--input-type=module", "-e", script,
                                          str(bot.HERE.parents[1] / "cloudflare/src/index.js"), str(expected), endpoint],
                                         capture_output=True, text=True, timeout=30, check=True)
                    result = json.loads(run.stdout)
                    self.assertEqual(result["status"], 200 if expected == 1 else 409, run.stderr)
                    db = sqlite3.connect(":memory:")
                    db.executescript((bot.HERE.parents[1] / "cloudflare/schema.sql").read_text(encoding="utf-8"))
                    db.execute("INSERT INTO reports (id,created_at,kind,status,updated_at) VALUES ('abc',100,'manual','open',100)")
                    db.execute("INSERT INTO messages (report_id,created_at,author,text) VALUES ('abc',100,'user','new input')")
                    db.commit()
                    with db:
                        for statement in result["batch"]:
                            db.execute(statement["sql"], statement["args"])
                    self.assertEqual(db.execute("SELECT status FROM reports").fetchone()[0], "closed" if expected == 1 else "open")
                    count = db.execute("SELECT COUNT(*) FROM messages WHERE author='dev'").fetchone()[0]
                    self.assertEqual(count, int(expected == 1 and endpoint == "reply"))
                    db.close()


if __name__ == "__main__":
    unittest.main()
