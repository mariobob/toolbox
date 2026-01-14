#!/bin/bash

# Easy rebase
rebase() {
    if [ -z "$1" ]; then
        echo "Usage:"
        echo "  rebase <N>        # interactive rebase last N commits (keeps committer date = author date)"
        echo "  rebase <branch>   # pull <branch> then rebase current branch onto it"
        return 1
    fi

    # If it's all digits -> treat as count for interactive rebase
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        local n="$1"
        if [ "$n" -le 0 ]; then
            echo "N must be >= 1"
            return 1
        fi

        # Save base commit to count resulting commits after squashing
        local base
        base=$(git rev-parse HEAD~"$n") || return 1

        git rebase -i "HEAD~$n" --committer-date-is-author-date || return $?

        # Fix committer dates on resulting commits (needed after squash/edit)
        local new_n
        new_n=$(git rev-list --count "$base"..HEAD)
        if [ "$new_n" -gt 0 ]; then
            git rebase "HEAD~$new_n" --committer-date-is-author-date
        fi
        return $?
    fi

    # Otherwise treat as branch name
    local target="$1"
    local original

    original="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 1
    if [ -z "$original" ] || [ "$original" = "HEAD" ]; then
        echo "Not on a branch (detached HEAD). Aborting."
        return 1
    fi

    # Make sure working tree is clean before switching branches
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "Working tree has uncommitted changes. Commit/stash before rebasing."
        return 1
    fi

    echo "Updating '$target' then rebasing '$original' onto '$target'..."

    # Fetch first so local target can be updated even if it doesn't exist locally yet
    git fetch --prune || return 1

    # Ensure target exists (locally or as remote tracking)
    if git show-ref --verify --quiet "refs/heads/$target"; then
        : # local branch exists
    elif git show-ref --verify --quiet "refs/remotes/origin/$target"; then
        # create local branch tracking origin/target
        git branch --track "$target" "origin/$target" || return 1
    else
        echo "Branch '$target' not found (neither local nor origin/$target)."
        return 1
    fi

    # Checkout target, pull, go back, rebase
    git checkout "$target" || return 1
    git pull --ff-only || { git checkout "$original" >/dev/null 2>&1; return 1; }

    git checkout "$original" || return 1
    git rebase "$target"
}

rebase "$@"
