# Toolbox
A collection of utility scripts for automation and productivity.

## Scripts
### check-ip.sh
Checks and logs public IP address changes. Only outputs on first run and when IP changes are detected.

**Useful for:** Scheduling with cron or task schedulers to track IP changes over time without flooding logs.

### lintcheck.sh
Runs Python linters (black, ruff, flake8) on changed files from recent Git commits or uncommitted changes.

**Useful for:** Validating code quality before pushing to ensure all changes pass linting standards.

### reconnect-bluetooth-devices.sh
Automatically reconnects Bluetooth devices. 

**Useful for:** Switching peripherals between computers (e.g. magic keyboard, trackpad, mouse, headphones).
