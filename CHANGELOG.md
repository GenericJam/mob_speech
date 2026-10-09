# Changelog

All notable changes to **mob_speech** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **On-device self-test** (MOB-418). `MobSpeech.SelfTest` implements
  `Mob.Plugin.SelfTest` and is declared in the manifest as `selftest:`. It
  calls the read-only `speech_available/0` NIF (no microphone, no session,
  no prompt): `true` passes; Android `false` (the bridge answered but no
  `RecognitionService` is visible, e.g. redroid, or a host without the
  Android 11+ `<queries>` entry) and iOS "not authorised" / "no recogniser
  for the locale" / "recogniser off" skip; a bridge that could not answer
  fails. Run it with `mix mob.selftest` from a host app (mob_dev 0.7.17).
  Requires mob 0.9.15; `mob_version` in the manifest is now `~> 0.9`.

### Changed
- **`speech_available/0` says why it is not `true`.** Android answers
  `{:error, :bridge_not_registered | :no_jni_env | :no_activity |
  :bridge_call_failed}` instead of `false` when the Kotlin bridge could not
  answer (`MobSpeechBridge.speech_available()` now returns an `Int` code,
  JNI signature `()I`). iOS answers `{:error, :unsupported_locale}` (no
  recogniser for the device locale) or `{:error, :not_authorized}` instead
  of `false`. `MobSpeech.available?/1` is unchanged: anything but `true` is
  `false`.

## 0.1.0 - 2026-10-03

Initial release (MOB-380, MOB-21). Speech-to-text only; text-to-speech stays in mob core as `Mob.Speech`.

- `MobSpeech.listen/2`, `stop/1`, `cancel/1`, `available?/1`, `permissions/1`.
- Events: `{:speech, :state, :listening | :processing | :idle}`, `{:speech, :partial, text}`, `{:speech, :final, text}`, `{:speech, :error, reason}`. Exactly one idle follows a final or an error.
- Last-partial fallback for empty finals and for `:no_speech` after partials. A stop watchdog (`stop_timeout_ms`, default 2000) handles recognisers that never report back after stop.
- The `:speech` permission capability: Android `RECORD_AUDIO`; iOS speech-recognition authorisation plus the microphone.
- Pluggable engines (`MobSpeech.Engine`): `:platform` (Android `SpeechRecognizer`, iOS `SFSpeechRecognizer` + `AVAudioEngine`), and the scripted `MobSpeech.Engine.Fake` for tests and agents.
- Error reasons normalised in `MobSpeech.Reason`, including `:service_permission` (the Android recognition service itself lacks the microphone) and `:language` (missing language pack).
- `MobSpeech.DemoScreen` at `/mob_speech/demo`.
