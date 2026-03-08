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
  end
end
