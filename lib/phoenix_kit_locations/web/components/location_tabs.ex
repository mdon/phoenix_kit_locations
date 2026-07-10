defmodule PhoenixKitLocations.Web.Components.LocationTabs do
  @moduledoc """
  Shared tab navigation between a Location's "Details" and "Structure"
  pages. Each tab is served by a separate LiveView (`LocationFormLive`
  and `LocationStructureLive`), so tab links use `navigate` rather than
  `patch`, mirroring `PhoenixKitWarehouse.Web.Components.WarehouseHeader`.

  Only meant to be rendered once the Location already exists (has a
  `uuid`) — there is no Structure tab for a not-yet-created Location.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitLocations.Gettext

  alias PhoenixKitLocations.Paths

  attr(:location, :map, required: true)
  attr(:active, :atom, required: true, values: [:details, :structure])

  def location_tabs(assigns) do
    ~H"""
    <div role="tablist" class="tabs tabs-border mb-4">
      <.link
        role="tab"
        navigate={Paths.location_edit(@location.uuid)}
        class={["tab", @active == :details && "tab-active"]}
      >
        {gettext("Details")}
      </.link>
      <.link
        role="tab"
        navigate={Paths.location_structure(@location.uuid)}
        class={["tab", @active == :structure && "tab-active"]}
      >
        {gettext("Structure")}
      </.link>
    </div>
    """
  end
end
