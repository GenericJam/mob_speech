defmodule MobSpeech.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  One read-only native call, `:mob_speech_nif.speech_available/0`: no
  microphone, no recognition session, no prompt. The host stub raises
  `nif_not_loaded`, so any answer proves the NIF is linked; what it answers
  says how far the native side got.

  **Android** (`mob_speech_nif.zig` → `MobSpeechBridge.speech_available()` →
  `SpeechRecognizer.isRecognitionAvailable/1`):

    * `true` passes: the zig NIF, the registered Kotlin bridge, its Activity
      and a recognition service all answered.
    * `false` is a string skip: the bridge answered (registered, has an
      Activity) and the system reports no `RecognitionService` the app can
      see. That is a device without one (redroid, AOSP emulator images) or,
      on Android 11+, a host whose `AndroidManifest.xml` lacks the
      `<queries>` entry for `android.speech.RecognitionService` (see the
      manifest's `host_requirements`; mob_new hosts do not add it).
    * `{:error, :bridge_not_registered | :no_jni_env | :no_activity |
      :bridge_call_failed}` fails: the bootstrap never called
      `MobSpeechBridge.register()` (or a method-ID lookup failed), the NIF
      found no JVM, the bootstrap never handed the bridge an Activity, or the
      Kotlin call threw. The plugin can never listen in that host.

  **iOS** (`mob_speech_nif.m` → `SFSpeechRecognizer`):

    * `true` passes: the Objective-C NIF and Speech.framework answered and a
      recogniser for the device locale is available.
    * `{:error, :not_authorized}` is `{:skip, :needs_user}`: the recogniser
      is not available and speech recognition is not authorised. `simctl
      privacy` has no speech-recognition service, so the runner cannot
      pre-grant it; a fresh simulator, and a physical device whose user has
      not answered, land here.
    * `{:error, :unsupported_locale}` (no recogniser for the device locale)
      and `false` (authorised, but Siri/dictation is off or there is no
      network) are string skips: a device setting, not the plugin.

  Any other answer fails.
  """
  @behaviour Mob.Plugin.SelfTest

  @impl true
  def run(ctx), do: run(ctx, :mob_speech_nif)

  @doc false
  # `nif` is the NIF module, so tests can pass a stub.
  @spec run(Mob.Plugin.SelfTest.ctx(), module()) :: Mob.Plugin.SelfTest.result()
  def run(%{platform: platform}, nif) do
    classify(nif.speech_available(), platform)
  rescue
    e in [ErlangError, UndefinedFunctionError] ->
      {:fail,
       "mob_speech_nif is not linked into this build: speech_available/0 raised " <>
         Exception.message(e)}
  end

  defp classify(true, _platform), do: :pass

  defp classify(false, :android) do
    {:skip,
     "SpeechRecognizer.isRecognitionAvailable is false: no RecognitionService is installed, " <>
       "or (Android 11+) the host's AndroidManifest.xml lacks <queries> for " <>
       "android.speech.RecognitionService"}
  end

  defp classify(false, :ios) do
    {:skip,
     "SFSpeechRecognizer.isAvailable is false although speech recognition is authorised: " <>
       "Siri/dictation is off or there is no network"}
  end

  defp classify({:error, :not_authorized}, :ios), do: {:skip, :needs_user}

  defp classify({:error, :unsupported_locale}, :ios) do
    {:skip, "SFSpeechRecognizer has no recogniser for the device locale"}
  end

  defp classify({:error, :bridge_not_registered}, :android) do
    {:fail,
     "speech_available/0 returned {:error, :bridge_not_registered}: MobSpeechBridge.register() " <>
       "never ran or the speech_available method-ID lookup failed"}
  end

  defp classify({:error, :no_jni_env}, :android) do
    {:fail, "speech_available/0 returned {:error, :no_jni_env}: the NIF could not reach the JVM"}
  end

  defp classify({:error, :no_activity}, :android) do
    {:fail,
     "speech_available/0 returned {:error, :no_activity}: MobSpeechBridge has no Activity " <>
       "(MobActivityAware.setActivity never called)"}
  end

  defp classify({:error, :bridge_call_failed}, :android) do
    {:fail,
     "speech_available/0 returned {:error, :bridge_call_failed}: " <>
       "MobSpeechBridge.speech_available() threw"}
  end

  defp classify(other, platform) do
    {:fail,
     "speech_available/0 on #{platform} returned #{inspect(other)}, expected true or false"}
  end
end
