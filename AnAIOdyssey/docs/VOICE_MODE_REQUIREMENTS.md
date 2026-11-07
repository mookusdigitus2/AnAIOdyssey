# An AI Odyssey — Voice Mode Requirements

Approved Oct 20, 2026 (REQ-15 added Oct 21, 2026). These describe what voice mode must do. Any rewrite has to meet all of them.

Each requirement has an ID (REQ-01…). Every requirement has at least one automated test tagged with its ID in `AnAIOdysseyAITests`, which the AnAIOdyssey scheme's test action runs (`xcodebuild test`). `VoiceRequirementsCoverageTests` and `Scripts/check_voice_requirements_coverage.sh` fail when a requirement has no tagged test. What can't be unit-tested is listed under Manual device checks.

## Recognition
1. **REQ-01 One recognizer:** Apple's SFSpeechRecognizer is the only speech-to-text path, running on-device where supported. There's no server or ElevenLabs speech-to-text. ElevenLabs is used for speech output only.
2. **REQ-02 One owner:** one component owns the audio engine, the player and the recognizer. There's only ever one current recognition pass, and results from any older pass are ignored.

## Submitting a turn
3. **REQ-03 One submit point:** every turn, spoken or typed, goes through a single submit function.
4. **REQ-04 One debounce:** a spoken turn is submitted only after 1.5 s of silence (no new words and no voice). Nothing else submits a spoken turn.
5. **REQ-05 Exactly once:** each utterance gets an ID and is submitted at most once. Old text is never re-delivered after a restart, an error or a route change.
6. **REQ-06 One turn in flight:** a new turn cancels any running reply (both generation and speech) before it starts. Two replies never run at once.

## Speaking and barge-in
7. **REQ-07 Turn-taking:** nothing is submitted while the app is thinking or speaking unless the user barges in. Listening resumes when playback actually finishes.
8. **REQ-08 Barge-in never submits.** Speaking over the reply:
   - pauses audio playback without discarding the rest of the reply,
   - shows the continue prompt,
   - goes into listening mode.
   What the user says is then submitted by the normal 1.5 s silence debounce (req. 4).
9. **REQ-09 Continue prompt:** the answer goes through that same submit path. Yes resumes the paused reply. No ends it. Anything else becomes a new turn and drops the paused reply. All of this is decided in one function.
10. **REQ-10 Echo:** the app's own voice must never be taken as user speech. This relies on the audio engine's echo cancellation plus checking whether audio is playing, not on matching transcript text. Where echo cancellation isn't available (for example Bluetooth hands-free), the app doesn't listen during playback and the user taps to interrupt.

## Reliability
11. **REQ-11 Stop and Back** act instantly, are safe to press repeatedly, and no late callback acts after them.
12. **REQ-12 Recovery:** an interruption, route change or recognizer error starts a fresh recognition pass with a new ID and doesn't lose or replay the turn.
13. **REQ-13 Logging:** every state change logs the utterance ID and pass ID, so a duplicate can be traced.
14. **REQ-14 Tests:** automated tests prove one submit per utterance (including late and stale recognizer callbacks), that barge-in doesn't submit, and that two quick turns produce only one reply.

## Echo
15. **REQ-15 Never hears itself:** the app must never hear or transcribe its own reply, and must never barge in on it. To meet that:
   - voice processing (AEC) stays on for the recognizer's input for the whole session, through engine rebuilds and route changes,
   - all reply and TTS audio and the cues play through that same voice-processed engine,
   - the session is playAndRecord in .voiceChat mode,
   - routes without AEC, such as Bluetooth HFP, keep the mic off during playback,
   - no transcript text matching.

   The engine owner verifies this at runtime: at session start and after every engine rebuild or route change (including a route change that needs no rebuild) it checks that voice processing is enabled on the input node, that the player is attached to that same engine, and that the session mode is .voiceChat. A failed check is repaired once (the repair restarts the engine, which drops any reply audio still pending; Replay still has it); if it still fails, the app logs `voice.aec.disabled` with the details, keeps the mic closed during playback, so it can never submit its own reply, and shows that interrupting by voice is off. The failure is logged, not asserted, so Debug device builds keep running. (Bluetooth HFP can't run Apple's voice processing; there the mic is closed during playback instead.)

## Manual device checks
These can't be proven by unit tests. Run them on a device before shipping a voice change.
- **M-15a Acoustic echo (REQ-15):** on the built-in speaker, at normal volume and again at full volume, ask a question that gets a reply of several sentences and stay silent. The reply plays to the end, no "Would you like me to continue?" prompt appears, no new user message is created, and the audio log shows `voice.aec.ok` and no `listen.speechOverReply` or `listen.utterance` while the reply plays. This is the check for a 2-word echo leak: two or more leaked words of the reply would pause it, and those words would then be submitted as the prompt answer (a new turn that drops the reply).
- **M-15b Barge-in (REQ-08, REQ-15):** during a reply, say two or more words and keep talking for a few seconds. The reply pauses, the prompt appears, and your words become the answer: the new user message is exactly what you said, with no words missing right after the pause and no words of the reply mixed in (a leaked reply phrase in the answer is an echo leak and fails this check). Then barge in with "no wait": the prompt stays up and "yes" resumes the reply.
- **M-15c Bluetooth HFP (REQ-10, REQ-15):** in a car or on an HFP headset, a reply is never interrupted by its own audio; tapping interrupts.
