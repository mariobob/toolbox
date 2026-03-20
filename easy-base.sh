#!/bin/bash

# Easy checkout to base branch and pull

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/git-base.sh"

base "$@"
