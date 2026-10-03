defmodule MobSpeech.Session do
  @moduledoc """
  One recognition, from `MobSpeech.listen/2` to its single
  `{:speech, :state, :idle}`.

  A session is a short-lived process between an engine and the screen (the
  "target"). The engine sends it raw events (see `MobSpeech.Engine`); the
  session forwards the public events to the target and enforces the event
  contract. The contract itself is the pure `handle/2` state machine below,
  so it is unit-tested without a device or a process:

    * `:listening` once, when the engine reports it;
    * `:processing` only when the app stops (a hold-to-talk button is still
      held while the recogniser endpoints on its own);
    * an empty final, or a `:no_speech` error after partials, becomes a final
      carrying the last partial;
    * after a stop, a watchdog (`stop_timeout_ms`) cancels a recogniser that
      never reports back and delivers the last partial, or `:no_speech`;
    * exactly one idle after a final or an error; nothing after that;
    * cancel → idle, no final;
    * the target dying cancels the engine silently.

  The session process ends as soon as it has delivered idle, so stale engine
  messages (a slow recogniser answering a cancelled session) go to a dead pid.
  """

  require Logger

  alias MobSpeech.Reason

  @default_stop_timeout_ms 2_000

  @enforce_keys [:partial_results, :stop_timeout_ms]
  defstruct phase: :starting, last_partial: "", partial_results: true, stop_timeout_ms: 2_000

  @type phase :: :starting | :listening | :stopping | :done

  @type t :: %__MODULE__{
          phase: phase(),
          last_partial: String.t(),
          partial_results: boolean(),
          stop_timeout_ms: non_neg_integer()
        }

  @type event ::
          {:speech, :state, :listening | :processing | :idle}
          | {:speech, :partial, String.t()}
          | {:speech, :final, String.t()}
          | {:speech, :error, Reason.t()}

  @type input ::
          {:engine, term()} | :stop | :cancel | :watchdog | :target_down

  @type effect ::
          {:emit, event()} | {:engine, :stop | :cancel} | {:watchdog, non_neg_integer()}

  @doc "The stop watchdog used when neither the caller nor the engine sets one."
  @spec default_stop_timeout_ms() :: pos_integer()
  def default_stop_timeout_ms, do: @default_stop_timeout_ms

  @doc "A fresh session state (pure)."
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      partial_results: Keyword.get(opts, :partial_results, true),
      stop_timeout_ms: Keyword.get(opts, :stop_timeout_ms, @default_stop_timeout_ms)
    }
  end

  @doc """
  Advance the state machine by one input. Returns the new state and the
  effects to run, in order. Pure: no messages are sent here.
  """
  @spec handle(t(), input()) :: {t(), [effect()]}
  def handle(%__MODULE__{phase: :done} = s, _input), do: {s, []}

  def handle(s, {:engine, {:speech, :state, :listening}}) do
    case s.phase do
      :starting -> {%{s | phase: :listening}, [{:emit, {:speech, :state, :listening}}]}
      _ -> {s, []}
    end
  end

  def handle(s, {:engine, {:speech, :state, :idle}}) do
    cond do
      s.phase == :stopping and s.last_partial != "" -> finish(s, {:final, s.last_partial})
      s.phase == :stopping -> finish(s, {:error, :no_speech})
      true -> finish(s, :none)
    end
  end

  def handle(s, {:engine, {:speech, :partial, text}}) when is_binary(text) do
    if blank?(text) do
      {s, []}
    else
      {s, listening} = ensure_listening(s)
      emit = if s.partial_results, do: [{:emit, {:speech, :partial, text}}], else: []
      {%{s | last_partial: text}, listening ++ emit}
    end
  end

  def handle(s, {:engine, {:speech, :final, text}}) when is_binary(text) do
    cond do
      not blank?(text) -> finish(s, {:final, text})
      s.last_partial != "" -> finish(s, {:final, s.last_partial})
      true -> finish(s, {:error, :no_speech})
    end
  end

  def handle(s, {:engine, {:speech, :error, raw}}) do
    case Reason.normalize(raw) do
      :cancelled -> finish(s, :none)
      :no_speech when s.last_partial != "" -> finish(s, {:final, s.last_partial})
      reason -> finish(s, {:error, reason})
    end
  end

  def handle(s, :stop) when s.phase in [:starting, :listening] do
    {%{s | phase: :stopping},
     [
       {:emit, {:speech, :state, :processing}},
       {:engine, :stop},
       {:watchdog, s.stop_timeout_ms}
     ]}
  end

  def handle(s, :cancel) do
    {s, effects} = finish(s, :none)
    {s, [{:engine, :cancel} | effects]}
  end

  def handle(%__MODULE__{phase: :stopping} = s, :watchdog) do
    outcome = if s.last_partial != "", do: {:final, s.last_partial}, else: {:error, :no_speech}
    {s, effects} = finish(s, outcome)
    {s, [{:engine, :cancel} | effects]}
  end

  def handle(s, :target_down), do: {%{s | phase: :done}, [{:engine, :cancel}]}

  # Anything else (an engine's own :processing, a late watchdog, a stop while
  # already stopping, malformed engine messages) changes nothing.
  def handle(s, _input), do: {s, []}

  defp ensure_listening(%__MODULE__{phase: :starting} = s),
    do: {%{s | phase: :listening}, [{:emit, {:speech, :state, :listening}}]}

  defp ensure_listening(s), do: {s, []}

  defp finish(s, outcome) do
    result =
      case outcome do
        {:final, text} -> [{:emit, {:speech, :final, text}}]
        {:error, reason} -> [{:emit, {:speech, :error, reason}}]
        :none -> []
      end

    {%{s | phase: :done}, result ++ [{:emit, {:speech, :state, :idle}}]}
  end

  defp blank?(text), do: String.trim(text) == ""

  # ── process ─────────────────────────────────────────────────────────────

  @doc """
  Spawn a session that runs `engine` for `target` with the already-validated
  `opts`. Returns the session pid (used by `stop/1` / `cancel/1`).
  """
  @spec start(pid(), module(), keyword()) :: pid()
  def start(target, engine, opts) do
    spawn(fn -> init(target, engine, opts) end)
  end

  @doc "Ask a session to stop (deliver the final). No-op once it has ended."
  @spec stop(pid()) :: :ok
  def stop(session) do
    send(session, {:mob_speech, :stop})
    :ok
  end

  @doc "Ask a session to cancel (idle, no final). No-op once it has ended."
  @spec cancel(pid()) :: :ok
  def cancel(session) do
    send(session, {:mob_speech, :cancel})
    :ok
  end

  defp init(target, engine, opts) do
    ref = Process.monitor(target)
    state = new(opts)

    case call_engine(fn -> engine.start(self(), opts) end) do
      :ok -> loop(state, target, engine, ref)
      {:error, reason} -> step(state, {:engine, {:speech, :error, reason}}, target, engine, ref)
    end
  end

  defp loop(state, target, engine, ref) do
    receive do
      {:speech, _, _} = msg -> step(state, {:engine, msg}, target, engine, ref)
      {:mob_speech, :stop} -> step(state, :stop, target, engine, ref)
      {:mob_speech, :cancel} -> step(state, :cancel, target, engine, ref)
      {:mob_speech, :watchdog} -> step(state, :watchdog, target, engine, ref)
      {:DOWN, ^ref, :process, _, _} -> step(state, :target_down, target, engine, ref)
      _other -> loop(state, target, engine, ref)
    end
  end

  defp step(state, input, target, engine, ref) do
    {state, effects} = handle(state, input)
    Enum.each(effects, &run(&1, target, engine))
    if state.phase == :done, do: :ok, else: loop(state, target, engine, ref)
  end

  defp run({:emit, event}, target, _engine), do: send(target, event)
  defp run({:engine, :stop}, _target, engine), do: call_engine(fn -> engine.stop(self()) end)
  defp run({:engine, :cancel}, _target, engine), do: call_engine(fn -> engine.cancel(self()) end)

  defp run({:watchdog, ms}, _target, _engine),
    do: Process.send_after(self(), {:mob_speech, :watchdog}, ms)

  # The target must always get its idle, so an engine that raises (or a
  # platform engine on a build without the native NIF linked) becomes an
  # error instead of a dead session.
  defp call_engine(fun) do
    fun.()
  rescue
    e in ErlangError ->
      if e.original == :nif_not_loaded do
        {:error, :unavailable}
      else
        engine_crash(e, __STACKTRACE__)
      end

    e ->
      engine_crash(e, __STACKTRACE__)
  end

  defp engine_crash(e, stacktrace) do
    Logger.error("mob_speech engine raised: " <> Exception.format(:error, e, stacktrace))
    {:error, :client}
  end
end
