# The session process owns the event contract, not native code

- Date: 2026-10-03
- Status: accepted
- Issues: MOB-380 (hold-to-talk, test injection), MOB-21 (speech-to-text)

## Context

Hold-to-talk dictation was first built inside the Operator app
(`OperatorDictation.kt`). Each rule it learned on a Moto G 2021 was coded in
Kotlin next to the recogniser:

- keep the last partial when the final is empty or `NO_MATCH`/`SPEECH_TIMEOUT`
  follows partials;
- don't emit `processing` when the recogniser endpoints while the finger is
  still down;
- give `stopListening` 2 s, then cancel and use what was heard;
- don't let a stale watchdog end a later session.

mob_speech has to deliver the same contract on Android and iOS, and through
third-party engines too (an offline whisper.cpp engine is being built against
it). If each native engine re-implemented those rules, they would drift, and
none of the rules could be tested on the host.

## Decision

- `MobSpeech.listen/2` spawns a per-listen **session** process. It calls the
  engine's callbacks from inside itself and receives the engine's raw events
  (`{:speech, ...}`, with raw error codes).
- A pure state machine, `MobSpeech.Session.handle/2`, applies every rule: the
  last-partial fallback, the stop watchdog (`stop_timeout_ms`, default 2000,
  or the engine's optional `stop_timeout_ms/0`), `:processing` only on stop,
  exactly one idle, cancel without a final, and cancelling the engine when
  the screen dies.
- One pure module, `MobSpeech.Reason`, maps raw codes. Android sends
  `{:android, code, app_has_mic}`; iOS sends `{:ios, domain, code}` or a tag.
- Stale isolation uses the session pid: native `stop`/`cancel` take the pid
  and act only on the matching running recognition.

The brief asked for the last-partial fallback "in native code". It lives in
the plugin's Elixir layer instead. The screen still never sees an empty
final, and the rule is now unit-tested and shared by every engine.

## Consequences

- Native code is thin and has no policy. Adding a mapping or changing a rule
  is an Elixir change with a host test.
- A recognition costs one extra short-lived process, which ends at its idle.
- `listen/2` always returns the socket. Failures, including a missing
  permission and a host build without the NIF, arrive as error + idle.
- `MobSpeech.Engine.Fake` goes through the same session, so scripted tests
  exercise the real contract.
