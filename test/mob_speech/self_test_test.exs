defmodule MobSpeech.SelfTestTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}
  alias MobSpeech.SelfTest

  @plugin_dir Path.expand("../..", __DIR__)
  @android %{platform: :android, device: :emulator}
  @ios %{platform: :ios, device: :simulator}

  # Stub NIF modules: speech_available/0 answers what the native side can.
  for {name, answer} <- [
        AvailableNif: true,
        UnavailableNif: false,
        NotAuthorizedNif: {:error, :not_authorized},
        UnsupportedLocaleNif: {:error, :unsupported_locale},
        BridgeNotRegisteredNif: {:error, :bridge_not_registered},
        NoJniEnvNif: {:error, :no_jni_env},
        NoActivityNif: {:error, :no_activity},
        BridgeCallFailedNif: {:error, :bridge_call_failed},
        OkNif: :ok
      ] do
    defmodule Module.concat(__MODULE__, name) do
      @answer answer
      def speech_available, do: @answer
    end
  end

  defmodule NotLoadedNif do
    def speech_available, do: :erlang.nif_error(:nif_not_loaded)
  end

  defp nif(name), do: Module.concat(__MODULE__, name)

  defp run!(ctx, name) do
    result = SelfTest.run(ctx, nif(name))
    assert Mob.Plugin.SelfTest.result?(result), "#{inspect(result)} is outside the contract"
    result
  end

  test "the manifest declares it and the validator raises no selftest warning" do
    {:ok, m} = Manifest.load(@plugin_dir)
    assert m.selftest == MobSpeech.SelfTest
    assert %{errors: [], warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
    refute Enum.any?(warnings, &(&1 =~ "selftest"))
  end

  test "an available recogniser passes on both platforms" do
    assert run!(@android, :AvailableNif) == :pass
    assert run!(@ios, :AvailableNif) == :pass
  end

  test "Android false (bridge answered, no recognition service) skips naming the service" do
    assert {:skip, reason} = run!(@android, :UnavailableNif)
    assert reason =~ "isRecognitionAvailable is false"
    assert reason =~ "android.speech.RecognitionService"
  end

  test "iOS: unauthorised needs the user; no locale recogniser or an off recogniser skip" do
    assert run!(@ios, :NotAuthorizedNif) == {:skip, :needs_user}

    assert run!(@ios, :UnsupportedLocaleNif) ==
             {:skip, "SFSpeechRecognizer has no recogniser for the device locale"}

    assert {:skip, reason} = run!(@ios, :UnavailableNif)
    assert reason =~ "SFSpeechRecognizer.isAvailable is false"
  end

  test "an Android bridge that could not answer fails, naming what is missing" do
    assert {:fail, reason} = run!(@android, :BridgeNotRegisteredNif)
    assert reason =~ "MobSpeechBridge.register() never ran"

    assert {:fail, reason} = run!(@android, :NoJniEnvNif)
    assert reason =~ "could not reach the JVM"

    assert {:fail, reason} = run!(@android, :NoActivityNif)
    assert reason =~ "MobSpeechBridge has no Activity"

    assert {:fail, reason} = run!(@android, :BridgeCallFailedNif)
    assert reason =~ "MobSpeechBridge.speech_available() threw"
  end

  test "an answer outside the native contract fails, naming the call and the answer" do
    assert run!(@android, :OkNif) ==
             {:fail, "speech_available/0 on android returned :ok, expected true or false"}

    # An iOS-only answer on Android is not a skip.
    assert {:fail, reason} = run!(@android, :NotAuthorizedNif)
    assert reason =~ "returned {:error, :not_authorized}"
  end

  test "nif_not_loaded fails, naming the NIF, instead of raising" do
    assert {:fail, reason} = run!(@ios, :NotLoadedNif)
    assert reason =~ "mob_speech_nif is not linked"
    assert reason =~ "nif_not_loaded"
  end

  test "run/1 on the host (stub .erl, no NIF linked) fails instead of raising" do
    assert {:fail, reason} = SelfTest.run(@android)
    assert reason =~ "mob_speech_nif is not linked"
    assert Mob.Plugin.SelfTest.result?({:fail, reason})
  end
end
