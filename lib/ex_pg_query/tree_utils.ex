defmodule ExPgQuery.TreeUtils do
  @moduledoc """
  Compatibility wrapper around the unified AST update API.
  """

  alias ExPgQuery.AST

  @type error_reason :: ExPgQuery.AST.update_error()

  @doc """
  Updates a value deep within a nested structure following the given path.
  """
  @spec update_in_tree(term(), ExPgQuery.AST.path(), (term() -> term())) ::
          {:ok, term()} | {:error, error_reason()}
  def update_in_tree(tree, path, update_fn) when is_function(update_fn, 1) do
    AST.update(tree, path, update_fn)
  end

  @doc """
  Same as `update_in_tree/3` but raises on error.
  """
  @spec update_in_tree!(term(), ExPgQuery.AST.path(), (term() -> term())) :: term()
  def update_in_tree!(tree, path, update_fn) when is_function(update_fn, 1) do
    AST.update!(tree, path, update_fn)
  end

  @doc """
  Convenience function for setting a value directly in a nested structure.
  """
  @spec put_in_tree(term(), ExPgQuery.AST.path(), term()) ::
          {:ok, term()} | {:error, error_reason()}
  def put_in_tree(tree, path, value) do
    AST.put(tree, path, value)
  end
end
