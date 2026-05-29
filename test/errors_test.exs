defmodule PhoenixKitLocations.ErrorsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitLocations.Errors

  describe "message/1 known atoms" do
    test ":location_not_found" do
      assert Errors.message(:location_not_found) == "Location not found."
    end

    test ":location_type_not_found" do
      assert Errors.message(:location_type_not_found) == "Location type not found."
    end

    test ":location_delete_failed" do
      assert Errors.message(:location_delete_failed) == "Failed to delete location."
    end

    test ":location_type_delete_failed" do
      assert Errors.message(:location_type_delete_failed) == "Failed to delete location type."
    end

    test ":type_assignment_failed" do
      assert Errors.message(:type_assignment_failed) ==
               "Saved but failed to update type assignments."
    end

    test ":space_not_found" do
      assert Errors.message(:space_not_found) == "Space not found."
    end

    test ":parent_in_other_location" do
      assert Errors.message(:parent_in_other_location) ==
               "The chosen parent space belongs to a different location."
    end

    test ":parent_not_found" do
      assert Errors.message(:parent_not_found) ==
               "The chosen parent space no longer exists."
    end

    test ":cycle" do
      assert Errors.message(:cycle) == "Cannot make a space its own ancestor."
    end

    test ":parent_floor_unsaved" do
      assert Errors.message(:parent_floor_unsaved) ==
               "its parent floor was not saved (it might need a name)"
    end

    test ":unexpected" do
      assert Errors.message(:unexpected) == "An unexpected error occurred."
    end
  end

  describe "message/1 fallback" do
    test "passes strings through unchanged" do
      assert Errors.message("already a string") == "already a string"
    end

    test "renders unknown atoms via inspect" do
      assert Errors.message(:some_new_atom) == "Unexpected error: :some_new_atom"
    end

    test "renders tuples via inspect" do
      assert Errors.message({:weird, :tuple}) == "Unexpected error: {:weird, :tuple}"
    end

    test "renders maps via inspect" do
      assert Errors.message(%{a: 1}) == "Unexpected error: %{a: 1}"
    end
  end
end
