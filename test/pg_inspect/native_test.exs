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

    test "returns zero-based cursor positions for parse errors" do
      sql = "SELECT * FROM x WHERE y = ?"

      assert {:error, %{message: message, cursorpos: 27}} =
               PgInspect.Native.parse_protobuf(sql)

      assert message =~ "syntax error"
    end

    test "returns zero-based cursor positions for scan errors" do
      sql = <<39>>

      assert {:error, %{message: message, cursorpos: 0}} =
               PgInspect.Native.scan(sql)

      assert message =~ "unterminated quoted string"
    end
  end
end
