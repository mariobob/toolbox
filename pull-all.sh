#!/bin/bash

# Pull latest base branch in every git repository under a directory.
# Usage: pull-all [directory]   (defaults to current directory)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/git-base.sh"

pull_all() {
  local root="${1:-.}"

  if [ ! -d "$root" ]; then
    echo "Not a directory: $root"
    return 1
  fi

  root="$(cd "$root" && pwd)"

  local failed=()

  while IFS= read -r git_dir; do
    local repo_dir="${git_dir%/.git}"
    local repo_name="${repo_dir#"$root"/}"

    echo "── $repo_name ──"
    (cd "$repo_dir" && base) || failed+=("$repo_name")
    echo ""
  done < <(find "$root" -name .git -type d -maxdepth 3 | sort)

  if [ ${#failed[@]} -gt 0 ]; then
    echo "Failed repositories:"
    printf "  - %s\n" "${failed[@]}"
    return 1
  fi
}

pull_all "$@"
