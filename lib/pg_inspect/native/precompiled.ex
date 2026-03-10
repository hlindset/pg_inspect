defmodule PgInspect.Native.Precompiled do
  @moduledoc false

  @project_root Path.expand("../../..", __DIR__)
  @artifact_dir Path.join(@project_root, "lib/pg_inspect/native/lib")
  @checksum_file Path.join(@project_root, "checksum.exs")
  @binding_file Path.join(@project_root, "lib/pg_inspect/native/binding.ex")
  @module_prefix "Elixir.PgInspect.Native.Binding"
  @release_repo "hlindset/pg_inspect"
  @release_url_template "https://github.com/#{@release_repo}/releases/download/v#VERSION/#{@module_prefix}.#VERSION.#TRIPLE.#EXT"

  def project_root, do: @project_root
  def artifact_dir, do: @artifact_dir
  def checksum_file, do: @checksum_file
  def binding_file, do: @binding_file
  def binding_file_relative, do: Path.relative_to(@binding_file, @project_root)
  def module_prefix, do: @module_prefix
  def release_repo, do: @release_repo
  def release_url_template, do: @release_url_template

  def release_tag(version), do: "v#{version}"

  def artifact_prefix(version), do: "#{@module_prefix}.#{version}."

  def release_asset?(name, version), do: String.starts_with?(name, artifact_prefix(version))

  def supported_targets do
    [
      {:aarch64, :freebsd, :none},
      {:aarch64, :linux, :gnu},
      {:aarch64, :linux, :musl},
      {:aarch64, :macos, :none},
      {:arm, :linux, :gnueabi},
      {:arm, :linux, :gnueabihf},
      {:arm, :linux, :musleabi},
      {:arm, :linux, :musleabihf},
      {:x86_64, :freebsd, :none},
      {:x86_64, :linux, :gnu},
      {:x86_64, :linux, :musl},
      {:x86_64, :macos, :none}
    ]
  end
end
