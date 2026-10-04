defmodule MobSpeechTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("..", __DIR__)

  describe "plugin manifest" do
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      %{manifest: manifest}
    end

    test "loads and validates clean (round-trips)", %{manifest: m} do
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "classifies as tier 3 (NIF + a demo screen)", %{manifest: m} do
      assert Manifest.tier(m) == 3
    end

    test "passes the full pre-publish validator (paths, NIF modules, permissions)",
         %{manifest: m} do
      assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
    end

    test "declares the cross-platform NIF pattern: one module, both platforms",
         %{manifest: m} do
      assert [ios, android] = m.nifs
      assert ios.module == :mob_speech_nif and ios.platform == :ios and ios.lang == :objc
      assert android.module == :mob_speech_nif and android.platform == :android
      assert android.lang == :zig
    end

    test "owns the :speech capability with the iOS self-registered handler", %{manifest: m} do
      assert [%{capability: :speech, ios: %{handler: "mob_speech_request_permission"}}] =
               m.permissions
    end

    test "Android declares RECORD_AUDIO; iOS the speech key but not the core-owned mic key",
         %{manifest: m} do
      assert "android.permission.RECORD_AUDIO" in m.android.permissions
      assert Map.has_key?(m.ios.plist_keys, "NSSpeechRecognitionUsageDescription")
      # Core owns :microphone; a second plugin declaring the key would collide.
      refute Map.has_key?(m.ios.plist_keys, "NSMicrophoneUsageDescription")
      assert "Speech" in m.ios.frameworks
    end

    test "the iOS permission handler named in the manifest is the one the NIF registers",
         %{manifest: m} do
      [%{ios: %{handler: handler}}] = m.permissions
      objc = File.read!(Path.join(@plugin_dir, "priv/native/ios/mob_speech_nif.m"))
      assert objc =~ ~s{mob_register_permission_handler("speech", #{handler})}
    end
  end

  describe "NIF stub agreement" do
    @stub_nifs [speech_start: 5, speech_stop: 1, speech_cancel: 1, speech_available: 0]

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "every NIF the engine calls is exported by the stub at the right arity" do
      exports = :mob_speech_nif.module_info(:exports)
      for fa <- @stub_nifs, do: assert(fa in exports, "#{inspect(fa)} missing from stub")
    end

    # Guards the native FFI seam (a NIF table drifting from the stub fails to
    # load on device), not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the iOS and Android NIF tables register exactly the stub's NIFs" do
      objc = File.read!(Path.join(@plugin_dir, "priv/native/ios/mob_speech_nif.m"))
      zig = File.read!(Path.join(@plugin_dir, "priv/native/jni/mob_speech_nif.zig"))

      objc_table =
        for [_, name, arity] <- Regex.scan(~r/\{"(speech_\w+)", (\d), nif_\w+, 0\}/, objc),
            do: {String.to_atom(name), String.to_integer(arity)}

      zig_table =
        for [_, name, arity] <- Regex.scan(~r/\.name = "(speech_\w+)", \.arity = (\d)/, zig),
            do: {String.to_atom(name), String.to_integer(arity)}

      assert Enum.sort(objc_table) == Enum.sort(@stub_nifs)
      assert Enum.sort(zig_table) == Enum.sort(@stub_nifs)
    end

    # A JNI name drifting from the Kotlin bridge silently does nothing on
    # device — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "every JNI thunk and cached bridge method exists in the Kotlin bridge" do
      zig = File.read!(Path.join(@plugin_dir, "priv/native/jni/mob_speech_nif.zig"))
      kt = File.read!(Path.join(@plugin_dir, "priv/native/android/MobSpeechBridge.kt"))

      thunks =
        for [_, n] <- Regex.scan(~r/Java_io_mob_speech_MobSpeechBridge_(\w+)\(/, zig), do: n

      cached = for [_, n] <- Regex.scan(~r/cacheMethod\(jenv, cls, "(\w+)"/, zig), do: n

      assert Enum.sort(thunks) ==
               ~w(nativeDeliverError nativeDeliverState nativeDeliverText nativeRegister)

      for n <- thunks, do: assert(kt =~ "external fun #{n}(", "Kotlin lacks external #{n}")
      for n <- cached, do: assert(kt =~ "fun #{n}(", "Kotlin lacks bridge method #{n}")
    end

    # A signature drift leaves the cached method id null on device, and the
    # NIF then returns :ok while doing nothing — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "every cached JNI signature matches the Kotlin method's parameter types" do
      zig = File.read!(Path.join(@plugin_dir, "priv/native/jni/mob_speech_nif.zig"))
      kt = File.read!(Path.join(@plugin_dir, "priv/native/android/MobSpeechBridge.kt"))

      jni = %{"Long" => "J", "String" => "Ljava/lang/String;", "Boolean" => "Z", "Int" => "I"}

      for [_, name, sig] <- Regex.scan(~r/cacheMethod\(jenv, cls, "(\w+)", "([^"]+)"\)/, zig) do
        [_, params | ret] = Regex.run(~r/fun #{name}\(([^)]*)\)(?::\s*(\w+))?/, kt)

        args =
          for p <- String.split(params, ",", trim: true),
              [_, type] = Regex.run(~r/:\s*(\w+)/, p),
              into: "",
              do: Map.fetch!(jni, type)

        ret = if ret in [[], [""]], do: "V", else: Map.fetch!(jni, hd(ret))
        assert sig == "(#{args})#{ret}", "#{name}: zig #{sig} vs Kotlin (#{args})#{ret}"
      end
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "host (no native linked) falls back to nif_not_loaded, not a load crash" do
      assert_raise ErlangError, ~r/nif_not_loaded/, fn -> :mob_speech_nif.speech_stop(self()) end
    end
  end

  describe "available?/1 and permissions/1" do
    test "the platform engine is unavailable on a host build (no NIF linked)" do
      refute MobSpeech.available?()
      refute MobSpeech.available?(:platform)
    end

    test "reports each engine's own answer" do
      assert MobSpeech.available?(MobSpeech.Engine.Fake)
      assert MobSpeech.permissions() == [:speech]
      assert MobSpeech.permissions(MobSpeech.Engine.Fake) == []
    end
  end

  describe "validate_opts!/1" do
    defmodule SlowEngine do
      @behaviour MobSpeech.Engine
      def start(_pid, _opts), do: :ok
      def stop(_pid), do: :ok
      def cancel(_pid), do: :ok
      def available?, do: true
      def permissions, do: []
      def stop_timeout_ms, do: 30_000
    end

    test "fills the documented defaults; offline is never preferred by default" do
      {engine, target, opts} = MobSpeech.validate_opts!([])

      assert engine == MobSpeech.Engine.Platform
      assert target == self()
      assert opts[:language] == nil
      assert opts[:prefer_offline] == false
      assert opts[:partial_results] == true
      assert opts[:stop_timeout_ms] == 2_000
    end

    test "passes the given values and unknown options through to the engine" do
      to = spawn(fn -> :ok end)

      {MobSpeech.Engine.Fake, ^to, opts} =
        MobSpeech.validate_opts!(
          engine: MobSpeech.Engine.Fake,
          to: to,
          language: "zh-Hant-TW",
          prefer_offline: true,
          partial_results: false,
          stop_timeout_ms: 0,
          model: "base.en"
        )

      assert opts[:language] == "zh-Hant-TW"
      assert opts[:prefer_offline] == true
      assert opts[:partial_results] == false
      assert opts[:stop_timeout_ms] == 0
      assert opts[:model] == "base.en"
      refute Keyword.has_key?(opts, :engine) or Keyword.has_key?(opts, :to)
    end

    test "an engine's stop_timeout_ms/0 is the default; an explicit option wins" do
      {_, _, opts} = MobSpeech.validate_opts!(engine: SlowEngine)
      assert opts[:stop_timeout_ms] == 30_000

      {_, _, opts} = MobSpeech.validate_opts!(engine: SlowEngine, stop_timeout_ms: 500)
      assert opts[:stop_timeout_ms] == 500
    end

    test "rejects invalid options with ArgumentError" do
      for bad <- [
            [language: "en_US"],
            [language: "e"],
            [language: :en],
            [prefer_offline: "yes"],
            [partial_results: nil],
            [stop_timeout_ms: -1],
            [stop_timeout_ms: 1.5],
            [engine: Enum],
            [engine: "platform"],
            [to: :me]
          ] do
        assert_raise ArgumentError, fn -> MobSpeech.validate_opts!(bad) end
      end
    end
  end
end
