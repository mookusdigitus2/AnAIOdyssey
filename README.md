# An AI Odyssey

Standalone source for the An AI Odyssey app and the local packages it builds with. The app is a personal AI workspace for Mac, iPad, and iPhone. `AnAIOdyssey` (no spaces) is the code name used for modules, targets, and folders. User-facing text says "An AI Odyssey".

This tree is a copy of the staged files into a new Git repository. The destination `.git` was reinitialized empty: no commits and no remote. It does not contain another repository's history. This documentation update does not publish the repository and does not push it.

The repository being set up is <https://github.com/mookusdigitus2/AnAIOdyssey>. That address is the intended remote. It is not a claim that this tree has been pushed there.

The previous root `README.md` was the 52-byte scaffold (`# AnAIOdyssey` / `An AI based knowledge management tool`). The previous root `LICENSE` was the Apache License 2.0 scaffold from that empty repository. Neither described this code. Both are replaced. Third-party Apache-2.0 notices stay in `AnAIOdyssey/THIRD_PARTY_NOTICES.md`.

## Layout that was copied

The copy kept the staged folders. Paths below are from this repository's root.

```
README.md
LICENSE                         component map, not a single grant
AnAIOdyssey/                    app, XcodeGen project, local Swift packages
AIConnect/
  LICENSE                       MIT for AIConnect and AIConnectUI
  AIConnect/                    Swift package (products AIConnect, AIConnectUI)
  AIModelOptions/               Swift package (product AIModelOptions)
  project.yml                   XcodeGen project for those packages
AIConnectVoice/
  LICENSE                       MIT
  Package.swift
  project.yml
```

`AIModelOptions` is present at `AIConnect/AIModelOptions`. There is no `AIModelOptions` package at the repository root, and these docs do not add one.

Local package paths in the manifests match this layout:

- `AnAIOdyssey/project.yml` depends on `../AIConnect/AIConnect` and `../AIConnectVoice`.
- `AnAIOdyssey/Packages/AnAIOdysseyAI/Package.swift` depends on `../AnAIOdysseyCore`, `../../../AIConnect/AIModelOptions`, `../../../AIConnect/AIConnect`, `../../../AIConnectVoice`, and `https://github.com/ml-explore/mlx-swift-lm` from 2.21.2.
- `AnAIOdyssey/Packages/AnAIOdysseyUI/Package.swift` uses the same `../../../AIConnect/...` paths.
- `AnAIOdyssey/Packages/AnAIOdysseyCore/Package.swift` depends on `../../../AIConnect/AIConnect`.
- `AIConnect/AIConnect/Package.swift` depends on `../AIModelOptions`.
- `AIConnectVoice/Package.swift` depends on `../AIConnect/AIConnect` and `../AIConnect/AIModelOptions`.

## Component licenses

The map with copyright lines is [`LICENSE`](LICENSE). Short form:

| Component | License |
|---|---|
| `AnAIOdyssey/` | AGPL-3.0-or-later, Copyright (C) 2026 Grey Matter Ideations, plus the section 7 store permission and trademark sentence in [`AnAIOdyssey/LICENSE`](AnAIOdyssey/LICENSE). The same permission is repeated in [`AnAIOdyssey/LICENSE.appstore`](AnAIOdyssey/LICENSE.appstore). |
| `AIConnect/` (AIConnect and AIConnectUI) | MIT, Copyright (c) 2026 Mark Hanson. [`AIConnect/LICENSE`](AIConnect/LICENSE). |
| `AIConnect/AIModelOptions/` | MIT, same existing copyright line. [`AIConnect/AIModelOptions/LICENSE`](AIConnect/AIModelOptions/LICENSE). |
| `AIConnectVoice/` | MIT, Copyright (c) 2026 Mark Hanson. [`AIConnectVoice/LICENSE`](AIConnectVoice/LICENSE). Terms and attribution unchanged. |
| Odysseus text adapted at commit `e5c99a5e` | MIT, Copyright (c) 2025 Odysseus Contributors. [`AnAIOdyssey/ACKNOWLEDGMENTS.md`](AnAIOdyssey/ACKNOWLEDGMENTS.md). |
| Other Swift packages | The license in [`AnAIOdyssey/THIRD_PARTY_NOTICES.md`](AnAIOdyssey/THIRD_PARTY_NOTICES.md). |

The names do not match. The app license and `AppBranding.companyName` say Grey Matter Ideations. The MIT files say Mark Hanson. These docs keep each line as written. They do not pick a new owner.

## Build

These are the commands the staged manifests and READMEs already describe. This license update did not run them. Nothing here is a verified standalone build.

Requirements written in the tree: macOS 14 and iOS 17 (`project.yml` and the package manifests). The app README says Xcode 16 or later. The AIConnect and AIConnectVoice READMEs say Xcode 26 or later, tested with Xcode 27.2. Those Xcode sentences were not re-checked. [XcodeGen](https://github.com/yonaskolb/XcodeGen) is required to regenerate the Xcode projects. Resolving the app needs network access for `mlx-swift-lm` and its public Git dependencies. AIConnect, AIModelOptions, and AIConnectVoice manifests depend only on each other by relative path.

App, from the repository root:

```bash
cd AnAIOdyssey
xcodegen generate
open AnAIOdyssey.xcodeproj
```

`AnAIOdyssey/project.yml` names the scheme `AnAIOdyssey`, sets `MARKETING_VERSION` to `0.5` and `CURRENT_PROJECT_VERSION` to `47`, and sets `CODE_SIGN_STYLE` to Automatic and `CODE_SIGN_IDENTITY` to `Apple Development`. `AnAIOdyssey/Config/Signing.xcconfig` sets `BUNDLE_ID_PREFIX` to `com.example`, leaves `DEVELOPMENT_TEAM` empty, and sets `PROJECT_HOMEPAGE_URL` to a placeholder `https://example.com/an-ai-odyssey`. Device or store signing uses `Config/Local.xcconfig.example` copied to `Config/Local.xcconfig`. Signing files were not changed.

Further app commands, including `./Scripts/step1_verify.sh`, `step2_verify.sh`, `step3_verify.sh`, `verify_app.sh`, and the `xcodebuild` lines, are in [`AnAIOdyssey/README.md`](AnAIOdyssey/README.md). Those scripts are in `AnAIOdyssey/Scripts/`. They were not run.

Package commands, from the repository root:

```bash
(cd AIConnect/AIModelOptions && swift test)
(cd AIConnect/AIConnect && swift test)
(cd AIConnect && xcodegen generate)
(cd AIConnectVoice && swift test)
(cd AIConnectVoice && xcodegen generate)
```

The Xcode destinations named in the package READMEs (`iPhone 18 Pro`, and the app README's `iPad (A16),OS=26.5`) are the destinations those files already name. They were not run.

## Dependency pins in this copy

Two different lockfiles are in the staged app. Notices follow the Xcode workspace lock, not the per-package locks.

`AnAIOdyssey/AnAIOdyssey.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, which is what `AnAIOdyssey/THIRD_PARTY_NOTICES.md` lists:

| Package | Version |
|---|---|
| eventsource | 1.5.1 |
| mlx-swift | 0.31.6 |
| mlx-swift-lm | 2.31.3 |
| swift-argument-parser | 1.8.2 |
| swift-asn1 | 1.7.2 |
| swift-collections | 1.6.0 |
| swift-crypto | 4.5.2 |
| swift-huggingface | 0.10.0 |
| swift-jinja | 2.5.0 |
| swift-numerics | 1.1.1 |
| swift-transformers | 1.2.1 |
| yyjson | 0.12.0 |

`AnAIOdyssey/Packages/AnAIOdysseyAI/Package.resolved` (the Mail and UI copies match it) pins eventsource 1.4.1, mlx-swift 0.31.4, swift-asn1 1.7.1, swift-crypto 4.5.0, swift-huggingface 0.9.0, swift-jinja 2.3.6, and also swift-atomics 1.3.0, swift-nio 2.101.0, and swift-system 1.7.2. It does not pin swift-argument-parser. mlx-swift-lm 2.31.3, swift-collections 1.6.0, swift-numerics 1.1.1, swift-transformers 1.2.1, and yyjson 0.12.0 match the workspace lock.

`swift test` inside `AnAIOdysseyAI` can resolve from the package lock. `xcodebuild` of the app scheme uses the workspace lock. This docs update does not rewrite either lock or `THIRD_PARTY_NOTICES.md`.

Odysseus attribution stays at commit `e5c99a5e` under that commit's MIT license. The acknowledgments file records that later Odysseus `main` moved to AGPL-3.0 and that nothing after `e5c99a5e` is used.

## Limits

- No compile and no test was run for this documentation change.
- `AnAIOdyssey/ThirdPartyNotices/anaiodyssey-LICENSE.txt` and `anaiodyssey-LICENSE.appstore.txt` in this update are copies of the replacement license files, because `ThirdPartyNoticesTests.testBundledCopiesMatchTheRepositoryLicenses` compares them. `ThirdPartyNotices/manifest.json` and `THIRD_PARTY_NOTICES.md` were not regenerated.
- `ThirdPartyNoticesTests.testAppLicenseIsAGPLWithTheAppStorePermission` looks for the exact phrase `As additional permission under section 7`. The live permission says `As an additional permission under section 7`. Applying the live wording makes that assertion fail. The test was not edited.
- `AIConnect/AIConnect/Package.swift` still says the voice target lives in a separate folder pending a licensing decision. AIConnectVoice is in this tree and its MIT license is unchanged. That source comment was not edited.
- The app package manifests still carry `SPDX-License-Identifier: AGPL-3.0-or-later` and a comment pointing at `LICENSE.appstore`. Those comments were not edited.
- The in-app acknowledgements bundle will keep showing the old draft app license until those two notice files from this update are copied into place. Other notice files were left as staged.
- There is no contributor license agreement in this tree. The app is AGPL. The libraries are MIT. A change to an AGPL file is AGPL. A change that stays inside an MIT package is MIT. Combining them into the app binary does not rewrite the MIT files, and the store permission in the app license does not license third-party code or the name and icon. The operative sentences are in `AnAIOdyssey/LICENSE`.
- This repository has no commits and no tags. The live trademark paragraph that mentions tagged source is quoted in the app README as existing wording. It is not a claim that a tag exists here yet.
