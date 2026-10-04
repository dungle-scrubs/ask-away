# Contributing

Thank you for considering contributing to ask-away!

## Development Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/dungle-scrubs/ask-away.git
   cd ask-away
   ```

2. Install Xcode (the build uses its Swift 6 toolchain):
   ```bash
   xcode-select --install
   ```

3. Build the universal binary:
   ```bash
   ./build.sh
   ```

4. Run it:
   ```bash
   bin/ask-away --title "test: hello" --text "Does it work?" --buttons "No" "Yes"
   ```

## Making Changes

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes in `src/`
4. Build and exercise the real panel: `./build.sh` then a real invocation
5. Commit with a descriptive message
6. Push and open a Pull Request

## Code Style

- Swift 6 language mode; the build treats warnings as errors
- Design tokens come from `src/Theme.swift` - never hardcode a color, font, or spacing value elsewhere; `docs/design.md` is the binding visual contract
- Keep the CLI contract stable: flags, stdout values, and exit codes are load-bearing for every calling agent
- Add comments for non-obvious logic

## Commit Messages

This project uses [Conventional Commits](https://www.conventionalcommits.org/):

| Prefix | Purpose | Example |
| --- | --- | --- |
| `feat:` | New feature | `feat: cascade registry for parallel panels` |
| `fix:` | Bug fix | `fix: drain line hidden under scrim layer` |
| `docs:` | Documentation | `docs: update CLI reference` |
| `refactor:` | Code restructuring | `refactor: split glow from border layer` |
| `chore:` | Maintenance | `chore: bump CI runner image` |

## Pull Request Guidelines

- Keep PRs focused on a single change
- Include a clear description of what and why
- Update documentation if needed
- Verify the visual contract (`docs/design.md`) for any UI-facing change: chamfers, border, scrim, button states, drain line, countdown ramp
