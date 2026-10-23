#!/bin/sh
# Install this commit review skill as a global git hook.
#
# The skill is copied to ~/.claude/skills/<name>-commit-review, so the hook
# does not depend on any checkout staying around.  A dispatcher is installed
# in ~/.config/git/hooks under every hook name that git runs in addition to
# its own work, and core.hooksPath is pointed there.  For every hook event the
# dispatcher first runs the repository's own hook of the same name, if it has
# one, so other repositories keep their pre-commit, pre-push and other hooks.
# Two names are left out on purpose, push-to-checkout and proc-receive: when
# either exists it replaces a step git would otherwise do itself, so a
# dispatcher under that name would break every repository without a local
# one.  The dispatcher runs on every index write and ref update on the
# machine, a few milliseconds each.  A global core.hooksPath that was
# already set is recorded in ~/.config/git/hooks/previous-hooks-path and the
# dispatcher runs its hooks too, after the repository's own.  Hook files
# that already live in ~/.config/git/hooks itself are moved to a previous/
# directory there and run the same way.  Only a value in the global scope
# is preserved, not one in the system config; and if the previous
# directory's hooks run the repository's own hooks themselves, those run
# twice.  Delete previous-hooks-path to stop the chaining.
#
# The review itself runs only for commit-msg, and only in a repository whose
# origin is named like an installed skill: origin .../spock runs
# spock-commit-review, origin .../ace runs ace-commit-review, and so on.
# That covers every clone and worktree, and a fork as long as its origin
# keeps the name, except a repository that sets core.hooksPath locally, where
# git never runs the global hooks.  The skills for several repositories
# share the one dispatcher; installing a second skill does not disturb the
# first.
#
# scripts/selftest.sh exercises all of this against a throwaway HOME.
#
# Run from any copy of the skill, for example a repository checkout:
#
#     sh .claude/skills/<name>-commit-review/scripts/install-hook.sh
#
# Undo with: git config --global --unset core.hooksPath, or set it back to
# the path saved in ~/.config/git/hooks/previous-hooks-path if that file
# exists.

set -eu
# Character ranges below are meant in ASCII, whatever the user's locale.
LC_ALL=C
export LC_ALL

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_NAME="$(basename "$SRC_DIR")"
# The dispatcher lowercases the origin's name before looking the skill up,
# so the skill directory must be lowercase, and simple enough to be a
# directory name and a variable name.
case "$SKILL_NAME" in
    [a-z0-9]*-commit-review) ;;
    *) echo "skill directory must be named <name>-commit-review with a lowercase name: $SKILL_NAME" >&2
       exit 1 ;;
esac
case "$SKILL_NAME" in
    *[!a-z0-9._-]*) echo "skill name may only hold a-z, 0-9, dot, underscore and dash: $SKILL_NAME" >&2
       exit 1 ;;
esac
SKILLS_HOME="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
SKILL_HOME="$SKILLS_HOME/$SKILL_NAME"
HOOKS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/git/hooks"

if ! [ "$SRC_DIR" -ef "$SKILL_HOME" ]; then
    mkdir -p "$SKILL_HOME/scripts"
    cp "$SRC_DIR/SKILL.md" "$SKILL_HOME/SKILL.md"
    cp "$SRC_DIR/scripts/review-staged.sh" "$SRC_DIR/scripts/install-hook.sh" \
       "$SRC_DIR/scripts/selftest.sh" "$SKILL_HOME/scripts/"
fi
chmod +x "$SKILL_HOME/scripts/"*.sh

mkdir -p "$HOOKS_DIR"
# Record a global hooks directory that was configured before.  On a
# reinstall over this dispatcher the record is kept; when no global path is
# set any more, a record of another directory is stale and is removed, so
# its hooks do not keep running after the user unset it.
previous="$(git config --global --type=path --get core.hooksPath || true)"
recorded="$(cat "$HOOKS_DIR/previous-hooks-path" 2>/dev/null || true)"
if [ -n "$previous" ] && ! [ "$previous" -ef "$HOOKS_DIR" ]; then
    printf '%s\n' "$previous" > "$HOOKS_DIR/previous-hooks-path"
elif [ -z "$previous" ] && [ -n "$recorded" ] && ! [ "$recorded" -ef "$HOOKS_DIR/previous" ]; then
    rm -f "$HOOKS_DIR/previous-hooks-path"
    echo "removed the stale record of $recorded; core.hooksPath was no longer set"
fi

HOOK_NAMES="applypatch-msg pre-applypatch post-applypatch pre-commit \
            pre-merge-commit prepare-commit-msg commit-msg post-commit \
            pre-rebase post-checkout post-merge pre-push post-rewrite \
            pre-auto-gc sendemail-validate post-index-change \
            reference-transaction pre-receive update post-receive \
            post-update p4-changelist p4-prepare-changelist \
            p4-post-changelist p4-pre-submit"

# Hooks already in the hooks directory itself are kept in previous/ and run
# from there, unless previous-hooks-path already names another directory.
# Every conflict is checked before anything is moved, so the install either
# moves them all or none.
is_own_link() {
    [ -L "$1" ] && [ "$(readlink "$1")" = commit-review-dispatch ]
}
recorded="$(cat "$HOOKS_DIR/previous-hooks-path" 2>/dev/null || true)"
for hook in $HOOK_NAMES; do
    f="$HOOKS_DIR/$hook"
    [ -e "$f" ] || continue
    is_own_link "$f" && continue
    if [ -n "$recorded" ] && ! [ "$recorded" -ef "$HOOKS_DIR/previous" ]; then
        echo "$f exists and previous-hooks-path already names $recorded;" >&2
        echo "move the hook there or elsewhere, then run the installer again" >&2
        exit 1
    fi
    if [ -e "$HOOKS_DIR/previous/$hook" ] || [ -L "$HOOKS_DIR/previous/$hook" ]; then
        echo "$f exists and so does $HOOKS_DIR/previous/$hook;" >&2
        echo "move one of them elsewhere, then run the installer again" >&2
        exit 1
    fi
done
for hook in $HOOK_NAMES; do
    f="$HOOKS_DIR/$hook"
    [ -e "$f" ] || continue
    is_own_link "$f" && continue
    mkdir -p "$HOOKS_DIR/previous"
    if [ -L "$f" ]; then
        # Re-create a symlink with an absolute target, so a relative one
        # still resolves one directory deeper.  Resolved physically, as
        # the kernel does, in case an ancestor is itself a symlink.
        target="$(readlink "$f")"
        case "$target" in
            /*) ;;
            *) target="$(cd -P "$HOOKS_DIR" && cd -P "$(dirname "$target")" && pwd -P)/$(basename "$target")" ;;
        esac
        ln -s "$target" "$HOOKS_DIR/previous/$hook"
        rm -f "$f"
    else
        mv "$f" "$HOOKS_DIR/previous/$hook"
    fi
    printf '%s\n' "$HOOKS_DIR/previous" > "$HOOKS_DIR/previous-hooks-path"
    echo "moved $f to $HOOKS_DIR/previous/"
done
cat > "$HOOKS_DIR/commit-review-dispatch" <<DISPATCH
#!/bin/sh
# Global git hook dispatcher, installed by the <name>-commit-review skills and
# linked under every additive hook name.
# 1. Run the repository's own hook of the same name, if it has one.
# 2. Run the same hook from the global hooks directory that core.hooksPath
#    named before this one was installed, if there was one.
# 3. For commit-msg, run the review skill named after the origin repository,
#    if one is installed.
# Hooks that git feeds on stdin get a copy of it each; the others inherit
# stdin as they would without the dispatcher.

hook="\$(basename "\$0")"
common_dir="\$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0
case "\$common_dir" in /*) ;; *) common_dir="\$(pwd)/\$common_dir" ;; esac
local_hook="\$common_dir/hooks/\$hook"
previous_dir="\$(cat "$HOOKS_DIR/previous-hooks-path" 2>/dev/null)"
[ -x "\$local_hook" ] && [ "\$local_hook" != "\$0" ] || local_hook=""
[ -n "\$previous_dir" ] && [ -x "\$previous_dir/\$hook" ] || previous_dir=""

stdin_copy=""
if [ -n "\$local_hook\$previous_dir" ]; then
    case "\$hook" in
        pre-push|pre-receive|post-receive|post-rewrite|reference-transaction)
            stdin_copy="\$(mktemp "\${TMPDIR:-/tmp}/hook-stdin.XXXXXX")"
            cat > "\$stdin_copy"
            trap 'rm -f "\$stdin_copy"' EXIT ;;
    esac
fi
run_hook() {
    if [ -n "\$stdin_copy" ]; then
        "\$@" < "\$stdin_copy"
    else
        "\$@"
    fi
}

if [ -n "\$local_hook" ]; then
    run_hook "\$local_hook" "\$@" || exit \$?
fi
if [ -n "\$previous_dir" ]; then
    run_hook "\$previous_dir/\$hook" "\$@" || exit \$?
fi

if [ "\$hook" = commit-msg ]; then
    name="\$(git remote get-url origin 2>/dev/null \\
             | sed -E 's#/+\$##; s#\\.git\$##; s#.*[:/]##' | tr 'A-Z' 'a-z')"
    reviewer="$SKILLS_HOME/\$name-commit-review/scripts/review-staged.sh"
    if [ -n "\$name" ] && [ -x "\$reviewer" ]; then
        exec "\$reviewer" "\$@"
    fi
fi
exit 0
DISPATCH
chmod +x "$HOOKS_DIR/commit-review-dispatch"

for hook in $HOOK_NAMES; do
    ln -sf commit-review-dispatch "$HOOKS_DIR/$hook"
done

git config --global core.hooksPath "$HOOKS_DIR"

# A repository that sets core.hooksPath locally never runs the global hooks.
local_path="$(git config --local --get core.hooksPath 2>/dev/null || true)"
if [ -n "$local_path" ]; then
    echo "note: the repository you are in sets core.hooksPath=$local_path locally," >&2
    echo "so git will not run the review hook there; unset it or chain $HOOKS_DIR/commit-msg from it" >&2
fi
echo "skill installed: $SKILL_HOME"
echo "hooks installed: $HOOKS_DIR (core.hooksPath set globally)"
