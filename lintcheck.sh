#!/bin/bash

# lintcheck performs formatting and linting on changed Python files using black, ruff, and flake8.
# It determines which files to lint based on uncommitted changes or recent commits.
#
# If no argument is provided:
#   - If there are uncommitted Python files, it prompts the user to lint them.
#   - If there are no uncommitted changes, it defaults to linting the last commit.
#
# If an argument is provided:
#   - 0: lints uncommitted (staged/unstaged) Python files, no prompt.
#   - N > 0: lints Python files changed in the last N commits.
#
# For each selected file, the function:
#   - Formats with black
#   - Fixes issues with ruff
#   - Checks code style with flake8
#
# The function stops early if any of the tools report issues, so you can inspect and re-run.
#
# Example usage:
#   lintcheck       # lints the last commit, or prompts if there are uncommitted files
#   lintcheck 0     # silently lints uncommitted changes
#   lintcheck 2     # lints last 2 commits
lintcheck() {
    num_commits=$1
    changed_files=()

    if [ -z "$num_commits" ]; then
        changed_files=( $(get_uncommitted_python_files) )

        if [ "${#changed_files[@]}" -gt 0 ]; then
            echo "Uncommitted Python files detected:"
            for file in "${changed_files[@]}"; do
                echo "- $file"
            done
            echo -n "Do you want to lint these uncommitted changes? [y/N]: "
            read -r answer
            if [[ ! "$answer" =~ ^[Yy]$ ]]; then
                echo "Aborting lintcheck."
                return 0
            fi
        else
            num_commits=1
        fi
    fi

    if [ -n "$num_commits" ] && [ "${#changed_files[@]}" -eq 0 ]; then
        if [ "$num_commits" -eq 0 ]; then
            changed_files=( $(get_uncommitted_python_files) )
        else
            commit_range="HEAD~$num_commits..HEAD"
            for file in $(git diff --name-only --diff-filter=ACMRTUXB "$commit_range"); do
                if echo "$file" | grep -qE '\.py$'; then
                    changed_files+=("$file")
                fi
            done
        fi
    fi

    if [ "${#changed_files[@]}" -eq 0 ]; then
        echo "No Python files to lint."
        return 0
    fi

    echo "Linting the following files:"
    for file in "${changed_files[@]}"; do
        echo "- $file"
    done
    echo

    # Run Black
    echo "Running black..."
    black "${changed_files[@]}"
    if [ $? -ne 0 ]; then
        echo "black encountered issues. Please check and re-run lintcheck."
        return 1
    fi

    # Run Ruff with --fix
    echo "Running ruff check with --fix..."
    ruff check "${changed_files[@]}" --fix
    if [ $? -ne 0 ]; then
        echo "ruff found issues. Please check and re-run lintcheck."
        return 1
    fi

    # Run flake8
    echo "Running flake8..."
    flake8 "${changed_files[@]}"
    if [ $? -ne 0 ]; then
        echo "flake8 found issues. Please check and re-run lintcheck."
        return 1
    fi

    echo "All checks passed!"
    return 0
}

# Helper: returns unique list of uncommitted (staged and/or unstaged) Python files
get_uncommitted_python_files() {
    local files=()
    local file

    # Collect both unstaged (working tree) and staged (index) changes
    for file in $(git diff --name-only --diff-filter=ACMRTUXB; git diff --cached --name-only --diff-filter=ACMRTUXB); do
        [[ $file == *.py ]] && files+=("$file")
    done

    # Deduplicate and output
    printf '%s\n' "${files[@]}" | sort -u
}

# Invoke the lintcheckfunction
lintcheck "$@"
