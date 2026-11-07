# Acknowledgments

## Odysseus

An AI Odyssey adapts prompt and tool-format text from
[Odysseus](https://github.com/pewdiepie-archdaemon/odysseus) v1.0
(commit `e5c99a5e`), used under the MIT License. Adapted text appears in:

- `Packages/AnAIOdysseyMail/Sources/AnAIOdysseyMail/EmailPrompts.swift`
- `Packages/AnAIOdysseyAI/Sources/AnAIOdysseyAI/Agent/AgentLoopService.swift`
- `Packages/AnAIOdysseyAI/Sources/AnAIOdysseyAI/Agent/AgentToolRegistry.swift`
- `Packages/AnAIOdysseyAI/Sources/AnAIOdysseyAI/Agent/AgentDocumentTools.swift`

```
MIT License

Copyright (c) 2025 Odysseus Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Verified on 2026-11-03: the `LICENSE` file at Odysseus commit `e5c99a5e` is the
MIT License above. (Odysseus's current `main` branch has since moved to the
AGPL-3.0; nothing after `e5c99a5e` is used here.)

## Swift packages and other components

Every bundled package, its license, and its full license and NOTICE text are
listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The app shows the
same text under Settings > About > Acknowledgements.

Those versions are the pins in
`AnAIOdyssey.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
The `Package.resolved` files inside `Packages/AnAIOdysseyAI`,
`Packages/AnAIOdysseyMail`, and `Packages/AnAIOdysseyUI` are a different,
older set. The Odysseus MIT text above is unchanged.
