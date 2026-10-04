defmodule MobSpeech.SessionTest do
  use ExUnit.Case, async: true

  alias MobSpeech.Engine.Fake
  alias MobSpeech.Session

  # Feed inputs through the pure state machine; return every effect, in order.
  defp run(inputs, opts \\ []) do
    {_state, effects} =
      Enum.reduce(inputs, {Session.new(opts), []}, fn input, {s, acc} ->
        {s, effects} = Session.handle(s, input)
        {s, acc ++ effects}
      end)

    effects
  end

  defp emitted(effects), do: for({:emit, e} <- effects, do: e)
  defp engine(x), do: {:engine, x}

  describe "state machine (pure)" do
    test "listening once, partials streamed, stop → processing, final, one idle" do
      effects =
        run([
          engine({:speech, :state, :listening}),
          engine({:speech, :state, :listening}),
          engine({:speech, :partial, "hel"}),
          engine({:speech, :partial, "hello"}),
          :stop,
          engine({:speech, :final, "hello there"})
        ])

      assert emitted(effects) == [
               {:speech, :state, :listening},
               {:speech, :partial, "hel"},
               {:speech, :partial, "hello"},
               {:speech, :state, :processing},
               {:speech, :final, "hello there"},
               {:speech, :state, :idle}
             ]

      assert {:engine, :stop} in effects
      assert {:watchdog, 2_000} in effects
    end

    test "the recogniser's own end-of-speech is not :processing (the hold continues)" do
      effects =
        run([
          engine({:speech, :state, :listening}),
          engine({:speech, :state, :processing}),
          engine({:speech, :partial, "hi"})
        ])

      assert emitted(effects) == [{:speech, :state, :listening}, {:speech, :partial, "hi"}]
    end

    test "an empty final falls back to the last partial" do
      effects =
        run([engine({:speech, :partial, "turn left"}), :stop, engine({:speech, :final, "  "})])

      assert {:speech, :final, "turn left"} in emitted(effects)
    end

    test "an empty final with no partials is :no_speech" do
      effects = run([engine({:speech, :state, :listening}), :stop, engine({:speech, :final, ""})])

      assert Enum.take(emitted(effects), -2) == [
               {:speech, :error, :no_speech},
               {:speech, :state, :idle}
             ]
    end

    test "NO_MATCH / SPEECH_TIMEOUT after partials deliver the last partial as the final" do
      for code <- [6, 7] do
        effects =
          run([
            engine({:speech, :partial, "hello"}),
            engine({:speech, :error, {:android, code, true}})
          ])

        assert Enum.take(emitted(effects), -2) == [
                 {:speech, :final, "hello"},
                 {:speech, :state, :idle}
               ]
      end
    end

    test "other errors are normalised and end with one idle, even after partials" do
      effects =
        run([
          engine({:speech, :partial, "hello"}),
          engine({:speech, :error, {:android, 13, true}})
        ])

      assert Enum.take(emitted(effects), -2) == [
               {:speech, :error, :language},
               {:speech, :state, :idle}
             ]
    end

    test "partial_results: false hides partials but still uses them for the fallback" do
      effects =
        run(
          [engine({:speech, :partial, "quiet"}), :stop, engine({:speech, :final, ""})],
          partial_results: false
        )

      refute Enum.any?(emitted(effects), &match?({:speech, :partial, _}, &1))
      assert {:speech, :final, "quiet"} in emitted(effects)
    end

    test "a final before stop (self-endpointing) ends it; the later stop is a no-op" do
      effects =
        run([
          engine({:speech, :state, :listening}),
          engine({:speech, :final, "done"}),
          :stop,
          engine({:speech, :final, "late"})
        ])

      assert emitted(effects) == [
               {:speech, :state, :listening},
               {:speech, :final, "done"},
               {:speech, :state, :idle}
             ]

      refute {:engine, :stop} in effects
    end

    test "the watchdog cancels a silent recogniser and delivers the last partial" do
      effects =
        run(
          [
            engine({:speech, :partial, "so far"}),
            :stop,
            :watchdog,
            engine({:speech, :final, "x"})
          ],
          stop_timeout_ms: 50
        )

      assert {:watchdog, 50} in effects

      # The screen hears first; the (possibly slow) engine call comes last.
      assert Enum.take(effects, -3) == [
               {:emit, {:speech, :final, "so far"}},
               {:emit, {:speech, :state, :idle}},
               {:engine, :cancel}
             ]
    end

    test "the watchdog with nothing heard is :no_speech" do
      effects = run([engine({:speech, :state, :listening}), :stop, :watchdog])

      assert Enum.take(emitted(effects), -2) == [
               {:speech, :error, :no_speech},
               {:speech, :state, :idle}
             ]
    end

    test "a watchdog that fires after the final changes nothing" do
      effects = run([:stop, engine({:speech, :final, "ok"}), :watchdog])

      refute {:engine, :cancel} in effects
      assert Enum.count(emitted(effects), &(&1 == {:speech, :state, :idle})) == 1
    end

    test "cancel → idle, no final; idle and ack precede the engine call; later events dropped" do
      ack = {self(), make_ref()}

      effects =
        run([
          engine({:speech, :partial, "abc"}),
          {:cancel, ack},
          engine({:speech, :final, "abc"}),
          {:cancel, nil}
        ])

      assert emitted(effects) == [
               {:speech, :state, :listening},
               {:speech, :partial, "abc"},
               {:speech, :state, :idle}
             ]

      assert Enum.take(effects, -3) == [
               {:emit, {:speech, :state, :idle}},
               {:ack, ack},
               {:engine, :cancel}
             ]
    end

    test "a preempted recogniser (engine idle) ends with a bare idle" do
      effects = run([engine({:speech, :state, :listening}), engine({:speech, :state, :idle})])
      assert emitted(effects) == [{:speech, :state, :listening}, {:speech, :state, :idle}]
    end

    test "preempted after stop: the last partial is the final; nothing heard is a bare idle" do
      heard = run([engine({:speech, :partial, "hi"}), :stop, engine({:speech, :state, :idle})])
      assert Enum.take(emitted(heard), -2) == [{:speech, :final, "hi"}, {:speech, :state, :idle}]

      silent =
        run([engine({:speech, :state, :listening}), :stop, engine({:speech, :state, :idle})])

      assert List.last(emitted(silent)) == {:speech, :state, :idle}
      refute Enum.any?(emitted(silent), &match?({:speech, :error, _}, &1))
    end

    test "the screen dying cancels the engine silently" do
      effects =
        run([engine({:speech, :partial, "x"}), :target_down, engine({:speech, :final, "x"})])

      assert emitted(effects) == [{:speech, :state, :listening}, {:speech, :partial, "x"}]
      assert {:engine, :cancel} in effects
    end

    test "iOS task cancellation is not reported as an error" do
      effects = run([engine({:speech, :error, {:ios, "kAFAssistantErrorDomain", 216}})])
      assert emitted(effects) == [{:speech, :state, :idle}]
    end
  end

  describe "listen/stop/cancel through the Fake engine" do
    setup do
      %{socket: Mob.Socket.new(nil)}
    end

    test "listen → listening + partials; stop → processing, last-partial final, idle", %{
      socket: s
    } do
      s =
        MobSpeech.listen(s,
          engine: Fake,
          script: [:listening, {:partial, "hello"}, {:partial, "hello world"}],
          on_stop: [{:final, ""}]
        )

      assert_receive {:speech, :state, :listening}
      assert_receive {:speech, :partial, "hello"}
      assert_receive {:speech, :partial, "hello world"}

      MobSpeech.stop(s)
      assert_receive {:speech, :state, :processing}
      assert_receive {:speech, :final, "hello world"}
      assert_receive {:speech, :state, :idle}

      MobSpeech.stop(s)
      refute_receive {:speech, _, _}, 50
    end

    test "stop with a recogniser that never answers: watchdog cancels it", %{socket: s} do
      s =
        MobSpeech.listen(s,
          engine: Fake,
          notify: self(),
          script: [:listening, {:partial, "held"}],
          on_stop: [],
          stop_timeout_ms: 30
        )

      assert_receive {:speech, :partial, "held"}
      MobSpeech.stop(s)
      assert_receive {:speech, :state, :processing}
      assert_receive {:mob_speech_fake, :stop, _}
      assert_receive {:mob_speech_fake, :cancel, _}
      assert_receive {:speech, :final, "held"}
      assert_receive {:speech, :state, :idle}
    end

    test "cancel → idle only, the engine is cancelled", %{socket: s} do
      s = MobSpeech.listen(s, engine: Fake, notify: self(), script: [:listening, {:partial, "x"}])

      assert_receive {:speech, :partial, "x"}
      s = MobSpeech.cancel(s)
      assert_receive {:mob_speech_fake, :cancel, _}
      assert_receive {:speech, :state, :idle}
      refute_receive {:speech, :final, _}, 50
      assert s.assigns.mob_speech == nil
    end

    test "a synchronous engine failure arrives as error + idle", %{socket: s} do
      MobSpeech.listen(s, engine: Fake, start_error: :permission)
      assert_receive {:speech, :error, :permission}
      assert_receive {:speech, :state, :idle}
    end

    test "the platform engine on a host build reports :unavailable + idle", %{socket: s} do
      MobSpeech.listen(s)
      assert_receive {:speech, :error, :unavailable}
      assert_receive {:speech, :state, :idle}
    end

    test "an engine error after partials becomes the final", %{socket: s} do
      MobSpeech.listen(s,
        engine: Fake,
        script: [:listening, {:partial, "almost"}, {:error, {:android, 7, true}}]
      )

      assert_receive {:speech, :final, "almost"}
      assert_receive {:speech, :state, :idle}
    end

    test ":to routes events to another process; unknown opts reach the engine", %{socket: s} do
      me = self()

      relay =
        spawn(fn ->
          receive do
            msg -> send(me, {:relayed, msg})
          end
        end)

      MobSpeech.listen(s,
        engine: Fake,
        to: relay,
        notify: me,
        script: [:listening],
        model: "tiny"
      )

      assert_receive {:mob_speech_fake, {:start, opts}, _}
      assert opts[:model] == "tiny"
      assert_receive {:relayed, {:speech, :state, :listening}}
      refute_received {:speech, _, _}
    end

    test "listening again cancels the previous session first", %{socket: s} do
      s = MobSpeech.listen(s, engine: Fake, notify: self(), script: [:listening])
      assert_receive {:speech, :state, :listening}
      %{session: first} = s.assigns.mob_speech

      s = MobSpeech.listen(s, engine: Fake, script: [:listening])
      assert_receive {:mob_speech_fake, :cancel, ^first}
      # The old session's idle is in the mailbox before the new one's events.
      assert_receive {:speech, _, _} = first_event
      assert first_event == {:speech, :state, :idle}
      assert_receive {:speech, :state, :listening}
      refute s.assigns.mob_speech.session == first
    end

    defmodule FailingEngine do
      @behaviour MobSpeech.Engine
      # opts[:fail] picks the callback that fails and how (raise / exit / throw /
      # a malformed return); the rest behave like a recogniser that is listening.
      def start(pid, opts) do
        Process.put(:fail, opts[:fail])

        if match?({:start, _}, opts[:fail]),
          do: fail(opts[:fail]),
          else: send(pid, {:speech, :state, :listening})

        :ok
      end

      def stop(_pid),
        do: if(match?({:stop, _}, Process.get(:fail)), do: fail(Process.get(:fail)), else: :ok)

      def cancel(_pid),
        do: if(match?({:cancel, _}, Process.get(:fail)), do: fail(Process.get(:fail)), else: :ok)

      def available?, do: true
      def permissions, do: []

      defp fail({_, :raise}), do: raise("boom")
      defp fail({_, :exit}), do: exit({:noproc, {GenServer, :call, [:nowhere]}})
      defp fail({_, :throw}), do: throw(:boom)
    end

    defp drain(acc \\ []) do
      receive do
        {:speech, _, _} = e -> drain([e | acc])
      after
        150 -> Enum.reverse(acc)
      end
    end

    @tag capture_log: true
    test "a start/2 that raises, exits or throws still ends with error + one idle", %{socket: s} do
      for how <- [:raise, :exit, :throw] do
        MobSpeech.listen(s, engine: FailingEngine, fail: {:start, how})
        assert drain() == [{:speech, :error, :client}, {:speech, :state, :idle}], "#{how}"
      end
    end

    @tag capture_log: true
    test "a stop/1 that fails delivers error + one idle at once, not after the watchdog",
         %{socket: s} do
      for how <- [:raise, :exit, :throw] do
        s =
          MobSpeech.listen(s, engine: FailingEngine, fail: {:stop, how}, stop_timeout_ms: 60_000)

        assert_receive {:speech, :state, :listening}
        MobSpeech.stop(s)

        assert drain() == [
                 {:speech, :state, :processing},
                 {:speech, :error, :client},
                 {:speech, :state, :idle}
               ],
               "#{how}"
      end
    end

    @tag capture_log: true
    test "a cancel/1 that exits doesn't swallow the idle (cancel and watchdog)", %{socket: s} do
      s = MobSpeech.listen(s, engine: FailingEngine, fail: {:cancel, :exit})
      assert_receive {:speech, :state, :listening}
      MobSpeech.cancel(s)
      assert drain() == [{:speech, :state, :idle}]

      s = MobSpeech.listen(s, engine: FailingEngine, fail: {:cancel, :exit}, stop_timeout_ms: 10)
      assert_receive {:speech, :state, :listening}
      MobSpeech.stop(s)

      assert drain() == [
               {:speech, :state, :processing},
               {:speech, :error, :no_speech},
               {:speech, :state, :idle}
             ]
    end

    defmodule BadReturnEngine do
      @behaviour MobSpeech.Engine
      def start(_pid, _opts), do: {:ok, make_ref()}
      def stop(_pid), do: :ok
      def cancel(_pid), do: :ok
      def available?, do: true
      def permissions, do: []
    end

    @tag capture_log: true
    test "a malformed start/2 return is an error + idle, not a dead session", %{socket: s} do
      MobSpeech.listen(s, engine: BadReturnEngine)
      assert drain() == [{:speech, :error, :client}, {:speech, :state, :idle}]
    end

    defmodule SlowStopEngine do
      @behaviour MobSpeech.Engine
      def start(pid, _opts), do: send(pid, {:speech, :state, :listening}) && :ok
      def stop(_pid), do: Process.sleep(200)
      def cancel(_pid), do: :ok
      def available?, do: true
      def permissions, do: []
    end

    test "a cancel that times out leaves no stray ack in the caller's mailbox", %{socket: s} do
      s = MobSpeech.listen(s, engine: SlowStopEngine, stop_timeout_ms: 60_000)
      assert_receive {:speech, :state, :listening}
      %{session: session} = s.assigns.mob_speech
      MobSpeech.stop(s)
      # The session is stuck in stop/1 for 200 ms; give up on the ack after 20.
      MobSpeech.Session.cancel(session, 20)
      assert_receive {:speech, :state, :idle}, 1_000
      refute_receive {_ref, :cancelled}, 300
    end

    test "the session goes away with its screen and cancels the engine" do
      me = self()

      screen =
        spawn(fn ->
          MobSpeech.listen(Mob.Socket.new(nil), engine: Fake, notify: me, script: [:listening])
          receive do: (:quit -> :ok)
        end)

      assert_receive {:mob_speech_fake, {:start, _}, session}
      ref = Process.monitor(session)
      send(screen, :quit)
      assert_receive {:mob_speech_fake, :cancel, ^session}
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    end
  end
end
