# Changelog

All notable changes to **mob_speech** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

## 0.1.0 - 2026-10-03

Initial release (MOB-380, MOB-21). Speech-to-text only; text-to-speech stays in mob core as `Mob.Speech`.

- `MobSpeech.listen/2`, `stop/1`, `cancel/1`, `available?/1`, `permissions/1`.
- Events: `{:speech, :state, :listening | :processing | :idle}`, `{:speech, :partial, text}`, `{:speech, :final, text}`, `{:speech, :error, reason}`. Exactly one idle follows a final or an error.
- Last-partial fallback for empty finals and for `:no_speech` after partials. A stop watchdog (`stop_timeout_ms`, default 2000) handles recognisers that never report back after stop.
- The `:speech` permission capability: Android `RECORD_AUDIO`; iOS speech-recognition authorisation plus the microphone.
- Pluggable engines (`MobSpeech.Engine`): `:platform` (Android `SpeechRecognizer`, iOS `SFSpeechRecognizer` + `AVAudioEngine`), and the scripted `MobSpeech.Engine.Fake` for tests and agents.
- Error reasons normalised in `MobSpeech.Reason`, including `:service_permission` (the Android recognition service itself lacks the microphone) and `:language` (missing language pack).
- `MobSpeech.DemoScreen` at `/mob_speech/demo`.
