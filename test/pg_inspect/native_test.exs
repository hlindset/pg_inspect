defmodule PgInspect.NativeTest do
  use ExUnit.Case

  doctest PgInspect.Native

  describe "SQL NIFs" do
    test "reject binaries containing null bytes" do
      sql = <<"SELECT 1", 0, " SELECT 2">>

      assert {:error, "argument must not contain null bytes"} ==
               PgInspect.Native.parse_protobuf(sql)

      assert {:error, "argument must not contain null bytes"} ==
               PgInspect.Native.scan(sql)

      assert {:error, "argument must not contain null bytes"} ==
               PgInspect.Native.fingerprint(sql)

      assert {:error, "argument must not contain null bytes"} ==
               PgInspect.Native.normalize(sql)
    end

    test "serializes concurrent libpg_query calls safely" do
      sql = "SELECT id, name FROM users WHERE id = 42"

      1..100
      |> Task.async_stream(
        fn i ->
          case rem(i, 4) do
            0 ->
              assert {:ok, _} = PgInspect.Native.parse_protobuf(sql)

            1 ->
              assert {:ok, _} = PgInspect.Native.scan(sql)

            2 ->
              assert {:ok, %{fingerprint_str: _}} = PgInspect.Native.fingerprint(sql)

            3 ->
              assert {:ok, _} = PgInspect.Native.normalize(sql)
          end
        end,
        max_concurrency: 16,
        timeout: 5_000
      )
      |> Enum.to_list()
    end
  end
end
