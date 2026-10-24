#!/usr/bin/env python3
"""Summarise gitleaks / trivy JSON reports WITHOUT secret values.

  report.py gitleaks <report.json>
  report.py trivy <report.json>
  report.py check-exceptions <.trivyignore.yaml>

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


def check_exceptions(path: str) -> int:
    """Every .trivyignore.yaml entry needs statement + expired_at (<= 90 days ahead)."""
    try:
        text = open(path).read()
    except OSError:
        return 0
    entries = re.split(r"\n\s*-\s+id:", "\n" + "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#")))[1:]
    today = datetime.date.today()
    bad = []
    for e in entries:
        ident = e.strip().splitlines()[0].strip()
        st = re.search(r"\bstatement:\s*(\S.*)", e)
        exp = re.search(r"\bexpired_at:\s*(\d{4}-\d{2}-\d{2})", e)
        if not st:
            bad.append("%s: statement（理由）がない" % ident)
        if not exp:
            bad.append("%s: expired_at（期限）がない" % ident)
        elif datetime.date.fromisoformat(exp.group(1)) > today + datetime.timedelta(days=90):
            bad.append("%s: 期限が 90 日より先（%s）" % (ident, exp.group(1)))
    for b in bad:
        print("EXCEPTION  " + b)
    print("trivy exceptions: %d entries, %d problem(s)" % (len(entries), len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("gitleaks", "trivy", "check-exceptions"):
        print(__doc__)
        sys.exit(2)
    sys.exit({"gitleaks": gitleaks, "trivy": trivy, "check-exceptions": check_exceptions}[sys.argv[1]](sys.argv[2]))
