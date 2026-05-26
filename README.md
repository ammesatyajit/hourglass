# Hourglass

Native macOS search + analytics for your iMessage history. Everything runs locally.

[**Download the latest signed DMG →**](https://github.com/ammesatyajit/hourglass/releases/latest/download/Hourglass.dmg)

## Build it yourself

```bash
brew install xcodegen xcbeautify create-dmg
git clone https://github.com/ammesatyajit/hourglass.git
cd hourglass
./scripts/generate.sh     # XcodeGen → Hourglass.xcodeproj
./scripts/build.sh        # Debug build → build/Build/Products/Debug/Hourglass.app
./scripts/test.sh         # ~500 tests, ~1 second
open Hourglass.xcodeproj  # or just iterate in Xcode
```

Requires **macOS 15+** and **Xcode 26+**. Apple Silicon recommended (the optional natural-language search uses MLX).

Or hand the repo to a coding agent and say *"set this up locally and run the tests."* The project is XcodeGen + SPM with a hermetic test suite (synthetic fixture, no real data), so most agents figure it out.

## Contributing

PRs welcome. Run `./scripts/test.sh` before sending; everything should be green. For larger changes, file an issue first.

The one hard rule: **no new network calls.** Local-only is the core promise. The one existing outbound is the optional first-run Hugging Face model download for NL search — and it's gated/opt-in.

## License

MIT. See [LICENSE](LICENSE).
