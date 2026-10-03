defmodule MobSpeech.Reason do
  @moduledoc """
  The one place raw recogniser failures become `{:speech, :error, reason}`
  atoms. Native code never decides a reason: it forwards the platform's raw
  code and this pure module maps it, so the table is unit-tested on the host.

  Raw shapes an engine may send as the third element of `{:speech, :error, raw}`:

    * a public reason atom (or its string form) — passed through;
    * `{:android, code, app_has_mic}` — a `SpeechRecognizer.ERROR_*` code plus
      whether the app held `RECORD_AUDIO` when it happened. Negative codes are
      the bridge's own pre-checks: `-1` app lacks `RECORD_AUDIO`, `-2` no
      recognition service, `-3` no Activity/Context yet;
    * `{:ios, domain, code}` — an `NSError` domain + code from
      `SFSpeechRecognizer` / `AVAudioEngine`;
    * anything else becomes `{:unknown, raw}`.

  `:cancelled` is internal: the recogniser aborted (a newer session preempted
  it, or iOS reported its own cancellation). The session turns it into a bare
  `{:speech, :state, :idle}`; screens never see it as an error.
  """

  @public [
    :no_speech,
    :language,
    :permission,
    :service_permission,
    :network,
    :audio,
    :busy,
    :client,
    :server,
    :unavailable,
    :too_many_requests
  ]

  @typedoc "A reason a screen can receive in `{:speech, :error, reason}`."
  @type t ::
          :no_speech
          | :language
          | :permission
          | :service_permission
          | :network
          | :audio
          | :busy
          | :client
          | :server
          | :unavailable
          | :too_many_requests
          | {:unknown, term()}

  @doc "Every reason atom a screen can receive (besides `{:unknown, code}`)."
  @spec public() :: [atom()]
  def public, do: @public

  @doc """
  Map a raw engine failure to a public reason (or `:cancelled`, see moduledoc).

      iex> MobSpeech.Reason.normalize({:android, 13, true})
      :language

      iex> MobSpeech.Reason.normalize({:android, 9, true})
      :service_permission

      iex> MobSpeech.Reason.normalize({:android, 9, false})
      :permission

      iex> MobSpeech.Reason.normalize({:android, 99, true})
      {:unknown, 99}
  """
  @spec normalize(term()) :: t() | :cancelled
  def normalize(reason) when reason in @public or reason == :cancelled, do: reason

  def normalize(reason) when is_binary(reason) do
    case Enum.find(@public, &(Atom.to_string(&1) == reason)) do
      nil -> {:unknown, reason}
      atom -> atom
    end
  end

  def normalize({:android, code, app_has_mic}) when is_integer(code),
    do: android(code, app_has_mic == true)

  def normalize({:ios, domain, code}) when is_binary(domain) and is_integer(code),
    do: ios(domain, code)

  def normalize(other), do: {:unknown, other}

  # android.speech.SpeechRecognizer.ERROR_* (API 34 constants).
  defp android(-1, _), do: :permission
  defp android(-2, _), do: :unavailable
  defp android(-3, _), do: :client
  # ERROR_NETWORK_TIMEOUT, ERROR_NETWORK
  defp android(code, _) when code in [1, 2], do: :network
  # ERROR_AUDIO
  defp android(3, _), do: :audio
  # ERROR_SERVER, ERROR_SERVER_DISCONNECTED
  defp android(code, _) when code in [4, 11], do: :server
  # ERROR_CLIENT
  defp android(5, _), do: :client
  # ERROR_SPEECH_TIMEOUT, ERROR_NO_MATCH
  defp android(code, _) when code in [6, 7], do: :no_speech
  # ERROR_RECOGNIZER_BUSY
  defp android(8, _), do: :busy
  # ERROR_INSUFFICIENT_PERMISSIONS. Holding RECORD_AUDIO and still refused
  # means the recognition SERVICE (the Google app) lacks the microphone itself.
  defp android(9, true), do: :service_permission
  defp android(9, false), do: :permission
  # ERROR_TOO_MANY_REQUESTS
  defp android(10, _), do: :too_many_requests
  # ERROR_LANGUAGE_NOT_SUPPORTED, ERROR_LANGUAGE_UNAVAILABLE (no language pack)
  defp android(code, _) when code in [12, 13], do: :language
  defp android(code, _), do: {:unknown, code}

  # SFSpeechErrorDomain (iOS 17+, SFErrors.h)
  defp ios("SFSpeechErrorDomain", 1), do: :server
  defp ios("SFSpeechErrorDomain", 2), do: :audio
  defp ios("SFSpeechErrorDomain", 12), do: :no_speech
  # The assistant/dictation service. 1110 "No speech detected"; 203 "Retry"
  # is what it reports when nothing intelligible was heard; 216 / 301 follow a
  # cancelled task; 1700 is its "not authorized" refusal.
  defp ios("kAFAssistantErrorDomain", code) when code in [203, 1110], do: :no_speech
  defp ios("kAFAssistantErrorDomain", code) when code in [216, 301], do: :cancelled
  defp ios("kAFAssistantErrorDomain", 1700), do: :permission
  defp ios("kAFAssistantErrorDomain", 1101), do: :server
  # On-device recogniser: 201 Siri & Dictation disabled, 300 no model for the
  # locale, 301 cancelled.
  defp ios("kLSRErrorDomain", 201), do: :unavailable
  defp ios("kLSRErrorDomain", 300), do: :language
  defp ios("kLSRErrorDomain", 301), do: :cancelled
  defp ios("NSURLErrorDomain", _), do: :network
  defp ios("NSOSStatusErrorDomain", _), do: :audio
  defp ios("com.apple.coreaudio.avfaudio", _), do: :audio
  defp ios(domain, code), do: {:unknown, "#{domain}:#{code}"}
end
