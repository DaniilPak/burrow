# Contributing to Burrow

Burrow welcomes bug fixes, documentation improvements, tests, and support for new
guests and devices. For large changes (a new guest backend, a new disk format,
changes to the `.burrow` bundle layout), open an issue first so we can agree on the
scope before you write the code.

## Getting set up

You need an Apple silicon Mac on macOS 14 or later and Xcode with Swift 6.

```bash
git clone https://github.com/DaniilPak/burrow.git
cd burrow
swift build
swift test                      # unit tests for BurrowCore
./scripts/build-app.sh          # → build/Burrow.app and build/burrowctl
```

Windows guests also need QEMU: `brew install qemu`.

## Where to start

- Issues labeled [`good first issue`](https://github.com/DaniilPak/burrow/labels/good%20first%20issue)
  are small and well scoped.
- Issues labeled [`help wanted`](https://github.com/DaniilPak/burrow/labels/help%20wanted)
  are bigger features we'd love help with.
- The [Limits in the FAQ](README.md#faq) list what doesn't work yet. Each one is a
  welcome contribution.

## Code layout

| Path | What lives there |
|---|---|
| `Sources/BurrowCore` | The engine. No UI code; everything here should be testable. |
| `Sources/Burrow` | The SwiftUI app. Keep logic in `BurrowCore` and views thin. |
| `Sources/burrowctl` | The CLI. New engine features should usually get a command here too. |
| `Tests/BurrowCoreTests` | Unit tests for `BurrowCore`. |

## Pull requests

- Keep each PR focused on one change, and explain the problem it solves.
- Add or update tests in `Tests/BurrowCoreTests` for engine changes.
- Run `swift test` before opening the PR, and say which guests you tried it with
  (for example "Ubuntu 24.04 desktop, Windows 11 24H2").
- For UI changes, include a screenshot.
- Match the style of the surrounding code.

## Reporting issues

Use the issue form that fits. For bugs, include your Mac model, macOS version, the
guest OS, what you expected, what happened, and the shortest way to reproduce it.
For a guest that won't boot, attach `console.log` from the machine's `.burrow` folder
if there is one.

Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Code of conduct

Be kind and assume good intent. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
