#!/bin/bash

# Shared base branch helper — source this file, do not execute directly.

# Detect the base branch for the current git repository.
# Accepts an optional argument to override detection.
# Sets the variable: _base_branch
detect_base_branch() {
  _base_branch=""

  if [ -n "$1" ]; then
    _base_branch="$1"
    return 0
  fi

  # Method 1: Check origin/HEAD (most reliable if set)
  _base_branch="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"

  # Method 2: Fall back to common base branch names
  if [ -z "$_base_branch" ]; then
    for candidate in develop staging main master; do
      if git show-ref --verify --quiet "refs/remotes/origin/$candidate"; then
        _base_branch="$candidate"
        return 0
      fi
    done
  fi

  [ -n "$_base_branch" ]
}

# Checkout the base branch and pull latest changes.
# Usage: base [branch]
base() {
  if ! detect_base_branch "$1"; then
    echo "Could not detect base branch."
    echo "Usage: base [branch]"
    return 1
  fi

  # Already on base branch? Just pull
  local current
  current="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$current" = "$_base_branch" ]; then
    echo "Already on '$_base_branch', pulling..."
    git pull --ff-only
    return $?
  fi

  # Check for uncommitted changes
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Working tree has uncommitted changes. Commit/stash first."
    return 1
  fi

  echo "Switching to '$_base_branch' and pulling..."
  git checkout "$_base_branch" || return 1
  git pull --ff-only
}
