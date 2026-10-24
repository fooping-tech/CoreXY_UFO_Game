#!/usr/bin/env python3
"""Rebuild the development state from GitHub + git and say which /dev phase is next.

GitHub (issues, branches, PRs, checks, review threads) is the source of truth;
nothing is stored locally, so a session can stop at any point and resume.

Usage (from anywhere inside the repository):
  dev_state.py                 # issue of the current branch, else `status`
  dev_state.py status          # open issues, open PRs, current branch
  dev_state.py next            # open issues nobody is working on, best first
  dev_state.py issue <N>       # state + next phase for issue N
  dev_state.py pr <N>          # state + next phase for PR N
  add --json for machine-readable output

Only reads; never changes anything. Needs `git` and an authenticated `gh`.
Compatible with Python 3.9 (macOS system python3).
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from typing import Any, Dict, List, Optional

# Branch names: <type>/<issue>-<slug>, e.g. feat/12-keyboard-jog
BRANCH_RE = re.compile(r"^(?:remotes/origin/|origin/)?([a-z]+/(\d+)-[A-Za-z0-9._-]+)$")
SKIP_LABELS = {"wontfix", "duplicate", "invalid", "question"}
PRIORITY_LABELS = ["bug", "priority:high", "good first issue", "enhancement", "documentation"]
# Codex review comments carry a badge like ![P2 Badge](...)
SEVERITY_RE = re.compile(r"\bP([0-3])\b")

PHASES = {
    "1": "Issue の取得と要件整理",
    "2": "依存関係と実装対象の調査",
    "3": "ブランチ作成",
    "4": "コード変更とテスト",
    "5": "コミットと push",
    "6": "PR 作成",
    "7": "CI とレビュー結果の確認（待ち）",
    "8": "指摘・失敗への修正と再検証",
    "9": "マージ（ユーザーの明示的な承認が必要）",
    "10": "Issue クローズの確認と結果報告",
    "done": "完了",
    "attention": "要確認",
}


# --------------------------------------------------------------------- shell
def run(cmd: List[str], allow_fail: bool = False) -> str:
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        if allow_fail:
            return ""
        raise RuntimeError("%s failed: %s" % (" ".join(cmd), p.stderr.strip()))
    return p.stdout.strip()


def gh_json(args: List[str], allow_fail: bool = False) -> Any:
    out = run(["gh"] + args, allow_fail=allow_fail)
    return json.loads(out) if out else None


# --------------------------------------------------------------------- local git
def repo_info() -> Dict[str, Any]:
    info = gh_json(["repo", "view", "--json", "nameWithOwner,defaultBranchRef"])
    return {"repo": info["nameWithOwner"], "default_branch": info["defaultBranchRef"]["name"]}


def local_state(default_branch: str) -> Dict[str, Any]:
    run(["git", "fetch", "--quiet", "--prune", "origin"], allow_fail=True)
    branch = run(["git", "branch", "--show-current"], allow_fail=True)
    dirty = [l for l in run(["git", "status", "--porcelain"], allow_fail=True).splitlines() if l]
    return {"branch": branch, "dirty_files": dirty, "default_branch": default_branch}


def branch_commits(branch: str, default_branch: str) -> Dict[str, Any]:
    """Commits of `branch` not in the default branch, and push status."""
    has_local = bool(run(["git", "rev-parse", "--verify", "--quiet", "refs/heads/" + branch], allow_fail=True))
    has_remote = bool(run(["git", "rev-parse", "--verify", "--quiet", "refs/remotes/origin/" + branch], allow_fail=True))
    ref = branch if has_local else "origin/" + branch
    ahead_main = 0
    if has_local or has_remote:
        ahead_main = int(run(["git", "rev-list", "--count", "origin/%s..%s" % (default_branch, ref)], allow_fail=True) or 0)
    unpushed = 0
    if has_local and has_remote:
        unpushed = int(run(["git", "rev-list", "--count", "origin/%s..%s" % (branch, branch)], allow_fail=True) or 0)
    elif has_local:
        unpushed = ahead_main
    return {"local": has_local, "remote": has_remote, "ahead_of_default": ahead_main, "unpushed": unpushed}


def branches_for_issue(number: int) -> List[str]:
    out = run(["git", "branch", "-a", "--format=%(refname:short)"], allow_fail=True)
    found: List[str] = []
    for line in out.splitlines():
        m = BRANCH_RE.match(line.strip())
        if m and int(m.group(2)) == number and m.group(1) not in found:
            found.append(m.group(1))
    return found


def issue_from_branch(branch: str) -> Optional[int]:
    m = BRANCH_RE.match(branch or "")
    return int(m.group(2)) if m else None


# --------------------------------------------------------------------- GitHub
PR_FIELDS = ("number,title,state,isDraft,url,headRefName,baseRefName,mergeable,mergeStateStatus,"
             "reviewDecision,statusCheckRollup,closingIssuesReferences,headRefOid")


def issue_detail(number: int) -> Optional[Dict[str, Any]]:
    return gh_json(["issue", "view", str(number), "--json", "number,title,state,labels,url,body,assignees"], allow_fail=True)


def prs_for_issue(number: int, branches: List[str]) -> List[Dict[str, Any]]:
    prs = gh_json(["pr", "list", "--state", "all", "--limit", "100", "--json",
                   "number,state,headRefName,closingIssuesReferences"]) or []
    hits = []
    for p in prs:
        closes = [c.get("number") for c in p.get("closingIssuesReferences") or []]
        if number in closes or p["headRefName"] in branches or issue_from_branch(p["headRefName"]) == number:
            hits.append(p["number"])
    return [pr_detail(n) for n in hits]


def pr_detail(number: int) -> Dict[str, Any]:
    pr = gh_json(["pr", "view", str(number), "--json", PR_FIELDS])
    pr["checks"] = summarize_checks(pr.get("statusCheckRollup") or [])
    pr["threads"] = unresolved_threads(number)
    return pr


def summarize_checks(rollup: List[Dict[str, Any]]) -> Dict[str, Any]:
    failing, pending, passing = [], [], []
    for c in rollup:
        name = c.get("name") or c.get("context") or "?"
        if c.get("__typename") == "StatusContext":
            state = (c.get("state") or "").upper()
            if state in ("PENDING", "EXPECTED"):
                pending.append(name)
            elif state == "SUCCESS":
                passing.append(name)
            else:
                failing.append(name)
            continue
        if (c.get("status") or "").upper() != "COMPLETED":
            pending.append(name)
        elif (c.get("conclusion") or "").upper() in ("SUCCESS", "NEUTRAL", "SKIPPED"):
            passing.append(name)
        else:
            failing.append(name)
    overall = "none"
    if failing:
        overall = "failure"
    elif pending:
        overall = "pending"
    elif passing:
        overall = "success"
    return {"overall": overall, "failing": failing, "pending": pending, "passing": passing}


def unresolved_threads(number: int) -> Optional[List[Dict[str, Any]]]:
    """Unresolved review threads, or None when they could not be fetched (unknown != none)."""
    owner, name = run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]).split("/")
    query = """
query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){
 reviewThreads(first:100){nodes{id isResolved isOutdated path line
  comments(first:1){nodes{databaseId author{login} body url}}}}}}}"""
    data = gh_json(["api", "graphql", "-f", "query=" + query, "-f", "owner=" + owner,
                    "-f", "name=" + name, "-F", "number=%d" % number], allow_fail=True)
    out = []  # type: List[Dict[str, Any]]
    try:
        nodes = data["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]
    except (TypeError, KeyError):
        return None
    for t in nodes:
        if t["isResolved"]:
            continue
        c = (t["comments"]["nodes"] or [{}])[0]
        body = c.get("body") or ""
        sev = SEVERITY_RE.search(body)
        title = re.sub(r"<[^>]+>|!\[[^\]]*\]\([^)]*\)|\*\*", "", body).strip().splitlines()
        out.append({
            "severity": "P" + sev.group(1) if sev else "-",
            "path": t.get("path"), "line": t.get("line"), "outdated": t.get("isOutdated"),
            "author": (c.get("author") or {}).get("login"),
            "summary": (title[0] if title else "")[:120], "url": c.get("url"),
            "thread_id": t.get("id"), "comment_id": c.get("databaseId"),
        })
    out.sort(key=lambda x: x["severity"] if x["severity"] != "-" else "P9")
    return out


# --------------------------------------------------------------------- phase logic (pure)
def infer_phase(issue: Optional[Dict[str, Any]], branch: Optional[Dict[str, Any]],
                pr: Optional[Dict[str, Any]], local: Dict[str, Any]) -> Dict[str, str]:
    """Decide the next /dev phase. Inputs are plain dicts so this is unit-testable.

    branch: {"name", "local", "remote", "ahead_of_default", "unpushed"} or None
    pr:     pr_detail() dict or None
    local:  {"branch", "dirty_files"}
    """
    issue_open = issue is None or issue.get("state") == "OPEN"
    on_branch = branch is not None and local.get("branch") == branch.get("name")
    dirty = on_branch and bool(local.get("dirty_files"))

    if pr is not None and pr.get("state") == "MERGED":
        if issue_open and issue is not None:
            return {"phase": "10", "reason": "PR #%d はマージ済みだが Issue がまだ開いている" % pr["number"]}
        return {"phase": "done", "reason": "PR #%d はマージ済み%s" % (
            pr["number"], "、Issue も閉じている" if issue is not None else "")}
    if pr is not None and pr.get("state") == "CLOSED":
        return {"phase": "attention", "reason": "PR #%d はマージされずに閉じられている。再開するか新しい PR にするかユーザーに確認" % pr["number"]}
    if not issue_open and pr is None:
        return {"phase": "attention", "reason": "Issue は PR なしで閉じられている"}

    if pr is not None:  # open PR
        if dirty:
            return {"phase": "8", "reason": "PR のブランチに未コミットの変更がある（修正の途中）"}
        if branch is not None and branch.get("unpushed", 0) > 0:
            return {"phase": "5", "reason": "未 push のコミットが %d 件ある" % branch["unpushed"]}
        if pr.get("mergeable") == "CONFLICTING":
            return {"phase": "8", "reason": "main と競合している"}
        checks = pr.get("checks", {}).get("overall", "none")
        if checks == "failure":
            return {"phase": "8", "reason": "CI が失敗: " + ", ".join(pr["checks"]["failing"])}
        threads = pr.get("threads")
        if threads is None:
            return {"phase": "7", "reason": "レビュー指摘を取得できなかった（状態不明）。時間をおいて再実行する"}
        blocking = [t for t in threads if not t.get("outdated")]
        if pr.get("reviewDecision") == "CHANGES_REQUESTED" or blocking:
            return {"phase": "8", "reason": "未解決のレビュー指摘が %d 件" % len(blocking)}
        if checks == "pending":
            return {"phase": "7", "reason": "CI 実行中: " + ", ".join(pr["checks"]["pending"])}
        if pr.get("isDraft"):
            return {"phase": "7", "reason": "下書き PR。検証が済んだら Ready for review にする"}
        if checks == "none":
            return {"phase": "7", "reason": "CI の結果がまだない（CI 未設定か、起動待ち）"}
        return {"phase": "9", "reason": "CI 成功、未解決の指摘なし。マージにはユーザーの承認が必要"}

    if branch is None:
        return {"phase": "1", "reason": "ブランチも PR もない（未着手）"}
    if branch.get("ahead_of_default", 0) == 0 or dirty:
        return {"phase": "4", "reason": "ブランチはあるが実装が途中（コミットなし、または未コミットの変更あり）"}
    if branch.get("unpushed", 0) > 0 or not branch.get("remote"):
        return {"phase": "5", "reason": "コミットが push されていない"}
    return {"phase": "6", "reason": "push 済みだが PR がない"}


# --------------------------------------------------------------------- reports
def choose_pr(prs: List[Dict[str, Any]], prefer: Optional[int] = None) -> Optional[Dict[str, Any]]:
    """The PR to report: the one explicitly asked for, else open > merged > any."""
    if prefer is not None:
        for p in prs:
            if p["number"] == prefer:
                return p
    open_prs = [p for p in prs if p["state"] == "OPEN"]
    merged = [p for p in prs if p["state"] == "MERGED"]
    return (open_prs or merged or prs or [None])[0]


def report_issue(number: int, local: Dict[str, Any], default_branch: str,
                 prefer_pr: Optional[int] = None) -> Dict[str, Any]:
    issue = issue_detail(number)
    if issue is None:
        return {"error": "Issue #%d が見つからない" % number}
    names = branches_for_issue(number)
    prs = prs_for_issue(number, names)
    if prefer_pr is not None and prefer_pr not in [p["number"] for p in prs]:
        prs.append(pr_detail(prefer_pr))
    open_prs = [p for p in prs if p["state"] == "OPEN"]
    pr = choose_pr(prs, prefer_pr)
    bname = pr["headRefName"] if pr else (names[0] if names else None)
    branch = None
    if bname:
        branch = dict(name=bname, **branch_commits(bname, default_branch))
    result = infer_phase(issue, branch, pr, local)
    warnings = []
    if len(open_prs) > 1:
        warnings.append("この Issue に開いている PR が複数ある: " + ", ".join("#%d" % p["number"] for p in open_prs))
    if len(names) > 1:
        warnings.append("この Issue のブランチが複数ある: " + ", ".join(names))
    return {"issue": {k: issue[k] for k in ("number", "title", "state", "url")},
            "labels": [l["name"] for l in issue.get("labels", [])],
            "branch": branch, "pr": pr, "next": result, "warnings": warnings,
            "local": {"branch": local["branch"], "dirty_files": local["dirty_files"]}}


def report_pr_only(number: int, local: Dict[str, Any], default_branch: str) -> Dict[str, Any]:
    """PR without a linked issue (no `Closes #N`, branch name without a number)."""
    pr = pr_detail(number)
    branch = dict(name=pr["headRefName"], **branch_commits(pr["headRefName"], default_branch))
    return {"issue": None, "labels": [], "branch": branch, "pr": pr,
            "next": infer_phase(None, branch, pr, local),
            "warnings": ["PR #%d は Issue に結び付いていない（本文に Closes #N がない）" % number],
            "local": {"branch": local["branch"], "dirty_files": local["dirty_files"]}}


def report_status(local: Dict[str, Any]) -> Dict[str, Any]:
    issues = gh_json(["issue", "list", "--state", "open", "--limit", "50", "--json", "number,title,labels,updatedAt"]) or []
    prs = gh_json(["pr", "list", "--state", "open", "--limit", "50", "--json",
                   "number,title,headRefName,isDraft,reviewDecision,statusCheckRollup,mergeable,closingIssuesReferences"]) or []
    for p in prs:
        p["checks"] = summarize_checks(p.pop("statusCheckRollup") or [])["overall"]
        p["issues"] = [c["number"] for c in p.pop("closingIssuesReferences") or []] or (
            [issue_from_branch(p["headRefName"])] if issue_from_branch(p["headRefName"]) else [])
    return {"current_branch": local["branch"], "dirty_files": local["dirty_files"],
            "current_issue": issue_from_branch(local["branch"]),
            "open_issues": [{"number": i["number"], "title": i["title"],
                             "labels": [l["name"] for l in i["labels"]]} for i in issues],
            "open_prs": prs}


def report_next() -> Dict[str, Any]:
    issues = gh_json(["issue", "list", "--state", "open", "--limit", "100", "--json", "number,title,labels,createdAt"]) or []
    prs = gh_json(["pr", "list", "--state", "open", "--limit", "100", "--json", "headRefName,closingIssuesReferences"]) or []
    taken = set()
    for p in prs:
        taken.update(c["number"] for c in p.get("closingIssuesReferences") or [])
        n = issue_from_branch(p["headRefName"])
        if n:
            taken.add(n)
    cands = []
    for i in issues:
        labels = [l["name"] for l in i["labels"]]
        if i["number"] in taken or SKIP_LABELS.intersection(labels):
            continue
        rank = min([PRIORITY_LABELS.index(l) for l in labels if l in PRIORITY_LABELS] or [len(PRIORITY_LABELS)])
        cands.append((rank, i["createdAt"], {"number": i["number"], "title": i["title"], "labels": labels,
                                              "has_branch": bool(branches_for_issue(i["number"]))}))
    cands.sort(key=lambda c: (c[0], c[1]))
    return {"candidates": [c[2] for c in cands[:5]], "in_progress": sorted(taken)}


def print_text(mode: str, data: Dict[str, Any]) -> None:
    if "error" in data:
        print(data["error"])
        return
    if mode in ("issue", "pr"):
        i = data["issue"]
        if i:
            print("Issue #%d [%s] %s" % (i["number"], i["state"], i["title"]))
        else:
            print("Issue: なし")
        b = data["branch"]
        if b:
            print("  branch: %s (local=%s remote=%s, main より %d コミット先行, 未 push %d)" % (
                b["name"], b["local"], b["remote"], b["ahead_of_default"], b["unpushed"]))
        else:
            print("  branch: なし")
        p = data["pr"]
        if p:
            c = p["checks"]
            print("  PR #%d [%s%s] %s" % (p["number"], p["state"], " draft" if p.get("isDraft") else "", p["url"]))
            print("    CI: %s %s | review: %s | mergeable: %s" % (
                c["overall"], ("failing=" + ",".join(c["failing"])) if c["failing"] else "",
                p.get("reviewDecision") or "-", p.get("mergeable")))
            if p["threads"] is None:
                print("    ⚠ レビュー指摘を取得できなかった（状態不明）")
            for t in p["threads"] or []:
                print("    未解決 %s %s:%s %s%s" % (t["severity"], t["path"], t["line"], t["summary"],
                                              " (outdated)" if t["outdated"] else ""))
        else:
            print("  PR: なし")
        if data["local"]["dirty_files"]:
            print("  未コミット (%s): %d ファイル" % (data["local"]["branch"], len(data["local"]["dirty_files"])))
        for w in data["warnings"]:
            print("  ⚠ " + w)
        n = data["next"]
        print("NEXT phase %s: %s — %s" % (n["phase"], PHASES[n["phase"]], n["reason"]))
    elif mode == "status":
        print("現在のブランチ: %s%s" % (data["current_branch"],
              " (Issue #%d)" % data["current_issue"] if data["current_issue"] else ""))
        if data["dirty_files"]:
            print("  未コミット: %d ファイル" % len(data["dirty_files"]))
        print("開いている PR: %d" % len(data["open_prs"]))
        for p in data["open_prs"]:
            print("  #%d %s [CI %s, review %s, %s%s] Issue %s" % (
                p["number"], p["title"], p["checks"], p.get("reviewDecision") or "-", p.get("mergeable"),
                ", draft" if p["isDraft"] else "", ",".join("#%d" % n for n in p["issues"]) or "-"))
        print("開いている Issue: %d" % len(data["open_issues"]))
        for i in data["open_issues"]:
            print("  #%d %s %s" % (i["number"], i["title"], ("[" + ",".join(i["labels"]) + "]") if i["labels"] else ""))
    elif mode == "next":
        if not data["candidates"]:
            print("着手できる Issue はない（作業中: %s）" % (", ".join("#%d" % n for n in data["in_progress"]) or "なし"))
        for k, c in enumerate(data["candidates"]):
            print("%d. #%d %s %s%s" % (k + 1, c["number"], c["title"],
                                       ("[" + ",".join(c["labels"]) + "]") if c["labels"] else "",
                                       " (ブランチあり)" if c["has_branch"] else ""))


def main(argv: List[str]) -> int:
    as_json = "--json" in argv
    args = [a for a in argv if a != "--json"]
    info = repo_info()
    local = local_state(info["default_branch"])
    mode = args[0] if args else None
    if mode is None:
        n = issue_from_branch(local["branch"])
        mode, args = ("issue", ["issue", str(n)]) if n else ("status", ["status"])
    if mode == "status":
        data = report_status(local)
    elif mode == "next":
        data = report_next()
    elif mode == "issue" and len(args) > 1:
        data = report_issue(int(args[1].lstrip("#")), local, info["default_branch"])
    elif mode == "pr" and len(args) > 1:
        pr = gh_json(["pr", "view", args[1].lstrip("#"), "--json", "number,headRefName,closingIssuesReferences"])
        closes = [c["number"] for c in pr.get("closingIssuesReferences") or []]
        n = closes[0] if closes else issue_from_branch(pr["headRefName"])
        if n is None:
            data = report_pr_only(pr["number"], local, info["default_branch"])
        else:
            data = report_issue(n, local, info["default_branch"], prefer_pr=pr["number"])
    else:
        print(__doc__)
        return 2
    if as_json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print_text(mode, data)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
