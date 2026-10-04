defmodule MobSpeech.Engine.Platform do
  @moduledoc """
  The OS recogniser: Android `android.speech.SpeechRecognizer`, iOS
  `SFSpeechRecognizer` fed by an `AVAudioEngine` input tap. Selected by
  `engine: :platform` (the default).

  Needs the `:speech` permission capability (this plugin registers it):
  Android `RECORD_AUDIO`; iOS speech-recognition authorisation **and** the
  microphone record permission. Without it `listen` delivers
  `{:speech, :error, :permission}` + idle.

  Platform behaviour behind the shared session contract:

    * Android runs the recogniser on the main thread. Each session gets a
      fresh `SpeechRecognizer`, destroyed when the session ends (final, error,
      cancel, or preemption): reusing one straight after `cancel()` made the
      next start fail with `ERROR_CLIENT`.
      `EXTRA_PARTIAL_RESULTS`, `EXTRA_LANGUAGE` and `EXTRA_PREFER_OFFLINE`
      follow the options; offline is never preferred by default because a
      missing on-device pack fails at once with `:language`.
    * iOS sets the shared `AVAudioSession` to play-and-record while
      listening and deactivates it afterwards; `requiresOnDeviceRecognition`
      is set only for `prefer_offline: true` on a recogniser that supports it.
    * Only one platform recognition runs at a time. Starting a new one while
      another is active cancels the old one: its screen gets
      `{:speech, :state, :idle}` (or, if it had already called `stop/1`, the
      last partial as its final).
    * `stop/1` and `cancel/1` act only on the session that is currently
      running natively, so a stale call can't end a newer recognition.

  Engine option (pass it to `MobSpeech.listen/2`):

    * `:silence_ms` — Android only: how long a pause may last before the
      recogniser ends the utterance by itself
      (`EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS` and
      `..._POSSIBLY_COMPLETE_...`). Default `10_000`, so a pause during
      hold-to-talk doesn't end the recognition; `0` keeps the recogniser's
      own default. Some recogniser versions ignore it. An invalid value fails
      the listen with `{:speech, :error, :client}` (and a logged
      `ArgumentError`).
  """

  @behaviour MobSpeech.Engine

  @default_silence_ms 10_000

  @impl true
  def start(pid, opts) do
    silence_ms = Keyword.get(opts, :silence_ms, @default_silence_ms)

    unless is_integer(silence_ms) and silence_ms in 0..0x7FFFFFFF do
      raise ArgumentError,
            ":silence_ms must be a non-negative integer, got: #{inspect(silence_ms)}"
    end

    :mob_speech_nif.speech_start(
      pid,
      Keyword.get(opts, :language) || "",
      Keyword.get(opts, :prefer_offline, false),
      Keyword.get(opts, :partial_results, true),
      silence_ms
    )
  end

  @impl true
  def stop(pid), do: :mob_speech_nif.speech_stop(pid)

  @impl true
  def cancel(pid), do: :mob_speech_nif.speech_cancel(pid)

  @impl true
  def available? do
    :mob_speech_nif.speech_available() == true
  rescue
    # No native NIF linked (a host build): nothing to recognise with.
    e in ErlangError ->
      if e.original == :nif_not_loaded, do: false, else: reraise(e, __STACKTRACE__)
  end

  @impl true
  def permissions, do: [:speech]
end
