"""Tests for the phase decision in dev_state.py (pure logic, no GitHub access).

Run: python3 -m unittest discover -s .claude/skills/dev/scripts
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from dev_state import BRANCH_RE, infer_phase, issue_from_branch, summarize_checks  # noqa: E402

OPEN_ISSUE = {"number": 12, "state": "OPEN"}
CLEAN = {"branch": "main", "dirty_files": []}


def branch(**kw):
    b = {"name": "feat/12-jog", "local": True, "remote": True, "ahead_of_default": 3, "unpushed": 0}
    b.update(kw)
    return b


def pr(**kw):
    p = {"number": 15, "state": "OPEN", "isDraft": False, "mergeable": "MERGEABLE", "reviewDecision": None,
         "checks": {"overall": "success", "failing": [], "pending": [], "passing": ["ci"]}, "threads": []}
    p.update(kw)
    return p


class InferPhase(unittest.TestCase):
    def phase(self, issue=OPEN_ISSUE, b=None, p=None, local=CLEAN):
        return infer_phase(issue, b, p, local)["phase"]

    def test_not_started(self):
        self.assertEqual(self.phase(), "1")

    def test_branch_without_commits(self):
        self.assertEqual(self.phase(b=branch(ahead_of_default=0, remote=False)), "4")

    def test_dirty_branch_is_implementing(self):
        local = {"branch": "feat/12-jog", "dirty_files": [" M a.gd"]}
        self.assertEqual(self.phase(b=branch(), local=local), "4")

    def test_unpushed(self):
        self.assertEqual(self.phase(b=branch(remote=False, unpushed=3)), "5")

    def test_pushed_no_pr(self):
        self.assertEqual(self.phase(b=branch()), "6")

    def test_ci_pending(self):
        p = pr(checks={"overall": "pending", "failing": [], "pending": ["ci"], "passing": []})
        self.assertEqual(self.phase(b=branch(), p=p), "7")

    def test_ci_failing(self):
        p = pr(checks={"overall": "failure", "failing": ["ci"], "pending": [], "passing": []})
        self.assertEqual(self.phase(b=branch(), p=p), "8")

    def test_unresolved_review(self):
        p = pr(threads=[{"severity": "P1", "outdated": False}])
        self.assertEqual(self.phase(b=branch(), p=p), "8")

    def test_outdated_thread_does_not_block(self):
        p = pr(threads=[{"severity": "P2", "outdated": True}])
        self.assertEqual(self.phase(b=branch(), p=p), "9")

    def test_conflict(self):
        self.assertEqual(self.phase(b=branch(), p=pr(mergeable="CONFLICTING")), "8")

    def test_ready_to_merge(self):
        self.assertEqual(self.phase(b=branch(), p=pr()), "9")

    def test_no_ci_is_not_ready(self):
        p = pr(checks={"overall": "none", "failing": [], "pending": [], "passing": []})
        self.assertEqual(self.phase(b=branch(), p=p), "7")

    def test_merged_issue_open(self):
        self.assertEqual(self.phase(b=branch(), p=pr(state="MERGED")), "10")

    def test_merged_issue_closed(self):
        self.assertEqual(self.phase(issue={"number": 12, "state": "CLOSED"}, b=branch(), p=pr(state="MERGED")), "done")

    def test_closed_unmerged(self):
        self.assertEqual(self.phase(b=branch(), p=pr(state="CLOSED")), "attention")


class Helpers(unittest.TestCase):
    def test_branch_names(self):
        self.assertEqual(issue_from_branch("feat/12-keyboard-jog"), 12)
        self.assertEqual(issue_from_branch("remotes/origin/fix/7-rope.nan"), 7)
        self.assertIsNone(issue_from_branch("feat/use-new-ufo-assets"))
        self.assertIsNone(issue_from_branch("main"))
        self.assertIsNotNone(BRANCH_RE.match("chore/4-dev-workflow"))

    def test_checks(self):
        roll = [{"__typename": "CheckRun", "name": "a", "status": "COMPLETED", "conclusion": "SUCCESS"},
                {"__typename": "CheckRun", "name": "b", "status": "IN_PROGRESS", "conclusion": None}]
        self.assertEqual(summarize_checks(roll)["overall"], "pending")
        roll.append({"__typename": "StatusContext", "context": "c", "state": "FAILURE"})
        self.assertEqual(summarize_checks(roll)["overall"], "failure")
        self.assertEqual(summarize_checks([])["overall"], "none")


if __name__ == "__main__":
    unittest.main()
