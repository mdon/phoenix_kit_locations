defmodule PhoenixKitLocations.AttachmentsTest do
  @moduledoc """
  Pure unit tests for stateless helpers in `PhoenixKitLocations.Attachments`.
  The socket-mutating lifecycle (`init/1`, `mount/2`, `state/2`,
  `forget_scope/2`) needs a real LV socket and exercises through
  `LocationFormLiveTest` (DB-backed integration suite).
  """

  use ExUnit.Case, async: true

  alias PhoenixKitLocations.Attachments
  alias PhoenixKitLocations.Schemas.{Location, Space}

  describe "upload_name/0" do
    test "is a stable string identifier" do
      name = Attachments.upload_name()
      assert is_atom(name) or is_binary(name)
      # Returned name is what `allow_upload/3` keys off of, so two calls
      # must give the same value.
      assert Attachments.upload_name() == name
    end
  end

  describe "empty_scope_state/0" do
    test "returns the canonical empty shape with all five keys" do
      st = Attachments.empty_scope_state()

      assert st == %{
               resource: nil,
               folder_uuid: nil,
               featured_image_uuid: nil,
               featured_image_file: nil,
               files: []
             }
    end
  end

  describe "folder_name_for/1" do
    test "Location with uuid → {:ok, prefixed}" do
      uuid = Ecto.UUID.generate()
      assert {:ok, "location-" <> ^uuid} = Attachments.folder_name_for(%Location{uuid: uuid})
    end

    test "Space with uuid → {:ok, prefixed}" do
      uuid = Ecto.UUID.generate()
      assert {:ok, "location-space-" <> ^uuid} = Attachments.folder_name_for(%Space{uuid: uuid})
    end

    test "Location without uuid → :pending" do
      assert Attachments.folder_name_for(%Location{}) == :pending
    end

    test "Space without uuid → :pending" do
      assert Attachments.folder_name_for(%Space{}) == :pending
    end

    test "unknown struct → :pending" do
      assert Attachments.folder_name_for(%{some: :map}) == :pending
      assert Attachments.folder_name_for(nil) == :pending
    end
  end

  describe "format_file_size/1" do
    test "nil → em-dash" do
      assert Attachments.format_file_size(nil) == "—"
    end

    test "non-integer → em-dash" do
      assert Attachments.format_file_size("not-a-number") == "—"
      assert Attachments.format_file_size(%{}) == "—"
    end

    test "bytes under 1KB → B" do
      assert Attachments.format_file_size(0) == "0 B"
      assert Attachments.format_file_size(999) == "999 B"
    end

    test "KB range" do
      assert Attachments.format_file_size(1_000) == "1.0 KB"
      assert Attachments.format_file_size(1_500) == "1.5 KB"
    end

    test "MB range" do
      assert Attachments.format_file_size(1_000_000) == "1.0 MB"
      assert Attachments.format_file_size(2_500_000) == "2.5 MB"
    end

    test "GB range" do
      assert Attachments.format_file_size(1_000_000_000) == "1.0 GB"
      assert Attachments.format_file_size(3_700_000_000) == "3.7 GB"
    end
  end

  describe "file_icon/1" do
    test "image → photo" do
      assert Attachments.file_icon(%{file_type: "image"}) == "hero-photo"
    end

    test "video → film" do
      assert Attachments.file_icon(%{file_type: "video"}) == "hero-film"
    end

    test "audio → musical-note" do
      assert Attachments.file_icon(%{file_type: "audio"}) == "hero-musical-note"
    end

    test "archive → archive-box" do
      assert Attachments.file_icon(%{file_type: "archive"}) == "hero-archive-box"
    end

    test "PDF mime → document-text" do
      assert Attachments.file_icon(%{mime_type: "application/pdf"}) == "hero-document-text"
    end

    test "PDF mime wins over absent file_type" do
      assert Attachments.file_icon(%{file_type: nil, mime_type: "application/pdf"}) ==
               "hero-document-text"
    end

    test "unknown shape → generic document" do
      assert Attachments.file_icon(%{file_type: "text"}) == "hero-document"
      assert Attachments.file_icon(%{}) == "hero-document"
    end
  end

  describe "upload_error_message/1" do
    test ":too_large maps to user-facing string" do
      assert Attachments.upload_error_message(:too_large) == "File is too large."
    end

    test ":not_accepted maps to user-facing string" do
      assert Attachments.upload_error_message(:not_accepted) == "File type not accepted."
    end

    test ":too_many_files maps to user-facing string" do
      assert Attachments.upload_error_message(:too_many_files) == "Too many files."
    end

    test "unknown atom is rendered via inspect in the error string" do
      assert Attachments.upload_error_message(:weird_atom) ==
               "Upload error: :weird_atom"
    end

    test "tuple shapes are inspected" do
      assert Attachments.upload_error_message({:weird, :tuple}) ==
               "Upload error: {:weird, :tuple}"
    end
  end
end
