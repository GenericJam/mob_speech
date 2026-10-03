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
      another is active cancels the old one: its screen gets a bare
      `{:speech, :state, :idle}`.
    * `stop/1` and `cancel/1` act only on the session that is currently
      running natively, so a stale call can't end a newer recognition.
  """

  @behaviour MobSpeech.Engine

  @impl true
  def start(pid, opts) do
    :mob_speech_nif.speech_start(
      pid,
      Keyword.get(opts, :language) || "",
      Keyword.get(opts, :prefer_offline, false),
      Keyword.get(opts, :partial_results, true)
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
