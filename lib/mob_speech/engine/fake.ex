defmodule MobSpeech.Engine.Fake do
  @moduledoc """
  A scripted engine: plays back recogniser events so screens (and agents
  driving them) can test dictation with no microphone, no recogniser and no
  device. Everything still goes through the real session, so the events a
  screen receives are exactly what the platform engine would produce for the
  same raw sequence (fallbacks, watchdog, single idle included).

      MobSpeech.listen(socket,
        engine: MobSpeech.Engine.Fake,
        script: [:listening, {:partial, "hello"}, {:wait, 100}, {:partial, "hello world"}],
        on_stop: [{:final, ""}]
      )

  Options (besides the usual `MobSpeech.listen/2` ones):

    * `:script` — steps played as soon as listening starts. Default
      `[:listening]`.
    * `:on_stop` — steps played when the app calls `MobSpeech.stop/1`.
      Default `[{:final, ""}]`: an empty final, like the Google recogniser
      often sends, so the session falls back to the last partial. `[]` means
      the recogniser never answers, which exercises the stop watchdog.
    * `:start_error` — make `start/2` fail synchronously with this reason.
    * `:notify` — a pid that receives `{:mob_speech_fake, call, session}`
      for every engine call (`{:start, opts}`, `:stop`, `:cancel`), to assert
      what the session did.

  Steps: `:listening`, `{:partial, text}`, `{:final, text}`,
  `{:error, raw_reason}` (anything `MobSpeech.Reason.normalize/1` takes, e.g.
  `{:android, 13, true}`), `:idle`, `{:wait, ms}`.
  """

  @behaviour MobSpeech.Engine

  @type step ::
          :listening
          | :idle
          | {:partial, String.t()}
          | {:final, String.t()}
          | {:error, term()}
          | {:wait, non_neg_integer()}

  @impl true
  def start(session, opts) do
    notify(opts, {:start, opts}, session)

    case Keyword.fetch(opts, :start_error) do
      {:ok, reason} ->
        {:error, reason}

      :error ->
        script = Keyword.get(opts, :script, [:listening])
        on_stop = Keyword.get(opts, :on_stop, [{:final, ""}])
        runner = spawn(fn -> runner(session, script, on_stop) end)
        Process.put(__MODULE__, {runner, Keyword.get(opts, :notify)})
        :ok
    end
  end

  @impl true
  def stop(session), do: signal(session, :stop)

  @impl true
  def cancel(session), do: signal(session, :cancel)

  @impl true
  def available?, do: true

  @impl true
  def permissions, do: []

  # Engine callbacks run in the session process (see MobSpeech.Engine), so
  # the runner started by start/2 is found in its process dictionary.
  defp signal(session, call) do
    case Process.get(__MODULE__) do
      {runner, notify_pid} ->
        if notify_pid, do: send(notify_pid, {:mob_speech_fake, call, session})
        send(runner, call)

      nil ->
        :ok
    end

    :ok
  end

  defp notify(opts, call, session) do
    case Keyword.get(opts, :notify) do
      pid when is_pid(pid) -> send(pid, {:mob_speech_fake, call, session})
      _ -> :ok
    end
  end

  defp runner(session, script, on_stop) do
    ref = Process.monitor(session)

    case play(script, session, ref) do
      :continue -> await_stop(session, on_stop, ref)
      :halt -> :ok
    end
  end

  defp await_stop(session, on_stop, ref) do
    receive do
      :stop -> play(on_stop, session, ref)
      :cancel -> :ok
      {:DOWN, ^ref, :process, _, _} -> :ok
    end
  end

  defp play([], _session, _ref), do: :continue

  defp play([{:wait, ms} | rest], session, ref) do
    receive do
      :cancel -> :halt
      {:DOWN, ^ref, :process, _, _} -> :halt
    after
      ms -> play(rest, session, ref)
    end
  end

  defp play([step | rest], session, ref) do
    send(session, event(step))
    play(rest, session, ref)
  end

  defp event(:listening), do: {:speech, :state, :listening}
  defp event(:idle), do: {:speech, :state, :idle}
  defp event({:partial, text}), do: {:speech, :partial, text}
  defp event({:final, text}), do: {:speech, :final, text}
  defp event({:error, reason}), do: {:speech, :error, reason}
end
