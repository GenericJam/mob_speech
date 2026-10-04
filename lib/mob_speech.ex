defmodule MobSpeech do
  @moduledoc """
  Speech-to-text for Mob screens — a Mob plugin.

  Speech-to-**text** only: text-to-speech stays in mob core as `Mob.Speech`.

  ## Usage

      # 1. Ask once for the engine's permissions (the platform engine needs :speech).
      socket = Enum.reduce(MobSpeech.permissions(), socket, &Mob.Permissions.request(&2, &1))

      # 2. Listen; events arrive in handle_info/2.
      socket = MobSpeech.listen(socket, language: "en-US")

      # 3. Finish (deliver the final) or abort (no final).
      socket = MobSpeech.stop(socket)
      socket = MobSpeech.cancel(socket)

  Hold-to-talk: `listen/2` on press, `stop/1` on release.

  ## Events

  Every event goes to the screen that called `listen/2` (or the `:to` pid):

      {:speech, :state, :listening | :processing | :idle}
      {:speech, :partial, text}
      {:speech, :final, text}
      {:speech, :error, reason}

    * `:listening` once the recogniser is capturing audio.
    * `:processing` when you call `stop/1` (not when the recogniser decides
      speech ended on its own: a held button is still a hold).
    * After a final or an error comes exactly one `{:speech, :state, :idle}`,
      and nothing else for that `listen`. The recogniser may end by itself
      while the user is still holding the button; then final + idle arrive
      before your `stop/1`, which becomes a harmless no-op.
    * `cancel/1` → `{:speech, :state, :idle}`, no final, no error.
    * An empty final, or `:no_speech` after partials were heard, arrives as
      `{:speech, :final, last_partial}`. An empty final with no partials is
      `{:speech, :error, :no_speech}`.
    * After `stop/1` the recogniser gets `:stop_timeout_ms` to answer; then it
      is cancelled and you get the last partial as the final (or
      `:no_speech`).

  Error reasons (`MobSpeech.Reason`): `:no_speech`, `:language` (no model or
  pack for the locale), `:permission` (the app lacks the permission — ask via
  `Mob.Permissions` and listen again), `:service_permission` (Android: the
  app holds `RECORD_AUDIO` but the recognition service, e.g. the Google app,
  has no microphone access itself), `:network`, `:audio`, `:busy`, `:client`,
  `:server`, `:unavailable` (no recogniser on this device), `:too_many_requests`,
  else `{:unknown, code}`.

  A missing permission is reported asynchronously like every other failure:
  `listen/2` always returns the socket, and the screen gets
  `{:speech, :error, :permission}` + idle.

  ## Engines

  `engine: :platform` (default) is the OS recogniser,
  `MobSpeech.Engine.Platform`. `engine: MobSpeech.Engine.Fake` plays a script
  (tests, agents). Any module implementing `MobSpeech.Engine` works.
  """

  alias MobSpeech.{Engine, Session}

  @known_opts [:engine, :to, :language, :prefer_offline, :partial_results, :stop_timeout_ms]

  @doc """
  Start recognising speech. Returns the socket with the session recorded
  under `assigns.mob_speech`, so `stop/1` and `cancel/1` reach it.

  Listening again while this socket already has a session cancels the old one
  first: its target gets its idle before any event of the new session.

  Options:

    * `:language` — BCP-47 tag such as `"en-US"`; default `nil`, the device
      locale.
    * `:prefer_offline` — prefer on-device recognition. Default `false`:
      a device without the offline pack for the language would fail at once
      with `:language`.
    * `:partial_results` — stream `{:speech, :partial, text}`. Default `true`.
    * `:stop_timeout_ms` — how long `stop/1` waits for the final before giving
      up with the last partial. Default: the engine's
      `c:MobSpeech.Engine.stop_timeout_ms/0`, else 2000.
    * `:engine` — `:platform` (default) or a `MobSpeech.Engine` module.
    * `:to` — the pid that receives the events. Default `self()`.

  Other options are passed to the engine untouched. Invalid options raise
  `ArgumentError`.
  """
  @spec listen(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def listen(socket, opts \\ []) do
    {engine, target, engine_opts} = validate_opts!(opts)
    socket = cancel(socket)
    session = Session.start(target, engine, engine_opts)
    Mob.Socket.assign(socket, :mob_speech, %{session: session, engine: engine})
  end

  @doc """
  Stop listening and deliver the final (`:processing`, then final or error,
  then idle). A no-op when nothing is listening or the recognition already
  ended.
  """
  @spec stop(Mob.Socket.t()) :: Mob.Socket.t()
  def stop(socket) do
    with %{session: session} <- socket.assigns[:mob_speech], do: Session.stop(session)
    socket
  end

  @doc """
  Abort listening: `{:speech, :state, :idle}`, no final. A no-op when nothing
  is listening. Returns once the idle has been sent (waiting at most 1 s for
  an engine that is busy in a callback), so it is already in the target's
  mailbox when the target is the caller.
  """
  @spec cancel(Mob.Socket.t()) :: Mob.Socket.t()
  def cancel(socket) do
    case socket.assigns[:mob_speech] do
      %{session: session} ->
        Session.cancel(session)
        Mob.Socket.assign(socket, :mob_speech, nil)

      _ ->
        socket
    end
  end

  @doc """
  Whether `engine` (default `:platform`) can recognise speech on this device.
  `false` on a host build without the native NIF. On iOS the platform
  recogniser reports `false` until speech recognition has been authorised, so
  request `permissions/1` before hiding a mic button over it.
  """
  @spec available?(:platform | module()) :: boolean()
  def available?(engine \\ :platform), do: resolve_engine!(engine).available?()

  @doc """
  The `Mob.Permissions` capabilities `engine` (default `:platform`) needs:
  `[:speech]` for the platform engine.
  """
  @spec permissions(:platform | module()) :: [atom()]
  def permissions(engine \\ :platform), do: resolve_engine!(engine).permissions()

  @doc """
  Validate `listen/2` options (pure). Returns `{engine_module, target_pid,
  engine_opts}`, where `engine_opts` carries the defaults filled in and every
  unknown option untouched. Raises `ArgumentError` on an invalid option.
  """
  @spec validate_opts!(keyword()) :: {module(), pid(), keyword()}
  def validate_opts!(opts) when is_list(opts) do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "options must be a keyword list")

    engine = resolve_engine!(Keyword.get(opts, :engine, :platform))
    target = Keyword.get(opts, :to, self())
    unless is_pid(target), do: raise(ArgumentError, ":to must be a pid, got: #{inspect(target)}")

    known = [
      language: language!(Keyword.get(opts, :language)),
      prefer_offline: boolean!(opts, :prefer_offline, false),
      partial_results: boolean!(opts, :partial_results, true),
      stop_timeout_ms: stop_timeout!(opts, engine)
    ]

    {engine, target, known ++ Keyword.drop(opts, @known_opts)}
  end

  defp resolve_engine!(:platform), do: MobSpeech.Engine.Platform

  defp resolve_engine!(engine) when is_atom(engine) do
    if engine_module?(engine) do
      engine
    else
      raise ArgumentError,
            ":engine must be :platform or a module implementing MobSpeech.Engine, got: " <>
              inspect(engine)
    end
  end

  defp resolve_engine!(engine),
    do: raise(ArgumentError, ":engine must be :platform or a module, got: #{inspect(engine)}")

  defp engine_module?(module) do
    behaviours =
      if Code.ensure_loaded?(module),
        do: module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten(),
        else: []

    Engine in behaviours
  end

  defp language!(nil), do: nil

  defp language!(lang) when is_binary(lang) do
    # BCP-47: a 2-8 letter primary subtag, then alphanumeric subtags of 1-8
    # chars, hyphen-separated ("en", "en-US", "zh-Hant-TW", "sr-Latn"), at
    # most 35 chars (RFC 5646's recommended buffer size; the native layers
    # copy it into a fixed buffer).
    if byte_size(lang) <= 35 and Regex.match?(~r/\A[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*\z/, lang) do
      lang
    else
      raise ArgumentError,
            ":language must be a BCP-47 tag like \"en-US\" (hyphen, not underscore), got: " <>
              inspect(lang)
    end
  end

  defp language!(lang),
    do: raise(ArgumentError, ":language must be a binary or nil, got: #{inspect(lang)}")

  defp boolean!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> value
      other -> raise ArgumentError, "#{inspect(key)} must be a boolean, got: #{inspect(other)}"
    end
  end

  defp stop_timeout!(opts, engine) do
    {source, ms} =
      case Keyword.fetch(opts, :stop_timeout_ms) do
        {:ok, ms} -> {":stop_timeout_ms", ms}
        :error -> engine_stop_timeout(engine)
      end

    if is_integer(ms) and ms >= 0 do
      ms
    else
      raise ArgumentError, "#{source} must be a non-negative integer, got: #{inspect(ms)}"
    end
  end

  defp engine_stop_timeout(engine) do
    if function_exported?(engine, :stop_timeout_ms, 0),
      do: {"#{inspect(engine)}.stop_timeout_ms/0", engine.stop_timeout_ms()},
      else: {"default", Session.default_stop_timeout_ms()}
  end
end
