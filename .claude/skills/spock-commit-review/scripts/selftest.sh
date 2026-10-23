#!/bin/sh
# Smoke test for install-hook.sh and review-staged.sh against a throwaway
# HOME, so the real global git config, hooks and skills are not touched, and
# with a stub claude on PATH that records its prompt and prints the verdict
# named in STUB_VERDICT.  Run: sh scripts/selftest.sh

set -eu

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_NAME="$(basename "$SKILL_DIR")"
NAME="${SKILL_NAME%-commit-review}"
T="$(mktemp -d "${TMPDIR:-/tmp}/commit-review-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" CLAUDE_SKILLS_DIR="$T/home/.claude/skills"
# git reads these over HOME, so without this a user who keeps the global
# config elsewhere would have the real one changed.
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$HOME" "$T/bin"
cat > "$T/bin/claude" <<'STUB'
#!/bin/sh
case "$1" in --help) echo "  --tools <tools...>"; exit 0 ;; esac
cat > "$STUB_PROMPT"
snap="$(sed -n 's/^Repository snapshot: \([^ ]*\) .*/\1/p' "$STUB_PROMPT")"
[ -f "$snap/a.txt" ] && cp "$snap/a.txt" "$STUB_PROMPT.a.txt"
[ -f "$snap/big.csv" ] && cp "$snap/big.csv" "$STUB_PROMPT.big.csv"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
case "${STUB_VERDICT:-APPROVE}" in
    TWO) printf 'VERDICT: APPROVE\n\nVERDICT: REJECT\n' ;;
    APPROVED) printf 'VERDICT: APPROVED\n\nSummary: stub.\n' ;;
    *) printf 'VERDICT: %s\n\nSummary: stub.\n' "${STUB_VERDICT:-APPROVE}" ;;
esac
STUB
chmod +x "$T/bin/claude"
export PATH="$T/bin:$PATH" STUB_PROMPT="$T/prompt"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# The committer's own diff and filter configuration must not reach the
# reviewer: an external diff, and a required smudge filter (as git-lfs
# installs) whose command fails because the object is not here.
printf '#!/bin/sh\necho EXTERNAL-DIFF\n' > "$T/bin/extdiff"
chmod +x "$T/bin/extdiff"
git config --global diff.external "$T/bin/extdiff"
git config --global filter.lfs.process "$T/bin/lfs-fails"
git config --global filter.lfs.smudge "$T/bin/lfs-fails"
git config --global filter.lfs.clean cat
git config --global filter.lfs.required true
printf '#!/bin/sh\ntouch "%s/lfs-ran"\nexit 1\n' "$T" > "$T/bin/lfs-fails"
chmod +x "$T/bin/lfs-fails"

# A global hooks directory that was already configured, with one hook.
mkdir -p "$T/oldhooks"
printf '#!/bin/sh\necho OLD-GLOBAL-PRE-COMMIT\n' > "$T/oldhooks/pre-commit"
chmod +x "$T/oldhooks/pre-commit"
git config --global core.hooksPath "~/../oldhooks"

sh "$SKILL_DIR/scripts/install-hook.sh" >/dev/null
[ "$(git config --global core.hooksPath)" = "$HOME/.config/git/hooks" ] || fail "core.hooksPath not set"
[ "$(cat "$HOME/.config/git/hooks/previous-hooks-path")" = "$HOME/../oldhooks" ] || fail "previous hooks path not recorded or not expanded"
pass "install records the previous global hooks path with tilde expanded"

# Repository named after the skill, with its own pre-commit and commit-msg.
R="$T/$NAME"
git init -q "$R"
cd "$R"
git remote add origin "https://github.invalid/someone/$NAME.git"
printf '#!/bin/sh\necho LOCAL-PRE-COMMIT\n' > .git/hooks/pre-commit
printf '#!/bin/sh\necho LOCAL-COMMIT-MSG\n' > .git/hooks/commit-msg
chmod +x .git/hooks/pre-commit .git/hooks/commit-msg

# The previously configured global directory's hook runs, with the local ones.
printf 'zero\n' > z.txt
git add z.txt
out="$(STUB_VERDICT=APPROVE git commit -q -m 'Zero.' 2>&1)" || fail "first commit refused: $out"
echo "$out" | grep -q OLD-GLOBAL-PRE-COMMIT || fail "previous global pre-commit did not run"
echo "$out" | grep -q LOCAL-PRE-COMMIT || fail "local pre-commit did not run"
pass "the previous global hooks directory is chained"

# A hook file sitting in the hooks directory itself is moved aside and kept,
# and a relative symlink there still resolves after the move.
printf '#!/bin/sh\necho IN-PLACE-POST-COMMIT\n' > "$HOME/.config/git/hooks/post-commit.real"
chmod +x "$HOME/.config/git/hooks/post-commit.real"
rm -f "$HOME/.config/git/hooks/previous-hooks-path"
mv "$HOME/.config/git/hooks/post-commit.real" "$HOME/.config/git/hooks/post-commit"
# The hooks directory itself sits behind a symlinked ancestor of another
# depth, as dotfiles layouts do, and the relative link is written for the
# physical location.
mkdir -p "$HOME/src/dotfiles/config"
mv "$HOME/.config/git" "$HOME/src/dotfiles/config/git"
ln -s "$HOME/src/dotfiles/config/git" "$HOME/.config/git"
printf '#!/bin/sh\necho DOTFILES-POST-MERGE\n' > "$HOME/src/dotfiles/post-merge"
chmod +x "$HOME/src/dotfiles/post-merge"
rm -f "$HOME/.config/git/hooks/post-merge"
ln -s ../../../post-merge "$HOME/.config/git/hooks/post-merge"
[ -x "$HOME/.config/git/hooks/post-merge" ] || fail "test setup: relative link does not resolve"
sh "$SKILL_DIR/scripts/install-hook.sh" >/dev/null
[ -x "$HOME/.config/git/hooks/previous/post-commit" ] || fail "in-place hook not moved to previous/"
[ -x "$HOME/.config/git/hooks/previous/post-merge" ] || fail "relative symlink hook dangles after the move"
pass "install keeps a hook file and a relative symlink behind a symlinked ancestor"

# A conflict with an entry already in previous/ stops the install before
# anything is moved: the other in-place hook stays where it was.
printf '#!/bin/sh\necho A\n' > "$HOME/.config/git/hooks/pre-rebase.real"
printf '#!/bin/sh\necho B\n' > "$HOME/.config/git/hooks/post-checkout.real"
chmod +x "$HOME/.config/git/hooks/pre-rebase.real" "$HOME/.config/git/hooks/post-checkout.real"
mv "$HOME/.config/git/hooks/pre-rebase.real" "$HOME/.config/git/hooks/pre-rebase"
mv "$HOME/.config/git/hooks/post-checkout.real" "$HOME/.config/git/hooks/post-checkout"
printf '#!/bin/sh\necho OLD\n' > "$HOME/.config/git/hooks/previous/post-checkout"
if sh "$SKILL_DIR/scripts/install-hook.sh" >/dev/null 2>&1; then
    fail "install went ahead over a previous/ conflict"
fi
[ -f "$HOME/.config/git/hooks/pre-rebase" ] && ! [ -L "$HOME/.config/git/hooks/pre-rebase" ] || fail "a hook was moved despite the conflict"
rm -f "$HOME/.config/git/hooks/previous/post-checkout"
sh "$SKILL_DIR/scripts/install-hook.sh" >/dev/null
[ -x "$HOME/.config/git/hooks/previous/pre-rebase" ] && [ -x "$HOME/.config/git/hooks/previous/post-checkout" ] || fail "hooks not moved after the conflict was cleared"
pass "a previous/ conflict moves nothing, and the install completes once cleared"

# Stage one content and leave different content in the working tree: the
# reviewer must see the staged one.
printf 'one\n' > a.txt
git add a.txt
printf 'unstaged\n' > a.txt
out="$(STUB_VERDICT=APPROVE git commit -q -m 'First.' 2>&1)" || fail "approved commit refused: $out"
[ "$(cat "$STUB_PROMPT.a.txt")" = one ] || fail "reviewer saw the working tree, not the index"
echo "$out" | grep -q LOCAL-PRE-COMMIT || fail "local pre-commit did not run"
echo "$out" | grep -q LOCAL-COMMIT-MSG || fail "local commit-msg did not run"
echo "$out" | grep -q IN-PLACE-POST-COMMIT || fail "moved post-commit did not run"
grep -q '^## Commit message' "$STUB_PROMPT" || fail "prompt has no commit message"
grep -q '^+one$' "$STUB_PROMPT" || fail "prompt has no diff"
grep -q 'EXTERNAL-DIFF' "$STUB_PROMPT" && fail "the committer's external diff reached the prompt"
pass "APPROVE commits, local and kept hooks run, prompt carries message and diff, reviewer sees the index"
git checkout -q -- a.txt

printf 'two\n' > a.txt
git add a.txt
if STUB_VERDICT=REJECT git commit -q -m 'Second.' >/dev/null 2>&1; then
    fail "rejected commit went through"
fi
[ "$(git log --oneline | wc -l | tr -d ' ')" = 2 ] || fail "rejected commit landed"
ls "$R/.git/$NAME-reviews"/*.md >/dev/null 2>&1 || fail "no report written"
pass "REJECT refuses the commit and writes a report"

if STUB_VERDICT=APPROVE git commit -q -m 'Third.' >/dev/null 2>&1; then
    git mv a.txt b.txt
    git add b.txt
    STUB_VERDICT=APPROVE git commit -q -m 'Rename.' >/dev/null 2>&1 || fail "rename commit refused"
    grep -q '^-two$' "$STUB_PROMPT" || fail "rename hides the removal"
    grep -q '^+two$' "$STUB_PROMPT" || fail "rename hides the addition"
    pass "a rename is shown as removal and addition"
else
    fail "third commit refused"
fi

# A path with a quote, a bracket, a space and a non-ASCII byte is diffed
# literally, so the prompt carries its change and no empty diff block.
odd='we"ird [1] é.txt'
printf 'odd\n' > "$odd"
printf 'plain\n' > 'é.txt'
git add -- "$odd" 'é.txt'
STUB_VERDICT=APPROVE git commit -q -m 'Odd.' >/dev/null 2>&1 || fail "odd path commit refused"
grep -q '^+odd$' "$STUB_PROMPT" || fail "odd path's diff is missing from the prompt"
grep -q '^+plain$' "$STUB_PROMPT" || fail "non-ASCII path's diff is missing from the prompt"
grep -q '^+++ b/é.txt$' "$STUB_PROMPT" || fail "non-ASCII path is quoted in the diff header"
grep -q 'not included' "$STUB_PROMPT" && fail "odd path was listed as not included"
pass "paths with quote, bracket, space and non-ASCII bytes are diffed literally and shown unquoted"

# A temporary directory that cannot be created refuses the commit instead of
# reviewing a partial tree.
printf 'y\n' > a.txt
git add a.txt
if out="$(TMPDIR="$T/does-not-exist" STUB_VERDICT=APPROVE git commit -q -m 'Notmp.' 2>&1)"; then
    fail "commit went through with an unusable TMPDIR"
fi
echo "$out" | grep -q 'cannot create a temporary directory' || fail "refused for another reason: $out"
pass "an unusable temporary directory refuses the commit"

# A file behind the required lfs filter, whose process command fails here,
# is snapshotted as its index content, and the commit is not refused.  A
# -diff attribute staged with it does not hide its hunk.
printf 'big.csv filter=lfs -diff\n' > .gitattributes
printf 'pointer\n' > big.csv
# Added with the filter off, and with an old mtime so git's index refresh
# at commit time does not run the clean side of the failing filter, which
# a real git-lfs would pass.
touch -t 200001010000 big.csv
git -c filter.lfs.process= -c filter.lfs.clean= -c filter.lfs.required=false add .gitattributes big.csv
out="$(STUB_VERDICT=APPROVE git commit -q -m 'Pointer.' 2>&1)" || fail "commit refused with a failing lfs filter: $out"
[ "$(cat "$STUB_PROMPT.big.csv")" = pointer ] || fail "snapshot did not hold the index content of the filtered file"
[ ! -e "$T/lfs-ran" ] || fail "the lfs process filter was started for the snapshot"
grep -q '^+pointer$' "$STUB_PROMPT" || fail "a -diff attribute hid the hunk"
pass "the lfs filter is not started for the snapshot, the index content is used, and -diff hides nothing"

# A byte that is not valid UTF-8 is text all the same.  (Such a byte in a
# path is not tried: the macOS filesystem refuses the name.)
# Run under a UTF-8 locale explicitly, which is where BSD tr would stop.
printf 'caf\351\n' > latin1.txt
git add latin1.txt
LC_ALL=en_US.UTF-8 STUB_VERDICT=APPROVE git commit -q -m 'Latin.' >/dev/null 2>&1 || fail "latin-1 commit refused"
LC_ALL=C grep -q '^+caf' "$STUB_PROMPT" || fail "latin-1 content missing from the prompt"
grep -q '(binary)' "$STUB_PROMPT" && fail "latin-1 content listed as binary"
pass "a byte invalid in UTF-8 is still diffed as text"

# A small binary is listed, not dumped into the prompt.
printf 'PNG\000\001\002BINARY-MARK\000\n' > pic.bin
git add pic.bin
STUB_VERDICT=APPROVE git commit -q -m 'Binary.' >/dev/null 2>&1 || fail "binary commit refused"
grep -q '^pic.bin (binary)$' "$STUB_PROMPT" || fail "binary file not listed"
grep -q 'BINARY-MARK' "$STUB_PROMPT" && fail "binary bytes reached the prompt"
pass "a small binary is listed instead of diffed"

# Over budget, the file is listed instead of diffed.
printf 'budget\n' > a.txt
git add a.txt
COMMIT_REVIEW_MAX_DIFF_BYTES=10 STUB_VERDICT=APPROVE git commit -q -m 'Budget.' >/dev/null 2>&1 || fail "over-budget commit refused"
grep -q '^+budget$' "$STUB_PROMPT" && fail "over-budget diff was included"
grep -q 'not included' "$STUB_PROMPT" || fail "over-budget file was not listed"
grep -q '^a.txt$' "$STUB_PROMPT" || fail "over-budget file name missing from the list"
pass "a diff over the budget is listed for reading instead"

# Two verdict lines refuse the commit, so does a verdict that only starts
# with APPROVE; a timeout refuses it and is recorded.
printf 'two\n' > a.txt
git add a.txt
if STUB_VERDICT=TWO git commit -q -m 'Two.' >/dev/null 2>&1; then
    fail "two verdict lines were accepted"
fi
if STUB_VERDICT=APPROVED git commit -q -m 'Approved.' >/dev/null 2>&1; then
    fail "VERDICT: APPROVED was accepted"
fi
if out="$(COMMIT_REVIEW_TIMEOUT_SECS=1 STUB_SLEEP=3 git commit -q -m 'Slow.' 2>&1)"; then
    fail "timed-out review was accepted"
fi
echo "$out" | grep -q 'timed out' || fail "timeout not reported: $out"
grep -l '^TIMEOUT after 1 s' "$R/.git/$NAME-reviews"/*.md >/dev/null || fail "timeout not recorded in a report"
pass "two verdict lines and a timeout both refuse the commit"

# A zero timeout, however spelled, does not disable the alarm: the hook
# reports the timeout it armed, and it must be the default.
printf 'zero\n' > a.txt
git add a.txt
out="$(COMMIT_REVIEW_TIMEOUT_SECS=000 STUB_VERDICT=APPROVE git commit -q -m 'Zerotimeout.' 2>&1)" || fail "zero timeout refused a quick review: $out"
echo "$out" | grep -q 'timeout 900 s' || fail "a zero timeout did not fall back to the default: $out"
pass "a zero timeout falls back to the default"

# A budget that is not a number falls back to the default the same way.
printf 'budgetdefault\n' > a.txt
git add a.txt
out="$(COMMIT_REVIEW_MAX_DIFF_BYTES=lots STUB_VERDICT=APPROVE git commit -q -m 'Budgetdefault.' 2>&1)" || fail "bad budget refused a review: $out"
echo "$out" | grep -q 'budget 250000 bytes' || fail "a bad budget did not fall back to the default: $out"
pass "a budget that is not a number falls back to the default"

# A path with a newline cannot be diffed one file at a time; the commit is
# refused rather than reviewed without that change.
nl_name="$(printf 'new\nline.txt')"
printf 'nl\n' > "$nl_name"
git add -- "$nl_name"
if out="$(STUB_VERDICT=APPROVE git commit -q -m 'Newline.' 2>&1)"; then
    fail "a path with a newline was reviewed without its diff"
fi
echo "$out" | grep -q 'contains a newline' || fail "refused for another reason: $out"
git rm -q --cached -- "$nl_name" && rm -f "$nl_name"
pass "a staged path with a newline refuses the commit"

# Unsetting the global hooks path and reinstalling drops the stale record.
printf '%s\n' "$T/gone" > "$HOME/.config/git/hooks/previous-hooks-path"
git config --global --unset core.hooksPath
sh "$SKILL_DIR/scripts/install-hook.sh" >/dev/null
[ ! -e "$HOME/.config/git/hooks/previous-hooks-path" ] || fail "stale previous-hooks-path kept after reinstall"
pass "a stale previous hooks path is removed on reinstall"

printf 'skip\n' > a.txt
git add a.txt
SKIP_VAR="$(printf '%s' "$NAME" | LC_ALL=C tr 'a-z' 'A-Z' | LC_ALL=C tr -c 'A-Z0-9' '_')_REVIEW"
rm -f "$STUB_PROMPT"
env "$SKIP_VAR=skip" git commit -q -m 'Skip.' >/dev/null 2>&1 || fail "skip did not commit"
[ ! -e "$STUB_PROMPT" ] || fail "skip still ran the reviewer"
grep -l SKIPPED "$R/.git/$NAME-reviews"/*.md >/dev/null || fail "skip not recorded"
pass "$SKIP_VAR=skip bypasses and is recorded"

# A repository with another name is not reviewed.
O="$T/other"
git init -q "$O"
cd "$O"
git remote add origin "https://github.invalid/someone/other.git"
rm -f "$STUB_PROMPT"
printf 'o\n' > o.txt
git add o.txt
git commit -q -m 'Other.' >/dev/null 2>&1 || fail "other repository commit refused"
[ ! -e "$STUB_PROMPT" ] || fail "other repository was reviewed"
pass "a repository with another name is not reviewed"

echo "all passed"
