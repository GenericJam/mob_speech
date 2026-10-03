defmodule MobSpeech.DemoScreen do
  @moduledoc """
  A ready-to-run sample screen exercising `MobSpeech`, shipped so a generated
  app can kick the tires the moment the plugin is activated. Declared in the
  plugin manifest's `:screens` (route `/mob_speech/demo`). Delete it (and the
  manifest entry) in a real app.

  **Listen** asks for the `:speech` permission, then starts the platform
  recogniser; **Stop** finishes with the final, **Cancel** aborts. **Fake**
  plays a scripted recognition through `MobSpeech.Engine.Fake`, so the event
  flow is visible on a device without a recogniser.
  """
  use Mob.Screen

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       state: :idle,
       partial: "",
       final: "",
       error: nil,
       available: MobSpeech.available?(),
       pending: false
     )}
  end

  @impl true
  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        <Text text="Speech to text" text_size={:lg} text_color={:on_surface} padding={:space_sm} />
        <Text text={"recogniser: #{if assigns.available, do: "available", else: "unavailable"}"} text_size={:sm} text_color={:muted} padding={4} />
        <Text text={"state: #{assigns.state}"} text_size={:sm} text_color={:primary} padding={4} />
        <Text text={"partial: #{assigns.partial}"} text_size={:md} text_color={:on_surface} padding={4} />
        <Text text={"final: #{assigns.final}"} text_size={:md} text_color={:on_surface} padding={4} />
        <Text text={"error: #{inspect(assigns.error)}"} text_size={:sm} text_color={:muted} padding={4} />
        <Spacer size={16} />
        <Button text="Listen" background={:primary} text_color={:on_primary} padding={:space_md} fill_width={true} on_tap={{self(), :listen}} />
        <Spacer size={12} />
        <Button text="Stop" background={:surface} text_color={:on_surface} padding={:space_md} fill_width={true} on_tap={{self(), :stop}} />
        <Spacer size={12} />
        <Button text="Cancel" background={:surface} text_color={:on_surface} padding={:space_md} fill_width={true} on_tap={{self(), :cancel}} />
        <Spacer size={12} />
        <Button text="Fake" background={:surface} text_color={:on_surface} padding={:space_md} fill_width={true} on_tap={{self(), :fake}} />
      </Column>
    </Scroll>
    """
  end

  @impl true
  def handle_info({:tap, :listen}, socket) do
    socket = Enum.reduce(MobSpeech.permissions(), socket, &Mob.Permissions.request(&2, &1))
    {:noreply, Mob.Socket.assign(socket, pending: true, error: nil)}
  end

  def handle_info({:tap, :stop}, socket), do: {:noreply, MobSpeech.stop(socket)}
  def handle_info({:tap, :cancel}, socket), do: {:noreply, MobSpeech.cancel(socket)}

  def handle_info({:tap, :fake}, socket) do
    socket =
      MobSpeech.listen(socket,
        engine: MobSpeech.Engine.Fake,
        script: [
          :listening,
          {:wait, 300},
          {:partial, "hello"},
          {:wait, 300},
          {:partial, "hello world"}
        ],
        on_stop: [{:wait, 300}, {:final, ""}]
      )

    {:noreply, reset(socket)}
  end

  def handle_info({:permission, :speech, :granted}, %{assigns: %{pending: true}} = socket) do
    {:noreply, socket |> MobSpeech.listen() |> reset()}
  end

  def handle_info({:permission, :speech, _status}, socket) do
    {:noreply, Mob.Socket.assign(socket, pending: false, error: :permission)}
  end

  def handle_info({:speech, :state, state}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :state, state)}

  def handle_info({:speech, :partial, text}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :partial, text)}

  def handle_info({:speech, :final, text}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :final, text)}

  def handle_info({:speech, :error, reason}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :error, reason)}

  defp reset(socket),
    do: Mob.Socket.assign(socket, partial: "", final: "", error: nil, pending: false)
end
