# AGENTS.md — orientation for AI agents working on mob_speech

You're in **mob_speech**, a Mob plugin for speech-to-text. A screen calls `MobSpeech.listen/2` and gets `{:speech, :state | :partial | :final | :error, _}` messages in `handle_info/2`. The default engine is the OS recogniser (Android `SpeechRecognizer`, iOS `SFSpeechRecognizer`). Engines are pluggable through the `MobSpeech.Engine` behaviour. Text-to-speech is **not** here: it stays in mob core as `Mob.Speech`.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view: the plugin manifest schema, the permission registry (`mob_register_permission_handler` / `MobPermissionProvider`), and how to drive a running app.

> **Keep this file current.** If you change the event contract, the engine behaviour, an option, or hit a gotcha, fix it here in the same commit.

## The shape, in one paragraph

`MobSpeech.listen(socket, opts)` validates the options (`MobSpeech.validate_opts!/1`) and spawns a **session** process (`MobSpeech.Session`). The session monitors the screen and calls the engine's callbacks from inside itself, so `pid == self()`. The engine sends it **raw** events, and the session forwards the public ones to the screen. The session's pure `handle/2` state machine owns every guarantee in the contract: `:processing` only on `stop/1`, the last-partial fallback (empty final, or `:no_speech` after partials), the stop watchdog (`stop_timeout_ms`), exactly one idle, cancel with no final, and engine cancellation when the screen dies. Reason codes are mapped in ONE pure place, `MobSpeech.Reason`. Native code decides nothing; it forwards raw codes. See `decisions/2026-10-03-session-owns-the-contract.md`.

## The load-bearing invariants

1. **The event contract is identical for every engine.** If you change a guarantee, change it in `MobSpeech.Session.handle/2`, its tests, the `MobSpeech` moduledoc and the README in the same commit. Engines (here and in other packages, e.g. mob_whisper) rely on the session doing it.
2. **The engine behaviour is a public API.** Other packages implement `MobSpeech.Engine`; an optional `stop_timeout_ms/0` callback exists for engines that transcribe after stop. Changing a callback is a breaking change for them.
3. **Native forwards raw, Elixir maps.** Android sends `{:speech, :error, {:android, code, app_has_mic}}`; iOS sends `{:ios, domain, code}` or a tag binary (`"permission"`, `"language"`, `"unavailable"`, `"audio"`). Add a mapping in `MobSpeech.Reason` plus a test in `test/mob_speech/reason_test.exs`, never in Kotlin or ObjC.
4. **Stale isolation is by pid.** Each `listen` is a new session pid. The native `speech_stop/1` and `speech_cancel/1` act only if that pid is the recognition running natively, and the native listeners drop events for an inactive pid. A new `speech_start/4` preempts the running one, which gets a bare idle.
5. **The NIF stub and both NIF tables move together.** `src/mob_speech_nif.erl`, the ObjC `nif_funcs`, the zig `nif_funcs` and the Kotlin `@JvmStatic` methods are one seam. `test/mob_speech_test.exs` checks names and arities across all four.

## Anatomy

* `lib/mob_speech.ex`: public API (`listen/2`, `stop/1`, `cancel/1`, `available?/1`, `permissions/1`, `validate_opts!/1`). The moduledoc is the canonical event contract.
* `lib/mob_speech/session.ex`: session process + pure state machine.
* `lib/mob_speech/reason.ex`: raw → public reason mapping.
* `lib/mob_speech/engine.ex`: behaviour. `engine/platform.ex` calls `:mob_speech_nif`; `engine/fake.ex` is scripted (tests, agents, demo).
* `lib/mob_speech/demo_screen.ex`: sample screen at `/mob_speech/demo` (Listen / Stop / Cancel / Fake).
* `src/mob_speech_nif.erl`: NIF stub with a tolerant `on_load`, so a host build returns `nif_not_loaded` instead of crashing. The session turns that into `:unavailable`.
* `priv/mob_plugin.exs`: the manifest. Declares the `:speech` capability, `RECORD_AUDIO`, `NSSpeechRecognitionUsageDescription`, the `Speech` and `AVFoundation` frameworks, and two `host_requirements`.
* `priv/native/android/MobSpeechBridge.kt`: main-thread `SpeechRecognizer`. Implements `MobPermissionProvider` (`speech` → `RECORD_AUDIO`).
* `priv/native/jni/mob_speech_nif.zig`: JNI glue. Text crosses as UTF-8 `byte[]`, not as a modified-UTF-8 `jstring`.
* `priv/native/ios/mob_speech_nif.m`: `SFSpeechRecognizer` plus an `AVAudioEngine` tap, audio-session setup and teardown, and the `:speech` permission handler (speech authorisation, then the microphone).

## Hard-won platform lessons (Moto G 2021, Android 11, Google recogniser)

* The Google app needs RECORD_AUDIO **itself**. Otherwise you get `ERROR_INSUFFICIENT_PERMISSIONS` even though the app holds it, and `Reason` reports `:service_permission`.
* Errors 12 and 13 mean the on-device pack for the locale is missing (`:language`). Never default `EXTRA_PREFER_OFFLINE` to true.
* The recogniser can stream partials and then send an EMPTY final, `ERROR_NO_MATCH` or `ERROR_SPEECH_TIMEOUT`. The session then delivers the last partial.
* The recogniser endpoints by itself while the finger is still down, and silence-length extras are often ignored. Final + idle can arrive before `stop/1`.
* After `stopListening` the Google service can take 10–20 s to report. The session's stop watchdog (default 2000 ms) cancels it and delivers the last partial.
* Some devices return empty results entirely (no language pack). That is not fixable here; it is why offline engines exist.

## Pre-commit checklist

```bash
mix format
mix credo --strict                  # includes ExSlop + jump_credo_checks
mix compile --warnings-as-errors
mix test
zig fmt priv/native/jni/*.zig
xcrun clang-format -i priv/native/ios/*.m
```

`mix setup` activates `.githooks/pre-push`, which runs format, credo and compile on every push, and the full suite when `mix.exs` changes.

Native code isn't exercised by `mix test`. Before committing a native change, `mix mob.deploy --native` a host app (a `mix mob.new` app with `{:mob_speech, path: ...}`, `:mob_speech` in `config :mob, :plugins` and in `:acknowledge_unsafe_plugins`), open `/mob_speech/demo`, and check that permission → Listen → Stop gives a final + idle, and that Cancel gives idle with no final. Lease the device first (`agent-lease`, see `~/AGENTS.md`).

### Tests are part of the change

The bar: **would this test fail if the change were reverted?** Contract changes need a `Session.handle/2` test; reason changes need a `Reason` test; manifest changes need a manifest test.

### Decision log

Non-obvious calls go in `decisions/YYYY-MM-DD-slug.md`. Append; never edit a landed one. If a record no longer holds, correct it in place with a note saying what was wrong.

### Review

Codex is the default adversarial reviewer (`codex exec -s read-only`, see `~/AGENTS.md`); use a reviewer subagent if Codex is unavailable. Things to look for here:

* **Contract regressions:** a second idle, an idle missing after an error, `:processing` sent without a stop, a final after cancel.
* **Stale sessions:** a native stop or cancel that ignores the pid, or a listener that delivers for an inactive pid.
* **Engines that raise:** the session must still deliver error + idle.

## Release

`version:` in `mix.exs` on master triggers `.github/workflows/release.yml`: tag, GitHub release, signing with the shared first-party key (`MOB_PLUGIN_SIGN_KEY`, checked against `priv/mob_plugin.pub`), then Hex publish (`HEX_API_KEY`). Bump only when the latest `tests` run on master is green, then confirm with `mix hex.info mob_speech`. Canonical flow: [`~/code/mob/RELEASE.md`](../mob/RELEASE.md).
