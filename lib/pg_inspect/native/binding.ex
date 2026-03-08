defmodule PgInspect.Native.Binding do
  @moduledoc false

  @project_root Path.expand("../../..", __DIR__)
  @libpg_query_root Path.join(@project_root, "libpg_query")
  @erlang_include_path Path.join(
                         [to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}", "include"]
                       )
  @include_dirs [
    @erlang_include_path,
    @libpg_query_root,
    Path.join(@libpg_query_root, "src"),
    Path.join(@libpg_query_root, "vendor"),
    Path.join(@libpg_query_root, "src/include"),
    Path.join(@libpg_query_root, "src/postgres/include"),
    Path.join(@libpg_query_root, "protobuf")
  ]
  @precompiled_url [
    "https://github.com/hlindset/pg_inspect/releases/download/v#VERSION/",
    "Elixir.PgInspect.Native.Binding.#VERSION.#TRIPLE.#EXT"
  ]
  @precompiled_shas [
    {:"aarch64-freebsd-none", "130ae06e7ef35cbad8058e10914d114b90e073ec0c256c6014aaffb93fb3779b"},
    {:"aarch64-linux-gnu", "f3c27d828b367f12aedf93a9ca496cae682762ba2269a9901dd2bac8032b0cbd"},
    {:"aarch64-linux-musl", "feabbf1a1ef81c43d0289fa775286c288f5124f967b3b564851f54dc946ef463"},
    {:"aarch64-macos-none", "33e4ba534109c6c5fd595537f806fae3fef3a23ac41fd7b495683b9345f11dd2"},
    {:"arm-linux-gnueabi", "ac362e0ae9bcb281115360ad08db7220024846bb8c96a2dc534b692e74162579"},
    {:"arm-linux-gnueabihf", "a6f438b80cfddc6266461ce40bbf3dc20365c4981670ed855ca46cee0bb31f4c"},
    {:"arm-linux-musleabi", "dd82c535469fb979a24792c1ee5a4e155c2888cd6125474c6e35332265936e9b"},
    {:"arm-linux-musleabihf", "8511ef9d410cdd01b3134a4c199c0b547f1b62eb0c0100931b8e105d0ebf1042"},
    {:"x86_64-freebsd-none", "894e58d9e7fc9fcfb35dcc7a802a8eb2054426dfbc6882f66362785bd55126f2"},
    {:"x86_64-linux-gnu", "a0fc0fad54f735ce3a778c9209b86d50ce8a372254f41fa5078d94e41fabe6ab"},
    {:"x86_64-linux-musl", "737cfac7f69bfeca58876f157e769a3dd31fed42eeb1016cb81c932257e9a178"},
    {:"x86_64-macos-none", "599afb55b45ab6591ff3e7db8fdad916ca8479435eb69e699b405721cd6b1085"}
  ]
  @c_flags [
    "-Wall",
    "-Wno-unused-function",
    "-Wno-unused-value",
    "-Wno-unused-variable",
    "-fno-strict-aliasing",
    "-fwrapv"
    | Enum.map(@include_dirs, &"-I#{&1}")
  ]
  @c_sources (
               Path.wildcard(Path.join(@libpg_query_root, "src/*.c")) ++
                 Path.wildcard(Path.join(@libpg_query_root, "src/postgres/*.c")) ++
                 [
                   Path.join(__DIR__, "uint64_shim.c"),
                   Path.join(@libpg_query_root, "vendor/protobuf-c/protobuf-c.c"),
                   Path.join(@libpg_query_root, "vendor/xxhash/xxhash.c"),
                   Path.join(@libpg_query_root, "protobuf/pg_query.pb-c.c")
                 ]
             )
             |> Enum.sort()
             |> Enum.map(&{&1, @c_flags})

  if File.exists?(Path.join(@project_root, ".git")) do
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
