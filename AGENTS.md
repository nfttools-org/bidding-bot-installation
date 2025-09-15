# Repository Guidelines

## Project Structure & Module Organization
- Root contains `install.sh` (installer), `compose.yaml` (Docker Compose), and auxiliary docs like `CLAUDE.md`.
- No application source code here; this repo installs and runs prebuilt images: `server`, `client`, `mongodb`, `redis`.
- Data persists in Docker volumes: `mongodb_data`, `redis_data`, `server_data`.

## Build, Test, and Development Commands
- Run installer: `bash install.sh` (sets up Docker, swap on Linux, pulls images, starts services).
- Compose lifecycle in the project directory:
  - `docker compose up -d` — start/update services.
  - `docker compose ps` — status; `docker compose logs -f server` — tail logs.
  - `docker compose down` — stop (volumes preserved).
- Validate configs: `docker compose config -q` (YAML sanity), `bash -n install.sh` (bash syntax).
- Health checks: `curl -f http://localhost:3003/health` and `curl -f http://localhost:3001/api/health`.

## Coding Style & Naming Conventions
- Bash (`install.sh`):
  - Prefer `set -euo pipefail` and explicit checks; functions as `lower_snake_case`.
  - Env vars UPPER_SNAKE_CASE; inline comments for non-obvious steps.
- YAML (`compose.yaml`): 2-space indent, lowercase service names, quoted ports (`"3001:3001"`).
- Filenames: kebab- or snake-case; scripts end with `.sh`.

## Testing Guidelines
- Lint shell: `shellcheck install.sh` (fix warnings before PR).
- Dry runs: run `docker compose pull` and `docker compose up` locally; verify health endpoints and volumes.
- If editing Compose, ensure services still start on amd64 and arm64 (see installer’s arch branch).

## Commit & Pull Request Guidelines
- Commits use imperative mood, concise subject (<= 72 chars), e.g., `Improve Redis healthcheck timing`.
- PRs include: summary of changes, rationale, test steps (commands + expected output), and any risks/rollbacks.
- Link related issues; attach logs or screenshots of `docker compose ps` when debugging infra changes.

## Security & Configuration Tips
- Never commit secrets. Use `.env` for `SERVER_IP`, `USERNAME`, `EMAIL`, `API_KEY`, `RATE_LIMIT`, etc. Compose reads from environment.
- Preserve MongoDB data: avoid removing `mongodb_data` unless explicitly required.
- Verify external URLs in `install.sh` before changing; prefer pinning to known-good sources and image tags.
