#!/usr/bin/env python3
"""Claude Code PreToolUse hook (Bash): stop risky git / gh operations before they run.

Blocks (exit 2, reason on stderr — Claude sees it and must ask the user):
  - git push to main/master (explicit refspec, HEAD on main, or an upstream of main),
    --all/--mirror/--repo, force push (--force*, -f, +refspec), remote branch deletion
  - destructive local commands: reset --hard, clean -f, branch -D / -df, checkout -f / -- / .,
    switch -f / --discard-changes, restore of the worktree, stash drop/clear, update-ref -d,
    reflog expire/delete, worktree remove --force, gc --prune=now, filter-branch/filter-repo
  - git -c alias.* (an alias can hide any of the above)
  - git commit when what it will commit contains secrets (tokens, private keys, .env files)
  - gh repo delete, gh pr merge --admin, and gh api writes to refs / branch protection /
    rulesets / file contents (REST or GraphQL), which would bypass the PR flow
The command line is parsed like a shell would split it: heredoc bodies and quoted text are
not commands, but `sh -c "..."`, `eval`, `$(...)`, backticks, `( ... )` and prefixes such as
env/sudo/command/time/nohup are looked into.

This is a guard rail for Claude, not a security boundary: the user can run anything in a
terminal, and GitHub branch protection is what actually protects main.
If the hook itself fails on a command that mentions git/gh, it blocks (fails closed).

Also usable directly:
  guard_git.py --scan-tracked   # scan every tracked file for secrets (tools/verify.sh / CI)
  guard_git.py --self-test      # built-in tests

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
# keep in step with .gitignore (`!.env.example`)
SECRET_FILE_ALLOW = re.compile(r"(?:^|/)\.env\.example$")

WRAPPERS = {"env", "command", "builtin", "sudo", "doas", "time", "nohup", "nice", "exec", "xargs", "stdbuf", "timeout"}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
# git subcommands that can change what the next commit contains
INDEX_CHANGING = {"add", "rm", "mv", "apply", "stash", "restore", "reset", "checkout", "switch",
                  "cherry-pick", "merge", "pull", "am", "revert"}
GH_WRITE_PATHS = re.compile(r"(?:/git/refs|/git/commits|/branches/[^/]+/protection|/rulesets|/contents/|"
                            r"/merges\b|/pulls/\d+/merge\b|/git/trees)")
GH_GRAPHQL_MUTATIONS = re.compile(r"\b(?:updateRefs?|deleteRef|createRef|createCommitOnBranch|"
                                  r"\w*BranchProtectionRule|\w*Ruleset|mergeBranch)\b")


class Blocked(Exception):
    pass


# --------------------------------------------------------------------- helpers
def git(args: List[str], cwd: str) -> str:
    p = subprocess.run(["git"] + args, cwd=cwd, capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else ""


def strip_heredocs(command: str) -> str:
    """Drop heredoc bodies: they are data (commit messages, PR bodies), not commands."""
    out, pending = [], []  # pending: [(delimiter, strip_tabs)]
    for line in command.split("\n"):
        if pending:
            delim, dash = pending[0]
            if (line.lstrip("\t") if dash else line).strip() == delim:
                pending.pop(0)
            continue
        out.append(line)
        for m in re.finditer(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2", line):
            pending.append((m.group(3), m.group(1) == "-"))
    return "\n".join(out)


def substitutions(text: str) -> List[str]:
    """Bodies of $( ... ) and `...` anywhere in the line (they run even inside double quotes)."""
    found = re.findall(r"`([^`]*)`", text)
    i = 0
    while True:
        i = text.find("$(", i)
        if i < 0:
            break
        depth, j = 1, i + 2
        while j < len(text) and depth:
            depth += {"(": 1, ")": -1}.get(text[j], 0)
            j += 1
        found.append(text[i + 2:j - 1])
        i += 2
    return found


def split_commands(command: str) -> List[List[str]]:
    """Simple commands of a shell line: split on ; & | ( ) and unquoted newlines."""
    lex = shlex.shlex(command.replace("\n", " ; "), posix=True, punctuation_chars=";&|()")
    lex.whitespace_split = True
    lex.commenters = ""
    try:
        tokens = list(lex)
    except ValueError:  # unbalanced quotes: fall back to a rough split
        tokens = re.split(r"\s+", command)
    out, cur = [], []
    for t in tokens:
        if t and set(t) <= set(";&|()"):
            if cur:
                out.append(cur)
            cur = []
        else:
            cur.append(t)
    if cur:
        out.append(cur)
    return out


def unwrap(tokens: List[str]) -> List[str]:
    """Skip env assignments, `{`, `!` and wrapper commands (env/sudo/command/time/...)."""
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if t in ("{", "}", "!") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
            i += 1
        elif os.path.basename(t) in WRAPPERS:
            i += 1
            while i < len(tokens) and tokens[i].startswith("-"):
                i += 1
            if i < len(tokens) and os.path.basename(tokens[i - 1]) == "timeout" and re.match(r"^\d", tokens[i]):
                i += 1
        else:
            break
    return tokens[i:]


def git_args(tokens: List[str]) -> Optional[Tuple[List[str], Optional[str]]]:
    """If tokens invoke git, return (subcommand args, -C dir)."""
    if not tokens or os.path.basename(tokens[0]) != "git":
        return None
    i, cdir = 1, None
    while i < len(tokens) and tokens[i].startswith("-"):
        if tokens[i] == "-C" and i + 1 < len(tokens):
            cdir = tokens[i + 1]
            i += 2
        elif tokens[i] == "-c" and i + 1 < len(tokens):
            if tokens[i + 1].lower().startswith("alias."):
                raise Blocked("git -c alias.* は禁止（別名で危険な操作を隠せるため）")
            i += 2
        elif tokens[i] in ("--git-dir", "--work-tree", "--namespace") and i + 1 < len(tokens):
            i += 2
        else:
            i += 1
    return tokens[i:], cdir


def short_flags(args: List[str]) -> str:
    """All single-letter flags, e.g. ['-df', '-x'] -> 'dfx'."""
    return "".join(a[1:] for a in args if re.match(r"^-[a-zA-Z]+$", a))


# --------------------------------------------------------------------- git rules
def check_push(args: List[str], cwd: str) -> Optional[str]:
    opts = [a for a in args if a.startswith("-")]
    pos = [a for a in args if not a.startswith("-")]
    if any(o in ("--force", "--force-if-includes") or o.startswith("--force-with-lease") for o in opts) \
            or "f" in short_flags(opts):
        return "force push は禁止（履歴を書き換える）"
    if any(o in ("--delete", "--mirror", "--all", "--prune") or o.startswith("--repo") for o in opts) \
            or "d" in short_flags(opts):
        return "リモートのブランチ削除・--all/--mirror/--prune/--repo の push は禁止"
    refspecs = pos[1:]  # pos[0] is the remote
    current = git(["branch", "--show-current"], cwd).strip()
    for r in refspecs:
        if r.startswith("+"):
            return "force push（+refspec）は禁止"
        if r.startswith(":"):
            return "リモートのブランチ削除（:branch）は禁止"
        dst = re.sub(r"[~^].*$", "", r.split(":")[-1].replace("refs/heads/", "")).lower()
        if dst in PROTECTED_BRANCHES or (dst in ("HEAD", "@") and current in PROTECTED_BRANCHES):
            return "%s への直接 push は禁止。ブランチを作って PR にする" % (dst if dst in PROTECTED_BRANCHES else current)
    if not refspecs:
        if current in PROTECTED_BRANCHES:
            return "%s ブランチ上での push は禁止。作業用ブランチを作って PR にする" % current
        upstream = git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], cwd).strip()
        if upstream.split("/")[-1] in PROTECTED_BRANCHES:
            return "このブランチの上流が %s になっている。`git push -u origin <branch>` と明示する" % upstream
    return None


def check_destructive(sub: str, args: List[str]) -> Optional[str]:
    flags = short_flags(args)
    if sub == "reset" and ("--hard" in args or "--merge" in args or "--keep" in args):
        return "git reset --hard は禁止（未コミットの変更が消える）"
    if sub == "clean" and ("f" in flags or "--force" in args):
        return "git clean -f は禁止（未追跡ファイルが消える）"
    if sub == "branch" and ("D" in flags or (("d" in flags or "--delete" in args) and ("f" in flags or "--force" in args))):
        return "ブランチの強制削除（branch -D / -df）は禁止"
    if sub == "checkout" and ("--" in args or "." in args or "f" in flags or "--force" in args):
        return "git checkout -- / . / -f は禁止（作業中の変更が消える）"
    if sub == "switch" and ("f" in flags or "--force" in args or "--discard-changes" in args):
        return "git switch -f / --discard-changes は禁止（作業中の変更が消える）"
    if sub == "restore" and ("--staged" not in args and "S" not in flags or "--worktree" in args or "W" in flags):
        return "git restore（作業ツリーの復元）は禁止（作業中の変更が消える）"
    if sub == "stash" and args[:1] and args[0] in ("drop", "clear"):
        return "git stash drop/clear は禁止"
    if sub == "update-ref" and ("-d" in args or "--delete" in args):
        return "git update-ref -d は禁止"
    if sub == "reflog" and args[:1] and args[0] in ("expire", "delete"):
        return "git reflog expire/delete は禁止"
    if sub == "worktree" and args[:1] == ["remove"] and ("f" in flags or "--force" in args):
        return "git worktree remove --force は禁止"
    if sub == "gc" and any(a.startswith("--prune") for a in args):
        return "git gc --prune は禁止"
    if sub in ("filter-branch", "filter-repo"):
        return "履歴の書き換えは禁止"
    return None


def scan_text(text: str) -> List[str]:
    return [name for name, rx in SECRET_PATTERNS if rx.search(text)]


def check_commit(args: List[str], cwd: str, index_changed: bool = False,
                 add_paths: Optional[List[str]] = None) -> Optional[str]:
    """Scan what the commit will contain.

    - plain commit: the staged diff
    - commit -a / with paths / --include / --only: the tracked changes vs HEAD (limited to the paths)
    - an earlier part of the same command changed the index (`git add x && git commit`): the hook
      runs before the whole line, so scan tracked changes vs HEAD plus the untracked files that
      `git add` may pick up (add_paths; [] = all). This can over-block, which is the safe side.
    """
    value_opts = {"-m", "--message", "-F", "--file", "-C", "-c", "--author", "--date", "-t", "--template",
                  "--fixup", "--squash", "--cleanup", "--trailer", "-S", "--gpg-sign"}
    paths, skip = [], False
    for k, a in enumerate(args):
        if skip:
            skip = False
            continue
        if a == "--":
            paths += args[k + 1:]
            break
        if a in value_opts or re.match(r"^-[a-zA-Z]*[mFCctS]$", a):  # -m msg, -am msg, ...
            skip = True
        elif not a.startswith("-"):
            paths.append(a)
    flags = short_flags([a for a in args if a not in value_opts])
    wide = "a" in flags or "--all" in args or index_changed or bool(paths) \
        or any(a in ("-i", "--include", "-o", "--only") for a in args)
    diff_args = ["diff", "HEAD"] if wide else ["diff", "--cached"]
    tail = ["--"] + paths if paths else []
    names = git(diff_args + ["--name-only", "--diff-filter=AMR"] + tail, cwd).split()
    added = "\n".join(l[1:] for l in git(diff_args + ["-U0", "--diff-filter=AMR"] + tail, cwd).splitlines()
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


# --------------------------------------------------------------------- gh rules
def check_gh(args: List[str]) -> Optional[str]:
    if args[:2] == ["repo", "delete"]:
        return "gh repo delete は禁止"
    if args[:2] == ["pr", "merge"] and "--admin" in args:
        return "gh pr merge --admin は禁止（必須チェックやブランチ保護を迂回する）"
    if args[:1] == ["api"]:
        method = "GET"
        for k, a in enumerate(args):
            if a in ("-X", "--method") and k + 1 < len(args):
                method = args[k + 1].upper()
            elif a.startswith("--method="):
                method = a.split("=", 1)[1].upper()
        has_fields = any(a in ("-f", "-F", "--field", "--raw-field", "--input") for a in args)
        if method == "GET" and has_fields:
            method = "POST"  # gh api sends POST when fields are given
        joined = " ".join(args)
        if "graphql" in args[1:2] or args[1:2] == ["graphql"]:
            if GH_GRAPHQL_MUTATIONS.search(joined):
                return "gh api graphql で参照・保護設定を書き換えるミューテーションは禁止（PR の流れを迂回する）"
        elif method != "GET" and GH_WRITE_PATHS.search(joined):
            return "gh api での参照・ブランチ保護・ルールセット・ファイル内容の書き換えは禁止（PR の流れを迂回する）"
    return None


# --------------------------------------------------------------------- evaluation
def evaluate(command: str, cwd: str, depth: int = 0) -> Optional[str]:
    if depth > 4:
        return None
    body = strip_heredocs(command)
    for sub_cmd in substitutions(body):
        reason = evaluate(sub_cmd, cwd, depth + 1)
        if reason:
            return reason
    index_changed = False
    add_paths = None  # type: Optional[List[str]]
    for raw in split_commands(body):
        tokens = unwrap(raw)
        if not tokens:
            continue
        head = os.path.basename(tokens[0])
        if head in SHELLS and "-c" in tokens:
            k = tokens.index("-c")
            if k + 1 < len(tokens):
                reason = evaluate(tokens[k + 1], cwd, depth + 1)
                if reason:
                    return reason
            continue
        if head == "eval":
            reason = evaluate(" ".join(tokens[1:]), cwd, depth + 1)
            if reason:
                return reason
            continue
        if head == "rm" and any(re.search(r"(?:^|/)\.git/?$", t) for t in tokens[1:]):
            return "リポジトリの .git の削除は禁止"
        if head == "gh":
            reason = check_gh(tokens[1:])
            if reason:
                return reason
            continue
        try:
            parsed = git_args(tokens)
        except Blocked as e:
            return str(e)
        if parsed is None or not parsed[0]:
            continue
        args, cdir = parsed
        where = os.path.join(cwd, cdir) if cdir else cwd
        sub, rest = args[0], args[1:]
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


SELF_TEST_COMMANDS = [
    # (command, should_block)
    ("git push origin main", True), ("git push origin HEAD:main", True), ("git push -f", True),
    ("git push --force-with-lease origin feat/1-x", True), ("git push origin +feat/1-x", True),
    ("git push origin :feat/1-x", True), ("git push --delete origin feat/1-x", True),
    ("git push --repo=origin main", True), ("git push -u origin feat/1-x", False),
    ("git push origin feat/x:MAIN", True), ("git push origin feat/x:main~0", True), ("rm -rf .git", True),
    ("rm -rf build/", False),
    ("git status && git push origin feat/2-y", False),
    # wrappers, subshells, substitutions
    ('sh -c "git push origin main"', True), ("bash -c 'git push origin main'", True),
    ('eval "git push origin main"', True), ("(git push origin main)", True), ("{ git push origin main; }", True),
    ("echo $(git push origin main)", True), ('echo "x `git push origin main` y"', True),
    ("env FOO=1 git push origin main", True), ("command git push origin main", True),
    ("sudo git push origin main", True), ("time git push origin main", True), ("nohup git push origin main &", True),
    ("git -c alias.p=push p origin main", True), ("git -C . push origin main", True),
    ("git status\ngit push origin main", True),
    # gh
    ("gh api repos/o/r/git/refs/heads/main -X PATCH -F sha=abc -F force=true", True),
    ("gh api -X DELETE repos/o/r/git/refs/heads/x", True),
    ("gh api repos/o/r/contents/README.md -X PUT -f message=m -f content=Zg== -f branch=main", True),
    ("gh api graphql -f query='mutation{updateRef(input:{}){clientMutationId}}'", True),
    ("gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}'", False),
    ("gh api repos/o/r/pulls/5/comments/1/replies -f body=ok", False), ("gh api repos/o/r/git/refs/heads/main", False),
    ("gh pr merge 5 --merge", False), ("gh pr merge 5 --merge --admin", True), ("gh repo delete foo", True),
    # destructive
    ("cd x && git reset --hard HEAD~1", True), ("git reset --soft HEAD~1", False),
    ("git clean -fd", True), ("git branch -D feat/1-x", True), ("git branch -df feat/1-x", True),
    ("git branch -d feat/1-x", False), ("git checkout -- game/x.gd", True), ("git checkout -f main", True),
    ("git checkout -b feat/3-z", False), ("git switch -f main", True), ("git switch --discard-changes main", True),
    ("git switch -c feat/3-z", False), ("git restore game/x.gd", True), ("git restore --staged game/x.gd", False),
    ("git restore --staged --worktree game/x.gd", True), ("git stash drop", True), ("git stash", False),
    ("git update-ref -d refs/heads/x", True), ("git reflog expire --all", True),
    ("git worktree remove --force ../w", True), ("git gc --prune=now", True),
    # data, not commands (no false positives)
    ("echo git push origin main", False),
    ("git commit -m \"fix: a; git reset --hard was used before\"", False),
    ("cat > notes.md <<'EOF'\ngit push origin main\ngit reset --hard\nEOF", False),
    ("git commit -F - <<'EOF'\nchore: x\n\ngit push origin main is now blocked\nEOF", False),
    ("gh pr create --title t --body \"$(cat <<'EOF'\n## x\ngit push --force; git reset --hard\nEOF\n)\"", False),
]


def self_test() -> int:
    tok = "gh" + "p_" + "a" * 36  # built at runtime so this file never contains a real-looking token
    fails = 0
    for cmd, should_block in SELF_TEST_COMMANDS:
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
                      (".env.sample", True), ("game/project.godot", False)]:
        if (bool(SECRET_FILES.search(name)) and not SECRET_FILE_ALLOW.search(name)) != bad:
            fails += 1
            print("FAIL file %r" % name)
    fails += self_test_commits(tok)
    print("guard_git self-test: %s (%d command cases)" % ("OK" if fails == 0 else "%d failure(s)" % fails,
                                                          len(SELF_TEST_COMMANDS)))
    return 1 if fails else 0


def self_test_commits(tok: str) -> int:
    """Commit checks need a real repository."""
    import tempfile
    fails = 0
    with tempfile.TemporaryDirectory() as d:
        ident = ["-c", "user.name=t", "-c", "user.email=t@example.invalid"]
        run = lambda *a: subprocess.run(["git"] + ident + ["-C", d] + list(a), check=True, capture_output=True)
        subprocess.run(["git", "init", "-q", d], check=True)
        with open(os.path.join(d, "a.py"), "w") as fh:
            fh.write("x = 1\n")
        run("add", "a.py")
        run("commit", "-q", "-m", "init")
        with open(os.path.join(d, "creds.txt"), "w") as fh:
            fh.write('t = "%s"\n' % tok)
        with open(os.path.join(d, "ok.py"), "w") as fh:
            fh.write("y = 1\n")
        with open(os.path.join(d, "a.py"), "a") as fh:  # tracked file, secret added but not staged
            fh.write('t = "%s"\n' % tok)
        for cmd, should_block in [("git add creds.txt && git commit -m t", True),
                                  ("git add -A && git commit -m t", True),
                                  ("git add . ; git commit -m t", True),
                                  ("git commit -m x a.py", True), ("git commit -m x -- a.py", True),
                                  ("git commit --include a.py -m x", True), ("git commit -am x", True),
                                  ("git add ok.py && git commit -m ok -- ok.py", False),
                                  ("git commit -m nothing-staged", False)]:
            got = evaluate(cmd, d) is not None
            if got != should_block:
                fails += 1
                print("FAIL %r: blocked=%s expected=%s" % (cmd, got, should_block))
        run("add", "creds.txt")
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
        return 0  # not a hook payload
    if data.get("tool_name") != "Bash":
        return 0
    command = (data.get("tool_input") or {}).get("command") or ""
    if not re.search(r"\b(?:git|gh)\b", command):
        return 0
    try:
        reason = evaluate(command, data.get("cwd") or os.getcwd())
    except Exception as e:  # fail closed: an unparsable git/gh command is not waved through
        reason = "安全確認に失敗した（%s）。コマンドを単純な形に分けて実行する" % type(e).__name__
    if reason:
        sys.stderr.write("[guard_git] ブロックしました: %s\n"
                         "（.claude/skills/dev/SKILL.md の運用ルール。どうしても必要ならユーザーに説明し、"
                         "ユーザー自身にターミナルで実行してもらう）\n" % reason)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
