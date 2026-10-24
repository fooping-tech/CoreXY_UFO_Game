#!/usr/bin/env python3
"""Summarise gitleaks / trivy JSON reports WITHOUT secret values.

  report.py gitleaks <report.json>
  report.py trivy <report.json>
  report.py check-exceptions <.trivyignore.yaml>
  report.py selftest-exceptions

Only file, rule, line, commit and what to do are printed. Match/Secret/Code
fields are never read out, so a value cannot leak into CI logs or PR comments.
Exit 1 when there are findings (or invalid exceptions).
"""

from __future__ import annotations

import datetime
import json
import re
import sys

ADVICE_SECRET = ("対処: 値をコードから取り除き、環境変数か .gitignore 済みのファイル（.env）に移す。"
                 "一度でもコミット・push した値は漏えいしたものとして発行元で無効化（ローテーション）し、"
                 "履歴からの削除はユーザーと相談する（force push を伴うため）。")


def gitleaks(path: str) -> int:
    try:
        findings = json.load(open(path))
    except (OSError, ValueError):
        findings = []
    for f in findings:
        commit = (f.get("Commit") or "")[:8] or "(未コミット)"
        print("SECRET  rule=%s  file=%s  line=%s  commit=%s" % (f.get("RuleID"), f.get("File"), f.get("StartLine"), commit))
    if findings:
        print("gitleaks: %d 件の秘密情報らしき値を検出（値は表示しない）。%s" % (len(findings), ADVICE_SECRET))
        return 1
    print("gitleaks: 検出 0 件")
    return 0


def trivy(path: str) -> int:
    try:
        report = json.load(open(path))
    except (OSError, ValueError):
        print("trivy: レポートを読めない（%s）" % path)
        return 1
    n_secret = n_vuln = n_conf = 0
    for res in report.get("Results") or []:
        target = res.get("Target")
        for s in res.get("Secrets") or []:
            n_secret += 1
            print("SECRET  rule=%s  severity=%s  file=%s  line=%s" % (s.get("RuleID"), s.get("Severity"), target, s.get("StartLine")))
        for v in res.get("Vulnerabilities") or []:
            n_vuln += 1
            print("VULN    %s  %s %s  %s  fixed=%s  file=%s" % (v.get("Severity"), v.get("PkgName"), v.get("InstalledVersion"),
                                                          v.get("VulnerabilityID"), v.get("FixedVersion") or "-", target))
        for m in res.get("Misconfigurations") or []:
            if m.get("Status") != "FAIL":
                continue
            n_conf += 1
            print("CONFIG  %s  %s  %s  file=%s" % (m.get("Severity"), m.get("ID"), m.get("Title"), target))
    if n_secret:
        print(ADVICE_SECRET)
    if n_vuln:
        print("対処（脆弱性）: fixed のバージョンへ更新する（backend: uv lock --upgrade-package <pkg>）。"
              "すぐ更新できない理由があれば .trivyignore.yaml に理由と期限付きで記録し、PR で合意を取る。")
    if n_conf:
        print("対処（設定不備）: 指摘の ID で修正方法を確認して直す。")
    print("trivy: secret %d / vuln %d / misconfig %d" % (n_secret, n_vuln, n_conf))
    return 1 if (n_secret or n_vuln or n_conf) else 0


SECTIONS = ("vulnerabilities", "misconfigurations", "secrets", "licenses")


def parse_exceptions(text: str):
    """Parse .trivyignore.yaml in the strict block style documented in the file.

    Returns (entries, errors). Each entry is a dict of its keys, whatever their order.
    Anything outside that style (flow mappings like `[{id: ...}]`, unknown nesting) is
    an error rather than silently skipped, so an exception can never slip past the check.
    """
    entries, errors = [], []
    section, cur, last_key = None, None, None
    for n, raw in enumerate(text.splitlines(), 1):
        line = re.sub(r"\s+#.*$", "", raw).rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = re.match(r"^([A-Za-z_]+):\s*(.*)$", line)
        if m:  # top-level section
            section, cur, last_key = m.group(1), None, None
            if section not in SECTIONS:
                errors.append("%d行目: 未知のセクション %s" % (n, section))
            elif m.group(2) not in ("", "[]"):
                errors.append("%d行目: %s はブロック形式（- id: ...）で書く（インライン形式は不可）" % (n, section))
            continue
        m = re.match(r"^\s+-\s+([A-Za-z_]+):\s*(.*)$", line)
        if m and section:
            cur = {"_section": section, "_line": n, m.group(1): m.group(2)}
            entries.append(cur)
            last_key = m.group(1)
            continue
        m = re.match(r"^\s+([A-Za-z_]+):\s*(.*)$", line)
        if m and cur is not None:
            cur[m.group(1)] = m.group(2)
            last_key = m.group(1)
            continue
        if re.match(r"^\s+-\s+[^:]*$", line) and cur is not None and last_key:
            cur[last_key] = (cur.get(last_key) or "") + " " + line.strip()[1:].strip()  # block list value
            continue
        errors.append("%d行目: 解釈できない（ブロック形式で書く）: %s" % (n, line.strip()[:60]))
    return entries, errors


def validate_exceptions(text: str, today: datetime.date):
    entries, problems = parse_exceptions(text)
    for e in entries:
        ident = (e.get("id") or "").strip("\"' ") or "(%d行目)" % e["_line"]
        if e["_section"] == "secrets":
            problems.append("%s: 秘密情報は例外にしない（キーを無効化して取り除く）" % ident)
            continue
        if not e.get("id"):
            problems.append("%s: id がない" % ident)
        if not (e.get("statement") or "").strip("\"' "):
            problems.append("%s: statement（理由）がない" % ident)
        exp = re.match(r"^[\"']?(\d{4}-\d{2}-\d{2})", (e.get("expired_at") or "").strip())
        if not exp:
            problems.append("%s: expired_at（期限 YYYY-MM-DD）がない" % ident)
        elif datetime.date.fromisoformat(exp.group(1)) > today + datetime.timedelta(days=90):
            problems.append("%s: 期限が 90 日より先（%s）" % (ident, exp.group(1)))
    return entries, problems


def check_exceptions(path: str) -> int:
    """Every .trivyignore.yaml entry needs id, statement and expired_at (<= 90 days ahead)."""
    try:
        text = open(path).read()
    except OSError:
        return 0
    entries, problems = validate_exceptions(text, datetime.date.today())
    for b in problems:
        print("EXCEPTION  " + b)
    print("trivy exceptions: %d entries, %d problem(s)" % (len(entries), len(problems)))
    return 1 if problems else 0


def selftest_exceptions() -> int:
    today = datetime.date(2026, 10, 25)
    cases = [
        ("vulnerabilities: []\nmisconfigurations: []\n", 0),
        ("vulnerabilities:\n  - id: CVE-1\n    statement: \"ok\"\n    expired_at: 2026-12-01\n", 0),
        ("vulnerabilities:\n  - paths:\n      - backend/uv.lock\n    id: CVE-1\n    statement: x\n    expired_at: 2026-12-01\n", 0),
        ("vulnerabilities:\n  - paths: [a]\n    id: CVE-1\n", 2),              # key order, missing reason+expiry
        ("vulnerabilities: [{id: CVE-2099-0001}]\n", 1),                         # flow style rejected
        ("vulnerabilities:\n  - id: CVE-1\n    statement: x\n    expired_at: 2027-12-01\n", 1),  # too far
        ("secrets:\n  - id: github-pat\n    statement: x\n    expired_at: 2026-11-01\n", 1),
        ("vulnerabilities:\n  - {id: CVE-1, statement: x}\n", 1),
    ]
    fails = 0
    for text, want in cases:
        got = len(validate_exceptions(text, today)[1])
        if (got == 0) != (want == 0) or (want and got < want):
            fails += 1
            print("FAIL exceptions case %r: %d problem(s), expected %d" % (text[:40], got, want))
    print("exceptions self-test: %s (%d cases)" % ("OK" if not fails else "%d failure(s)" % fails, len(cases)))
    return 1 if fails else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["selftest-exceptions"]:
        sys.exit(selftest_exceptions())
    if len(sys.argv) != 3 or sys.argv[1] not in ("gitleaks", "trivy", "check-exceptions"):
        print(__doc__)
        sys.exit(2)
    sys.exit({"gitleaks": gitleaks, "trivy": trivy, "check-exceptions": check_exceptions}[sys.argv[1]](sys.argv[2]))
