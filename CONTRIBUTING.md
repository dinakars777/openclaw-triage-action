# Contributing to OpenClaw Triage Action

Thanks for your interest in contributing! Here's how to get started.

## Development Setup

1. Fork the repository
2. Clone your fork
3. Make your changes on a feature branch
4. Open a PR against `main`

## Code Style

- Use `shellcheck` on all bash scripts
- Follow [Google's Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- Add comments explaining non-obvious logic

## Testing

Run the triage script locally against any public repo:

```bash
export GH_TOKEN=$(gh auth token)
export PR_NUMBER=1
export REPO=owner/repo
bash scripts/triage-action.sh
```

## Reporting Issues

Please include:
- Steps to reproduce
- Expected vs actual behavior
- Your OS and `gh` CLI version
