# Notes for coding agents

- Build with `swift build`; test with `swift test`. Build the app bundle with
  `./scripts/build-app.sh`.
- Engine code goes in `Sources/BurrowCore` and must not import SwiftUI. The app
  (`Sources/Burrow`) and the CLI (`Sources/burrowctl`) are thin layers on top of it.
- Add tests in `Tests/BurrowCoreTests` for engine changes.
- Don't commit anything from `build/` or `.build/`.
- Guest account passwords end up in generated setup media; never log them.
