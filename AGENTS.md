# Project Agent Instructions

Read and follow the shared global process in `/Users/john/Projects/AI/AGENTS.md`.

Before implementation, read:
- `PROJECT_CONTEXT.md`
- `docs/ARCHITECTURE.md`
- `TASK_LEDGER.md` (initial import only; GitLab issues are source of truth)
- `README.md`
- `docs/MANUAL_TEST_PLAN.md`

## Build and Verification

Use the project scripts in `scripts/`:
- `scripts/build.sh [Debug|Release]`
- `scripts/run.sh [Debug|Release] [--no-build]`
- `scripts/test.sh` (enforces 85% region, 80% line, 90% function coverage)
- `scripts/test.sh --last`
- `scripts/install.sh` (installs to `~/Applications/Minuteer.app`)
