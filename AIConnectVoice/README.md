# AIConnectVoice

The voice engine used by An AI Odyssey: full-duplex audio with echo
cancellation, speech input and endpointing, barge-in, and streamed speech
from System TTS, ElevenLabs, OpenAI and xAI. Builds on
[`../AIConnect`](../AIConnect).

## Requirements

iOS 17+ / macOS 14+, Xcode 26 or later (tested with Xcode 27.2), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) for the Xcode project.

## Build and test

```bash
swift test

xcodegen generate
xcodebuild test -project AIConnectVoice.xcodeproj -scheme AIConnectVoice \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

The tests drive the engine with fake audio hardware, so they need no
microphone. More voice tests that need the app's agent layer live in
`../AnAIOdyssey/AnAIOdysseyAITests`.

## License

MIT. Copyright (c) 2026 Mark Hanson. See [LICENSE](LICENSE). The MIT terms and this copyright line are the existing AIConnectVoice license, unchanged.
