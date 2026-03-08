defmodule ExPgQuery.TreeWalker do
  @moduledoc """
  Traverses a `PgQuery` AST and yields each visited node to a callback.

  This module is a compatibility wrapper over `ExPgQuery.AST.reduce/4`.
  """

  alias ExPgQuery.AST
  alias ExPgQuery.AST.Visit

  @doc """
  Walks through a protobuf message tree, applying a callback function to each node.
  """
  def walk(tree, acc, callback) when is_function(callback, 4) do
    AST.reduce(tree, acc, fn %Visit{} = visit, acc ->
      callback.(visit.parent, visit.field, {visit.node, visit.path}, acc)
    end)
  end
end
