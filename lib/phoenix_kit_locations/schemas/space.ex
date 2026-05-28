defmodule PhoenixKitLocations.Schemas.Space do
  @moduledoc """
  A nested space inside a `Location` — a floor, room, zone, etc.

  Spaces form a filesystem-like tree per Location: each row belongs to
  exactly one Location (required FK) and may optionally belong to a
  parent Space (self-ref FK), forming arbitrary-depth nesting.

  ## Translatable fields

  `name` and `description` are translatable. Primary-language values
  stay in the dedicated columns; secondary languages live under a
  language-code key in `data`, e.g.:

      %{ "es-ES" => %{ "name" => "Planta 2" } }

  Top-level keys in `data` carry attachment pointers
  (`files_folder_uuid`, `featured_image_uuid`), mirroring how
  `phoenix_kit_locations.data` is used.

  ## Kind

  `kind` is a fixed string from `@kinds`. The DB CHECK constraint in
  V122 mirrors the same list — keep both in sync if a new label is
  added.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKitLocations.Schemas.Location

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  # V1 of the Spaces UI only exposes two kinds: floor (top-level
  # subdivision of a location) and room (children of a floor). The DB
  # CHECK constraint (V122 in core) intentionally still allows a wider
  # set so we can grow into it without an immediate migration when
  # halls/suites/aisles/etc. become useful again — narrowing happens
  # in app-layer validation here.
  @kinds ~w(floor room)
  @statuses ~w(active inactive)

  schema "phoenix_kit_location_spaces" do
    field(:kind, :string)
    field(:name, :string)
    field(:description, :string)
    field(:notes, :string)
    field(:status, :string, default: "active")
    field(:position, :integer, default: 0)
    field(:data, :map, default: %{})

    belongs_to(:location, Location, foreign_key: :location_uuid, references: :uuid)
    belongs_to(:parent, __MODULE__, foreign_key: :parent_uuid, references: :uuid)

    has_many(:children, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  @required_fields [:location_uuid, :kind, :name]
  @optional_fields [
    :parent_uuid,
    :description,
    :notes,
    :status,
    :position,
    :data
  ]

  @doc """
  Form-facing changeset.

  Note: the "child belongs to the same Location as its parent"
  guarantee is enforced in the `PhoenixKitLocations.Spaces` context,
  not here — the schema doesn't have parent context to compare
  against without an extra DB read. Keep that invariant load-bearing
  on the context.
  """
  def changeset(space, attrs) do
    space
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:description, max: 2000)
    |> validate_length(:notes, max: 5000)
    |> validate_no_self_parent()
    |> assoc_constraint(:location)
    |> assoc_constraint(:parent)
    |> check_constraint(:kind,
      name: :phoenix_kit_location_spaces_kind_check,
      message: "must be one of: #{Enum.join(@kinds, ", ")}"
    )
    |> check_constraint(:status,
      name: :phoenix_kit_location_spaces_status_check,
      message: "must be one of: #{Enum.join(@statuses, ", ")}"
    )
  end

  # Mirrors the DB self-ref FK's "no cycles via direct self-loop" guard.
  # Doesn't catch indirect cycles (A → B → A) — that's a context-layer
  # check before any UPDATE that re-parents a node.
  defp validate_no_self_parent(changeset) do
    case {get_field(changeset, :uuid), get_change(changeset, :parent_uuid)} do
      {nil, _} -> changeset
      {_, nil} -> changeset
      {uuid, uuid} -> add_error(changeset, :parent_uuid, "cannot be its own parent")
      _ -> changeset
    end
  end

  def kinds, do: @kinds
  def statuses, do: @statuses
end
