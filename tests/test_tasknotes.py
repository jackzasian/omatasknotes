"""Regression fixtures are temporary vaults; no personal vault is accessed."""
import contextlib
import io
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from datetime import date, timedelta

import yaml

helper = runpy.run_path(str(Path(__file__).resolve().parents[1] / "bin/omatasknotes"))


class TaskNotesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.vault = Path(self.tmp.name)
        self.tasks = self.vault / "TaskNotes/Tasks"
        self.tasks.mkdir(parents=True)
        self.views = self.vault / "TaskNotes/Views"
        self.views.mkdir()
        self.settings = {
            "tasksFolder": "TaskNotes/Tasks", "taskTag": "task",
            "enableAPI": False, "maintainDueDateOffsetInRecurring": False,
            "customStatuses": [{"value": "open", "order": 0},
                               {"value": "done", "order": 1, "isCompleted": True}],
            "customPriorities": [{"value": "urgent", "weight": 4}],
        }
        self.write_settings()
        self.base = {
            "filters": {'and': ['file.hasTag("task")']},
            "formulas": dict(helper["KNOWN_FORMULA_EXPRESSIONS"]),
            "views": [{"type": "tasknotesTaskList", "name": "Today",
                       "filters": {'and': ['status != "done"']},
                       "sort": [{"property": "formula.urgencyScore", "direction": "DESC"}]}],
        }
        self.write_base()

    def write_settings(self):
        p = self.vault / ".obsidian/plugins/tasknotes/data.json"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(self.settings))

    def write_base(self):
        (self.views / "tasks.base").write_text(yaml.safe_dump(self.base))

    def task(self, name, **fields):
        fm = {"title": name, "status": "open", "tags": ["task"], **fields}
        p = self.tasks / (name + ".md")
        p.write_text("---\n" + yaml.safe_dump(fm, sort_keys=False) + "---\nKeep body.\n")
        return p

    def call(self, command, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            helper[command](str(self.vault), *args)
        return json.loads(out.getvalue())

    def read_fm(self, p):
        return yaml.safe_load(p.read_text().split("---")[1])

    def hash(self, p):
        return helper["fm_hash"](helper["split_frontmatter"](p.read_text())[2])

    def test_base_formula_beats_different_custom_priority_weight(self):
        today = date.today().isoformat()
        self.task("high", priority="high", due=today)
        self.task("urgent", priority="urgent", due=today)
        result = self.call("cmd_scan", "base:TaskNotes/Views/tasks.base::Today")
        self.assertTrue(result["ok"])
        self.assertEqual([r["title"] for r in result["rows"]], ["urgent", "high"])
        self.assertEqual(helper["priority_weight"]({"fm": {"priority": "urgent"}}, self.settings), 999)

    def test_custom_formula_dependency_is_refused(self):
        self.base["formulas"]["priorityWeight"] = "4"
        self.write_base()
        result = self.call("cmd_views")
        self.assertFalse(result["views"][0]["supported"])
        self.assertIn("priorityWeight", result["views"][0]["reason"])
        result = self.call("cmd_scan", "base:TaskNotes/Views/tasks.base::Today")
        self.assertEqual(result["error"], "unsupported-view")

    def test_top_filter_and_view_filter_both_apply(self):
        self.base["filters"] = {'and': ['file.hasTag("study")']}
        self.write_base()
        self.task("life", priority="normal")
        self.task("study", priority="normal", tags=["task", "study"])
        self.task("done", priority="normal", tags=["task", "study"], status="done")
        result = self.call("cmd_scan", "base:TaskNotes/Views/tasks.base::Today")
        self.assertEqual([r["title"] for r in result["rows"]], ["study"])

    def recurring(self, due_days):
        today = date.today()
        return self.task("repeat", scheduled=today.isoformat(),
                         due=(today + timedelta(days=due_days)).isoformat(),
                         recurrence="DTSTART:" + today.strftime("%Y%m%d") + ";FREQ=DAILY")

    def test_disabled_due_offset_keeps_future_deadline(self):
        p = self.recurring(3)
        result = self.call("cmd_complete", str(p.relative_to(self.vault)), self.hash(p))
        self.assertTrue(result["ok"])
        self.assertEqual(str(self.read_fm(p)["due"]), (date.today() + timedelta(days=3)).isoformat())
        self.assertEqual(str(self.read_fm(p)["scheduled"]), (date.today() + timedelta(days=1)).isoformat())

    def test_enabled_due_offset_moves_future_deadline(self):
        self.settings["maintainDueDateOffsetInRecurring"] = True
        self.write_settings()
        p = self.recurring(3)
        self.assertTrue(self.call("cmd_complete", str(p.relative_to(self.vault)), self.hash(p))["ok"])
        self.assertEqual(str(self.read_fm(p)["due"]), (date.today() + timedelta(days=4)).isoformat())

    def test_disabled_due_offset_still_advances_overdue_deadline(self):
        p = self.recurring(-1)
        self.assertTrue(self.call("cmd_complete", str(p.relative_to(self.vault)), self.hash(p))["ok"])
        self.assertEqual(str(self.read_fm(p)["due"]), date.today().isoformat())

    def test_stale_scan_cannot_complete_changed_task(self):
        p = self.task("changed")
        expected_hash = self.hash(p)
        p.write_text(p.read_text().replace("status: open", "status: in-progress"))
        before = p.read_bytes()
        result = self.call("cmd_complete", str(p.relative_to(self.vault)), expected_hash)
        self.assertEqual(result["error"], "stale")
        self.assertEqual(p.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
