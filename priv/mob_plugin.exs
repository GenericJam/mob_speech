%{
  name: :mob_speech,
  mob_version: "~> 0.9",
  plugin_spec_version: 1,
  description: "Speech-to-text (Android SpeechRecognizer / iOS SFSpeechRecognizer)",
  # On-device proof for `mix mob.selftest` / mob_ci: speech_available/0
  # through the NIF and the Kotlin bridge / SFSpeechRecognizer (see Mob.Plugin.SelfTest).
  selftest: MobSpeech.SelfTest,
  # A sample screen the host can navigate to by route. Pure-Elixir +
  # hot-pushable; drop it and this entry in a real app that builds its own UI.
  screens: [
    %{module: MobSpeech.DemoScreen, default_route: "/mob_speech/demo"}
  ],
  nifs: [
    # iOS: Objective-C NIF — SFSpeechRecognizer + AVAudioEngine input tap.
    %{module: :mob_speech_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
    # Android: zig NIF bridging to android.speech.SpeechRecognizer in the
    # Kotlin MobSpeechBridge.
    %{module: :mob_speech_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android}
  ],
  permissions: [
    # :speech = Android RECORD_AUDIO (MobSpeechBridge implements
    # MobPermissionProvider); iOS speech-recognition authorisation + microphone
    # record permission (handler self-registered at NIF load).
    %{capability: :speech, ios: %{handler: "mob_speech_request_permission"}}
  ],
  android: %{
    bridge_kt: "priv/native/android/MobSpeechBridge.kt",
    bridge_class: "io.mob.speech.MobSpeechBridge",
    # Set-unioned with core's template declaration — harmless duplicate.
    permissions: ["android.permission.RECORD_AUDIO"]
  },
  ios: %{
    frameworks: ["Speech", "AVFoundation"],
    # NSMicrophoneUsageDescription is deliberately NOT declared: core owns
    # :microphone and the generated host Info.plist already carries it, and two
    # plugins declaring the same plist key is a build-time collision (another
    # mic-using speech engine plugin would hit it).
    plist_keys: %{
      "NSSpeechRecognitionUsageDescription" =>
        "Speech recognition turns what you say into text."
    }
  },
  host_requirements: [
    "iOS: Info.plist must contain NSMicrophoneUsageDescription (mob_new apps " <>
      "have it; mob_speech doesn't declare it because core owns :microphone). " <>
      "Without it iOS kills the app the first time recognition starts.",
    "Android 11+: if MobSpeech.available?() is false although a recogniser is " <>
      "installed, add to AndroidManifest.xml (inside <manifest>, outside " <>
      "<application>): <queries><intent><action " <>
      "android:name=\"android.speech.RecognitionService\" /></intent></queries>"
  ]
}
