defmodule MobSpeech.ReasonTest do
  use ExUnit.Case, async: true

  alias MobSpeech.Reason

  doctest MobSpeech.Reason

  describe "Android SpeechRecognizer.ERROR_* codes" do
    test "map to the documented reasons" do
      table = %{
        1 => :network,
        2 => :network,
        3 => :audio,
        4 => :server,
        5 => :client,
        6 => :no_speech,
        7 => :no_speech,
        8 => :busy,
        10 => :too_many_requests,
        11 => :server,
        12 => :language,
        13 => :language
      }

      for {code, reason} <- table do
        assert Reason.normalize({:android, code, true}) == reason, "code #{code}"
      end
    end

    test "INSUFFICIENT_PERMISSIONS blames the service only when the app holds the mic" do
      assert Reason.normalize({:android, 9, true}) == :service_permission
      assert Reason.normalize({:android, 9, false}) == :permission
    end

    test "the bridge's own pre-checks" do
      assert Reason.normalize({:android, -1, false}) == :permission
      assert Reason.normalize({:android, -2, true}) == :unavailable
      assert Reason.normalize({:android, -3, false}) == :client
    end

    test "unknown codes keep the code" do
      assert Reason.normalize({:android, 14, true}) == {:unknown, 14}
    end
  end

  describe "iOS NSError domains" do
    test "map to the documented reasons" do
      assert Reason.normalize({:ios, "kAFAssistantErrorDomain", 1110}) == :no_speech
      assert Reason.normalize({:ios, "kAFAssistantErrorDomain", 203}) == :no_speech
      assert Reason.normalize({:ios, "kAFAssistantErrorDomain", 1700}) == :permission
      assert Reason.normalize({:ios, "kLSRErrorDomain", 300}) == :language
      assert Reason.normalize({:ios, "kLSRErrorDomain", 201}) == :unavailable
      assert Reason.normalize({:ios, "SFSpeechErrorDomain", 2}) == :audio
      assert Reason.normalize({:ios, "NSURLErrorDomain", -1009}) == :network
      assert Reason.normalize({:ios, "NSOSStatusErrorDomain", -50}) == :audio
    end

    test "the task's own cancellation is internal, not an error" do
      assert Reason.normalize({:ios, "kAFAssistantErrorDomain", 216}) == :cancelled
      assert Reason.normalize({:ios, "kLSRErrorDomain", 301}) == :cancelled
    end

    test "unknown domain/code pairs keep both" do
      assert Reason.normalize({:ios, "SomeDomain", 7}) == {:unknown, "SomeDomain:7"}
    end
  end

  describe "tags and atoms" do
    test "public atoms and their string tags pass through" do
      for reason <- Reason.public() do
        assert Reason.normalize(reason) == reason
        assert Reason.normalize(Atom.to_string(reason)) == reason
      end
    end

    test "anything else is {:unknown, raw}" do
      assert Reason.normalize("nope") == {:unknown, "nope"}
      assert Reason.normalize(:whatever) == {:unknown, :whatever}
      assert Reason.normalize({:android, "13", true}) == {:unknown, {:android, "13", true}}
    end
  end
end
