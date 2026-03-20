#!/bin/bash

# Easy checkout to base branch and pull
base() {
  local base_branch

  # If argument provided, use it directly
  if [ -n "$1" ]; then
    base_branch="$1"
  else
    # Method 1: Check origin/HEAD (most reliable if set)
    base_branch="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"

    # Method 2: Fall back to common base branch names
    if [ -z "$base_branch" ]; then
      for candidate in develop staging main master; do
        if git show-ref --verify --quiet "refs/remotes/origin/$candidate"; then
          base_branch="$candidate"
          break
        fi
      done
    fi
  fi

  if [ -z "$base_branch" ]; then
    echo "Could not detect base branch."
    echo "Usage: base [branch]"
    return 1
  fi

  # Already on base branch? Just pull
  local current
  current="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$current" = "$base_branch" ]; then
    echo "Already on '$base_branch', pulling..."
    git pull --ff-only
    return $?
  fi

  # Check for uncommitted changes
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Working tree has uncommitted changes. Commit/stash first."
    return 1
  fi

  echo "Switching to '$base_branch' and pulling..."
  git checkout "$base_branch" || return 1
  git pull --ff-only
}

base "$@"
