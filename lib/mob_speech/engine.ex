defmodule MobSpeech.Engine do
  @moduledoc """
  Implement these callbacks to plug any recogniser into `MobSpeech` — the OS
  one, an offline model, a cloud API, or a script.

  Shipped engines: `MobSpeech.Engine.Platform` (Android `SpeechRecognizer`,
  iOS `SFSpeechRecognizer`; `engine: :platform`, the default) and
  `MobSpeech.Engine.Fake` (scripted, for tests and agents). Other packages add
  their own (e.g. an offline whisper.cpp engine) and are selected with
  `MobSpeech.listen(socket, engine: TheirEngine)`.

  ## The session process

  Every `MobSpeech.listen/2` starts one short-lived **session** process. It
  calls the engine's `start/2`, `stop/1` and `cancel/1` from inside itself, so
  in every callback `pid == self()` is the session. The engine reports by
  sending messages to that pid, from any process it likes:

      {:speech, :state, :listening}   # recogniser is capturing audio
      {:speech, :partial, text}       # interim transcript (binary)
      {:speech, :final, text}         # finished transcript (binary)
      {:speech, :error, reason}       # failed; see MobSpeech.Reason for raw shapes
      {:speech, :state, :idle}        # ended with nothing to report (aborted)

  The session owns the guarantees screens rely on, so engines don't
  re-implement them:

    * `:processing` is emitted when the app calls `MobSpeech.stop/1`, never
      on the recogniser's own end-of-speech (anything else the engine sends
      as `{:speech, :state, _}` besides `:listening`/`:idle` is ignored);
    * an empty final, or a `:no_speech` error after partials were heard,
      becomes `{:speech, :final, last_partial}`;
    * after `stop/1`, if no final/error arrives within `stop_timeout_ms`, the
      session cancels the engine and delivers the last partial (or
      `:no_speech`);
    * exactly one `{:speech, :state, :idle}` follows a final or an error;
      later engine messages to the finished session are dropped;
    * error reasons are normalised by `MobSpeech.Reason.normalize/1`.

  `start/2` receives the validated options — `:language` (BCP-47 binary, or
  `nil` for the device locale), `:prefer_offline`, `:partial_results`,
  `:stop_timeout_ms` — plus every option `MobSpeech` doesn't know, untouched.
  """

  @doc """
  Begin recognising; deliver events to `pid`. Return `{:error, reason}` to fail
  synchronously — the session turns it into `{:speech, :error, reason}` + idle.
  """
  @callback start(pid(), keyword()) :: :ok | {:error, term()}

  @doc "Stop capturing and finish: deliver a final (or an error) to `pid` later."
  @callback stop(pid()) :: :ok

  @doc "Abort `pid`'s recognition. Nothing more needs to be delivered."
  @callback cancel(pid()) :: :ok

  @doc "Whether this engine can run on this device right now."
  @callback available?() :: boolean()

  @doc "`Mob.Permissions` capabilities the app must hold before `start/2`."
  @callback permissions() :: [atom()]

  @doc """
  Default stop watchdog in ms when the caller passes no `:stop_timeout_ms`.
  Engines that transcribe only after `stop/1` (e.g. whisper) return a longer
  budget. Without this callback the default is #{2_000} ms.
  """
  @callback stop_timeout_ms() :: pos_integer()

  @optional_callbacks stop_timeout_ms: 0
end
