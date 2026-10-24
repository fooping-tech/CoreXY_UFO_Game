#!/usr/bin/env python3
"""Claude Code PreToolUse hook (Bash): stop risky git operations before they run.

Blocks (exit 2, reason on stderr — Claude sees it and must ask the user):
  - git push to the default branch (main/master), --all/--mirror
  - force push (--force, -f, --force-with-lease, +refspec) and remote branch deletion
  - destructive local commands: reset --hard, clean -f, branch -D, checkout -- / checkout .,
    restore (worktree), stash drop/clear, filter-branch
  - git commit when the staged changes contain secrets (tokens, private keys, .env files)
  - gh repo delete

The user can still run any of these themselves in a terminal; this only guards Claude.

Also usable directly:
  guard_git.py --scan-tracked   # scan every tracked file for secrets (used by tools/verify.sh / CI)
  guard_git.py --self-test      # run the built-in tests

Python 3.9 compatible (macOS system python3).
"""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
from typing import List, Optional, Tuple

PROTECTED_BRANCHES = {"main", "master"}

SECRET_PATTERNS = [
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})\b")),
    ("AWS access key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("private key", re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY-----")),
    ("Slack token", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}\b")),
    ("Anthropic API key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}\b")),
    ("OpenAI API key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9]{32,}\b")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("hard-coded credential", re.compile(
        r"(?i)\b(?:api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|password|passwd)\b"
        r"\s*[:=]\s*['\"][^'\"\s]{12,}['\"]")),
]
SECRET_FILES = re.compile(r"(?:^|/)(?:\.env(?:\.[\w.-]+)?|id_(?:rsa|dsa|ecdsa|ed25519)|[^/]+\.pem|[^/]+\.p12|"
                          r"[^/]+\.pfx|[^/]+\.key|credentials\.json|service[-_]account[^/]*\.json)$")
SECRET_FILE_ALLOW = re.compile(r"(?:^|/)\.env\.(?:example|sample|template)$")


# --------------------------------------------------------------------- helpers
def git(args: List[str], cwd: str) -> str:
    p = subprocess.run(["git"] + args, cwd=cwd, capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else ""


def split_segments(command: str) -> List[List[str]]:
    """Split a shell command line into simple commands (on ; && || | and newlines)."""
    parts = re.split(r"&&|\|\||[;\n|]", command)
    out = []
    for part in parts:
        part = part.strip()
        if not part:
            continue
        try:
            out.append(shlex.split(part))
        except ValueError:
            out.append(part.split())
    return out


def git_args(tokens: List[str]) -> Optional[Tuple[List[str], Optional[str]]]:
    """If tokens invoke git, return (subcommand args, -C dir)."""
    i = 0
    while i < len(tokens) and re.match(r"^\w+=", tokens[i]):  # env assignments
        i += 1
    if i >= len(tokens) or os.path.basename(tokens[i]) != "git":
        return None
    i += 1
    cdir = None
    while i < len(tokens) and tokens[i].startswith("-"):
        if tokens[i] == "-C" and i + 1 < len(tokens):
            cdir = tokens[i + 1]
            i += 2
            continue
        if tokens[i] in ("-c", "--git-dir", "--work-tree") and i + 1 < len(tokens):
            i += 2
            continue
        i += 1
    return tokens[i:], cdir


# --------------------------------------------------------------------- rules
def check_push(args: List[str], cwd: str) -> Optional[str]:
    opts = [a for a in args if a.startswith("-")]
    pos = [a for a in args if not a.startswith("-")]
    if any(o in ("--force", "-f", "--force-if-includes") or o.startswith("--force-with-lease")
           or (re.match(r"^-[a-zA-Z]+$", o) and "f" in o) for o in opts):
        return "force push は禁止（履歴を書き換える）。必要ならユーザーに確認し、ユーザー自身に実行してもらう"
    if any(o in ("--delete", "-d", "--mirror", "--all", "--prune") for o in opts):
        return "リモートのブランチ削除・--all/--mirror/--prune の push は禁止"
    refspecs = pos[1:]  # pos[0] is the remote
    for r in refspecs:
        if r.startswith("+"):
            return "force push（+refspec）は禁止"
        if r.startswith(":"):
            return "リモートのブランチ削除（:branch）は禁止"
        dst = r.split(":")[-1].replace("refs/heads/", "")
        if dst in PROTECTED_BRANCHES:
            return "%s への直接 push は禁止。ブランチを作って PR にする" % dst
        current = git(["branch", "--show-current"], cwd).strip()
        if dst == "HEAD" and current in PROTECTED_BRANCHES:
            return "%s への直接 push は禁止（HEAD が %s）" % (current, current)
    if not refspecs:
        current = git(["branch", "--show-current"], cwd).strip()
        if current in PROTECTED_BRANCHES:
            return "%s ブランチ上での push は禁止。作業用ブランチを作って PR にする" % current
    return None


def check_destructive(sub: str, args: List[str]) -> Optional[str]:
    if sub == "reset" and "--hard" in args:
        return "git reset --hard は禁止（未コミットの変更が消える）"
    if sub == "clean" and any(re.match(r"^-[a-zA-Z]*f", a) or a == "--force" for a in args):
        return "git clean -f は禁止（未追跡ファイルが消える）"
    if sub == "branch" and any(a in ("-D",) or (re.match(r"^-[a-zA-Z]+$", a) and "D" in a)
                               or a == "--delete" and "--force" in args for a in args):
        return "git branch -D は禁止（マージされていないブランチが消える）"
    if sub == "checkout" and ("--" in args or "." in args):
        return "git checkout -- / checkout . は禁止（作業中の変更が消える）"
    if sub == "restore" and "--staged" not in args:
        return "git restore（作業ツリーの復元）は禁止（作業中の変更が消える）"
    if sub == "stash" and args[:1] and args[0] in ("drop", "clear"):
        return "git stash drop/clear は禁止"
    if sub in ("filter-branch", "filter-repo"):
        return "履歴の書き換えは禁止"
    return None


def scan_text(text: str) -> List[str]:
    found = []
    for name, rx in SECRET_PATTERNS:
        if rx.search(text):
            found.append(name)
    return found


# git subcommands that can change what the next commit contains
INDEX_CHANGING = {"add", "rm", "mv", "apply", "stash", "restore", "reset", "checkout", "switch",
                  "cherry-pick", "merge", "pull", "am", "revert"}


def check_commit(args: List[str], cwd: str, index_changed: bool = False,
                 add_paths: Optional[List[str]] = None) -> Optional[str]:
    """Scan what the commit will contain.

    The hook runs before the whole command line, so `git add x && git commit` would
    otherwise be checked against the index *before* `git add`. When an earlier part of
    the same command can change the index (index_changed), scan every tracked change
    against HEAD plus the untracked files that `git add` may pick up (add_paths;
    [] = all untracked files). That can over-block, which is the safe side.
    """
    all_flag = any(a in ("-a", "--all") or (re.match(r"^-[a-zA-Z]+$", a) and "a" in a) for a in args)
    diff_args = ["diff", "HEAD"] if (all_flag or index_changed) else ["diff", "--cached"]
    names = git(diff_args + ["--name-only", "--diff-filter=AM"], cwd).split()
    added = "\n".join(l[1:] for l in git(diff_args + ["-U0"], cwd).splitlines()
                      if l.startswith("+") and not l.startswith("+++"))
    if index_changed and add_paths is not None:
        untracked = git(["ls-files", "--others", "--exclude-standard", "--"] + add_paths, cwd).splitlines()
        names += untracked
        for f in untracked:
            try:
                path = os.path.join(cwd, f)
                if os.path.getsize(path) <= 2_000_000:
                    with open(path, "r", encoding="utf-8", errors="ignore") as fh:
                        added += "\n" + fh.read()
            except OSError:
                pass
    bad_files = [n for n in names if SECRET_FILES.search(n) and not SECRET_FILE_ALLOW.search(n)]
    if bad_files:
        return "秘密情報を含みうるファイルをコミットしようとしている: %s（.gitignore に追加する）" % ", ".join(bad_files)
    hits = scan_text(added)
    if hits:
        return "コミットする差分に秘密情報らしき値がある: %s。値を取り除き、環境変数や .gitignore 済みのファイルに移す" % ", ".join(hits)
    return None


def evaluate(command: str, cwd: str) -> Optional[str]:
    index_changed = False
    add_paths = None  # type: Optional[List[str]]
    for tokens in split_segments(command):
        if tokens[:3] == ["gh", "repo", "delete"]:
            return "gh repo delete は禁止"
        parsed = git_args(tokens)
        if parsed is None:
            continue
        args, cdir = parsed
        if not args:
            continue
        where = os.path.join(cwd, cdir) if cdir else cwd
        sub, rest = args[0], args[1:]
        reason = None
        if sub == "push":
            reason = check_push(rest, where)
        elif sub == "commit":
            reason = check_commit(rest, where, index_changed, add_paths)
        else:
            reason = check_destructive(sub, rest)
        if reason:
            return reason
        if sub in INDEX_CHANGING:
            index_changed = True
            if sub == "add":
                paths = [a for a in rest if not a.startswith("-")]
                everything = not paths or any(a in ("-A", "--all", ".") for a in rest + paths)
                add_paths = [] if everything else (add_paths or []) + paths
    return None


# --------------------------------------------------------------------- entry points
def scan_tracked(root: str) -> int:
    files = git(["ls-files"], root).splitlines()
    problems = []
    for f in files:
        if SECRET_FILES.search(f) and not SECRET_FILE_ALLOW.search(f):
            problems.append("%s: 秘密情報を含みうるファイル名" % f)
            continue
        path = os.path.join(root, f)
        try:
            if os.path.getsize(path) > 2_000_000:
                continue
            with open(path, "r", encoding="utf-8", errors="ignore") as fh:
                hits = scan_text(fh.read())
        except OSError:
            continue
        if hits:
            problems.append("%s: %s" % (f, ", ".join(hits)))
    for p in problems:
        print("SECRET? " + p)
    print("secret scan: %d tracked files, %d problem(s)" % (len(files), len(problems)))
    return 1 if problems else 0


def self_test() -> int:
    tok = "gh" + "p_" + "a" * 36  # built at runtime so this file never contains a real-looking token
    cases = [
        ("git push origin main", True), ("git push origin HEAD:main", True), ("git push -f", True),
        ("git push --force-with-lease origin feat/1-x", True), ("git push origin +feat/1-x", True),
        ("git push origin :feat/1-x", True), ("git push --delete origin feat/1-x", True),
        ("git push -u origin feat/1-x", False), ("git status && git push origin feat/2-y", False),
        ("cd x && git reset --hard HEAD~1", True), ("git reset --soft HEAD~1", False),
        ("git clean -fd", True), ("git branch -D feat/1-x", True), ("git branch -d feat/1-x", False),
        ("git checkout -- game/x.gd", True), ("git checkout -b feat/3-z", False),
        ("git restore game/x.gd", True), ("git restore --staged game/x.gd", False),
        ("git stash drop", True), ("gh repo delete foo", True), ("gh pr merge 5 --merge", False),
        ("echo git push origin main", False),
    ]
    fails = 0
    for cmd, should_block in cases:
        # cwd outside any repo: "current branch" checks see no branch
        got = evaluate(cmd, "/") is not None
        if got != should_block:
            fails += 1
            print("FAIL %r: blocked=%s expected=%s" % (cmd, got, should_block))
    fake_password = "pass" + 'word = "' + "x" * 14 + '"'  # assembled so --scan-tracked does not flag this file
    for text, should_hit in [(tok, True), (fake_password, True), ("AKIA" + "ABCDEFGHIJKLMNOP", True),
                             ("-----BEGIN " + "PRIVATE KEY-----", True), ("token_count = 5", False)]:
        if bool(scan_text(text)) != should_hit:
            fails += 1
            print("FAIL scan %r" % text[:20])
    for name, bad in [(".env", True), ("config/.env.local", True), (".env.example", False), ("keys/id_ed25519", True),
                      ("game/project.godot", False)]:
        if (bool(SECRET_FILES.search(name)) and not SECRET_FILE_ALLOW.search(name)) != bad:
            fails += 1
            print("FAIL file %r" % name)
    fails += self_test_commits(tok)
    print("guard_git self-test: %s" % ("OK" if fails == 0 else "%d failure(s)" % fails))
    return 1 if fails else 0


def self_test_commits(tok: str) -> int:
    """Commit checks need a real repository: `git add <secret> && git commit` in one command."""
    import tempfile
    fails = 0
    with tempfile.TemporaryDirectory() as d:
        ident = ["-c", "user.name=t", "-c", "user.email=t@example.invalid"]
        subprocess.run(["git", "init", "-q", d], check=True)
        subprocess.run(["git"] + ident + ["-C", d, "commit", "-q", "--allow-empty", "-m", "init"], check=True)
        with open(os.path.join(d, "creds.txt"), "w") as fh:
            fh.write('t = "%s"\n' % tok)
        with open(os.path.join(d, "ok.py"), "w") as fh:
            fh.write("x = 1\n")
        for cmd, should_block in [("git add creds.txt && git commit -m t", True),
                                  ("git add -A && git commit -m t", True),
                                  ("git add . ; git commit -m t", True),
                                  ("git add ok.py && git commit -m ok", False),
                                  ("git commit -m nothing-staged", False)]:
            got = evaluate(cmd, d) is not None
            if got != should_block:
                fails += 1
                print("FAIL %r: blocked=%s expected=%s" % (cmd, got, should_block))
        subprocess.run(["git", "-C", d, "add", "creds.txt"], check=True)
        if evaluate("git commit -m staged", d) is None:
            fails += 1
            print("FAIL staged secret not blocked")
    return fails


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    if "--scan-tracked" in sys.argv:
        root = git(["rev-parse", "--show-toplevel"], os.getcwd()).strip() or os.getcwd()
        return scan_tracked(root)
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    if data.get("tool_name") != "Bash":
        return 0
    command = (data.get("tool_input") or {}).get("command") or ""
    if "git" not in command and "gh " not in command:
        return 0
    reason = evaluate(command, data.get("cwd") or os.getcwd())
    if reason:
        sys.stderr.write("[guard_git] ブロックしました: %s\n"
                         "（.claude/skills/dev/SKILL.md の運用ルール。どうしても必要ならユーザーに説明し、"
                         "ユーザー自身にターミナルで実行してもらう）\n" % reason)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
