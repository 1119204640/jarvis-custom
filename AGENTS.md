# AGENTS.md

This file provides guidance to Codex and other AI coding agents working in this repository.

## Communication

- Use Chinese when communicating with the user.
- Read the relevant code before answering or editing; avoid making assumptions from filenames alone.

## Project Layout

- This project uses `uv` for dependency and environment management. Prefer `uv` commands when running Python code.
- First-party code lives in `src/`.
- Vendored or third-party code fetched from GitHub lives in `modules/`; avoid editing it unless the task clearly requires it.
- Client code lives in `src/client/`. The Flutter app is in `src/client/flutter_application_1/`.
- Server code lives in `src/server/`.

## Documentation Discipline

- Record non-trivial problems and their solutions in the repo-root `README.md`.
- If the problem belongs to the Flutter client, also record it in `src/client/flutter_application_1/README.md`.

## Validation

- Use `uv run python .claude/skills/run-jarvis/run_jarvis_smoke.py` for the main server smoke test when validating backend behavior.
- Human-run entry points remain `./start-server.sh` and `./start-client.sh`.
