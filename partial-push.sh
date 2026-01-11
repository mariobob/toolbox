#!/bin/bash

# Partial push - push commits while keeping recent ones local
partial_push() {
    local n="$1"

    if ! [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
        echo "Usage: partial-push <N>"
        echo "  Pushes commits except the last N commits (which stay local)"
        echo ""
        echo "Example:"
        echo "  partial-push 2    # push all commits except the last 2"
        return 1
    fi

    # Validate git state
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "Error: not in a git repository"; return 1; }

    local branch
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [[ -n "$branch" && "$branch" != "HEAD" ]] || { echo "Error: not on a branch (detached HEAD)"; return 1; }

    git diff --quiet && git diff --cached --quiet || { echo "Error: uncommitted changes. Commit or stash first."; return 1; }

    local total
    total=$(git rev-list --count HEAD)
    [[ "$n" -lt "$total" ]] || { echo "Error: only $total commit(s) in history, cannot keep back $n"; return 1; }

    # Display info
    local remote
    remote=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null)

    echo "Current branch: $branch"
    echo "Remote: ${remote:-origin/$branch}"
    echo ""

    echo "Commits that will STAY LOCAL (not pushed):"
    echo "-------------------------------------------"
    git --no-pager log --oneline HEAD~"$n"..HEAD
    echo ""

    local to_push
    [[ -n "$remote" ]] && to_push=$(git --no-pager log --oneline @{u}..HEAD~"$n" 2>/dev/null)

    echo "Commits that will be PUSHED:"
    echo "----------------------------"
    if [[ -z "$to_push" ]]; then
        echo "(none - remote is already up to date)"
        return 0
    fi
    echo "$to_push"
    echo ""

    echo -n "Proceed? (uses --force-with-lease) [y/N]: "
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; return 0; }

    echo ""
    echo "Executing partial push..."

    git reset --hard HEAD~"$n" || return 1

    if git push --force-with-lease; then
        echo "✓ Push successful"
    else
        echo "✗ Push failed, restoring..."
        git reset --hard HEAD@{1}
        return 1
    fi

    git reset --hard HEAD@{1} || { echo "✗ Failed to restore. Check: git reflog"; return 1; }

    echo "✓ Local commits restored"
    echo ""
    echo "Done! Pushed all commits except the last $n."
}

partial_push "$@"
