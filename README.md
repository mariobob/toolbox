# Toolbox
A collection of utility scripts for automation and productivity.

## Usage
Add aliases to your shell config (`.zshrc`, `.bashrc`, etc.):
```bash
alias rebase="~/path/to/easy-rebase.sh"
alias lintcheck="~/path/to/lintcheck.sh"
alias magic="~/path/to/reconnect-bluetooth-devices.sh"
alias partial-push="~/path/to/partial-push.sh"
```

## Scripts
### check-ip.sh
Checks and logs public IP address changes. Only outputs on first run and when IP changes are detected.

**Useful for:** Scheduling with cron or task schedulers to track IP changes over time without flooding logs.

### easy-rebase.sh
Simplifies Git rebasing with two modes: interactive rebase of last N commits (preserving author dates) or pulling a target branch and rebasing onto it.

**Useful for:** Cleaning up commit history before merging or staying up-to-date with a base branch while maintaining a clean rebase workflow.

### lintcheck.sh
Runs Python linters (black, ruff, flake8) on changed files from recent Git commits or uncommitted changes.

**Useful for:** Validating code quality before pushing to ensure all changes pass linting standards.

### partial-push.sh
Pushes commits to remote while keeping the last N commits local. Safely resets, pushes with force-with-lease, then restores local commits.

**Useful for:** Pushing reviewed changes in a PR while keeping work-in-progress commits local for further refinement.

### reconnect-bluetooth-devices.sh
Automatically reconnects Bluetooth devices. 

**Useful for:** Switching peripherals between computers (e.g. magic keyboard, trackpad, mouse, headphones).
