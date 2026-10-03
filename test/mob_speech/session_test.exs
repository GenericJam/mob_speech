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
      assert {:engine, :cancel} in effects

      assert Enum.take(emitted(effects), -2) == [
               {:speech, :final, "so far"},
               {:speech, :state, :idle}
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

    test "cancel → idle, no final, engine cancelled; later events dropped" do
      effects =
        run([
          engine({:speech, :partial, "abc"}),
          :cancel,
          engine({:speech, :final, "abc"}),
          :cancel
        ])

      assert emitted(effects) == [
               {:speech, :state, :listening},
               {:speech, :partial, "abc"},
               {:speech, :state, :idle}
             ]

      assert Enum.count(effects, &(&1 == {:engine, :cancel})) == 1
    end

    test "a preempted recogniser (engine idle) ends with a bare idle" do
      effects = run([engine({:speech, :state, :listening}), engine({:speech, :state, :idle})])
      assert emitted(effects) == [{:speech, :state, :listening}, {:speech, :state, :idle}]
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
      assert_receive {:speech, :state, :idle}
      assert_receive {:speech, :state, :listening}
      refute s.assigns.mob_speech.session == first
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
