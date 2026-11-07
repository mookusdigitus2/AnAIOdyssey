# AIConnect

Swift packages for reaching AI models from Apple-platform apps: Apple's
on-device model, downloaded local models, LM Studio and other
OpenAI-compatible servers, OpenAI, xAI and Gemini, plus their settings and
the shared settings UI. AIConnect is a connectivity layer only; it holds no
app prompts, agents or features.

| Package / module | What it is |
|---|---|
| `AIModelOptions/` → `AIModelOptions` | Pure value types and codecs: request/response encoding, model catalogs, tool-call formats, policies. No UI, no networking. |
| `AIConnect/` → `AIConnect` | Connections, model registry, remote LLM client, keychain storage, Sign in with ChatGPT. |
| `AIConnect/` → `AIConnectUI` | SwiftUI settings screens and pickers for the above. |

The voice engine that builds on these lives in [`../AIConnectVoice`](../AIConnectVoice).

## Requirements

iOS 17+ / macOS 14+, Xcode 26 or later (tested with Xcode 27.2), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) for the Xcode project.

## Use it

Add the packages by local path or URL, then depend on `AIConnect`,
`AIConnectUI` or `AIModelOptions`:

```swift
.package(path: "../AIConnect/AIConnect"),
.package(path: "../AIConnect/AIModelOptions"),
```

## Build and test

```bash
# Swift packages (macOS)
(cd AIModelOptions && swift test)
(cd AIConnect && swift test)

# Xcode project: the same sources as frameworks, plus both test bundles
xcodegen generate
xcodebuild test -project AIConnect.xcodeproj -scheme AIConnect \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

## License

MIT. Copyright (c) 2026 Mark Hanson. See [LICENSE](LICENSE) for AIConnect and AIConnectUI.

`AIModelOptions/` is part of this folder and has its own [AIModelOptions/LICENSE](AIModelOptions/LICENSE). That file is the same MIT text and the same copyright line. The app license in `../AnAIOdyssey/LICENSE` names Grey Matter Ideations instead. The two lines are both left as written.

The Xcode version sentence above is the one already in this README. It was not re-run for this license update.
