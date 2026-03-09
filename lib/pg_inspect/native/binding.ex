defmodule PgInspect.Native.Binding do
  @moduledoc false

  @project_root Path.expand("../../..", __DIR__)
  @libpg_query_root Path.join(@project_root, "libpg_query")
  @checksum_file PgInspect.Native.Precompiled.checksum_file()
  @erlang_include_path Path.join([
                         to_string(:code.root_dir()),
                         "erts-#{:erlang.system_info(:version)}",
                         "include"
                       ])
  @include_dirs [
    @erlang_include_path,
    @libpg_query_root,
    Path.join(@libpg_query_root, "src"),
    Path.join(@libpg_query_root, "vendor"),
    Path.join(@libpg_query_root, "src/include"),
    Path.join(@libpg_query_root, "src/postgres/include"),
    Path.join(@libpg_query_root, "protobuf")
  ]

  @precompiled_url PgInspect.Native.Precompiled.release_url_template()

  @precompiled_shas (if File.exists?(@checksum_file) do
                       @checksum_file
                       |> Code.eval_file()
                       |> elem(0)
                     else
                       []
                     end)

  @c_flags [
    "-Wall",
    "-Wno-unused-function",
    "-Wno-unused-value",
    "-Wno-unused-variable",
    "-fno-strict-aliasing",
    "-fwrapv"
    | Enum.map(@include_dirs, &"-I#{&1}")
  ]
  @c_sources (Path.wildcard(Path.join(@libpg_query_root, "src/*.c")) ++
                Path.wildcard(Path.join(@libpg_query_root, "src/postgres/*.c")) ++
                [
                  Path.join(__DIR__, "uint64_shim.c"),
                  Path.join(@libpg_query_root, "vendor/protobuf-c/protobuf-c.c"),
                  Path.join(@libpg_query_root, "vendor/xxhash/xxhash.c"),
                  Path.join(@libpg_query_root, "protobuf/pg_query.pb-c.c")
                ])
             |> Enum.sort()
             |> Enum.map(&{&1, @c_flags})

  if @precompiled_shas == [] do
    use Zig,
      otp_app: :pg_inspect,
      zig_code_path: "binding.zig",
      optimize: :fast,
      c: [
        include_dirs: @include_dirs,
        link_lib: [{:system, "pthread"}],
        src: @c_sources
      ],
      nifs: [
        parse_protobuf: [concurrency: :dirty_cpu],
        deparse_protobuf: [concurrency: :dirty_cpu],
        fingerprint: [concurrency: :dirty_cpu],
        scan: [concurrency: :dirty_cpu],
        normalize: [concurrency: :dirty_cpu]
      ]
  else
    use Zig,
      otp_app: :pg_inspect,
      zig_code_path: "binding.zig",
      optimize: :fast,
      precompiled: {:web, @precompiled_url, @precompiled_shas},
      c: [
        include_dirs: @include_dirs,
        link_lib: [{:system, "pthread"}],
        src: @c_sources
      ],
      nifs: [
        parse_protobuf: [concurrency: :dirty_cpu],
        deparse_protobuf: [concurrency: :dirty_cpu],
        fingerprint: [concurrency: :dirty_cpu],
        scan: [concurrency: :dirty_cpu],
        normalize: [concurrency: :dirty_cpu]
      ]
  end
end
