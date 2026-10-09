%% mob_speech_nif — Erlang NIF module for the platform speech-to-text engine.
%%
%% iOS: priv/native/ios/mob_speech_nif.m (Objective-C, SFSpeechRecognizer +
%% AVAudioEngine). Android: priv/native/jni/mob_speech_nif.zig (SpeechRecognizer
%% via the io.mob.speech.MobSpeechBridge Kotlin bridge). Both register this
%% module via ERL_NIF_INIT and are statically linked into the host binary on
%% device. On a host dev build neither is linked, so on_load tolerates the
%% failure and the NIFs fall back to nif_error until the native merge links one.
%%
%% Every call takes the session pid explicitly: speech_start/5 routes the
%% recogniser's raw events to it ({speech, ...} messages, see
%% MobSpeech.Engine), and speech_stop/1 / speech_cancel/1 act only when that
%% pid is the recognition currently running natively.
-module(mob_speech_nif).
-export([speech_start/5, speech_stop/1, speech_cancel/1, speech_available/0]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_speech_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

%% Pid, Language (BCP-47 binary, <<>> = device locale), PreferOffline,
%% PartialResults, SilenceMs (Android end-of-utterance silence; 0 = default).
speech_start(_Pid, _Language, _PreferOffline, _PartialResults, _SilenceMs) ->
    erlang:nif_error(nif_not_loaded).

speech_stop(_Pid) ->
    erlang:nif_error(nif_not_loaded).

speech_cancel(_Pid) ->
    erlang:nif_error(nif_not_loaded).

%% true | false | {error, Why}. false: no recogniser is available (Android: no
%% RecognitionService visible to the app; iOS: authorised, but Siri/dictation is
%% off or there is no network). {error, Why} says why the native side could not
%% answer yes: Android bridge_not_registered | no_jni_env | no_activity |
%% bridge_call_failed; iOS unsupported_locale | not_authorized.
%% MobSpeech.available?/0 is true only for true; MobSpeech.SelfTest reads the rest.
speech_available() ->
    erlang:nif_error(nif_not_loaded).
