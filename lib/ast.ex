defmodule UltraDark.AST do
  @moduledoc """
    Manipulate javascript as an abstract syntax tree. This module is responsible
    for sanitizing contracts and creating gamma charges within them
  """

  # Gamma costs are broken out into the following sets, with each item in @base costing
  # 2 gamma, each in @low costing 3, @medium costing 5 and @medium_high costing 6
  @base [:^, :==, :!=, :===, :!==, :<=, :<, :>, :>=, :instanceof, :|, :&, :"<<", :">>", :>>>, :in]
  @low [:+, :-]
  @medium [:*, :/, :%]
  @medium_high [:++, :--]
  @excluded_identifiers ["constructor", "push"]
  @sanitize_prefix "sanitized_"

  @doc """
    AST lets us analyze the structure of the contract, this is used to determine
    the computational intensity needed to run the contract
  """
  @spec generate_from_source(String.t()) :: Map
  def generate_from_source(source) do
    Execjs.eval("var e = require('esprima'); e.parse(`#{source}`)")
    |> ESTree.Tools.ESTreeJSONTransformer.convert()
  end

  @doc """
    Recursively traverse the AST generated by ESTree, and add a call to the charge_gamma
    function before each computation. This will increase the gamma counter before
    each javascript computation and will ensure that each computation is paid for
  """
  @spec remap_with_gamma(ESTree.Program) :: list
  def remap_with_gamma(map) when is_map(map) do
    cond do
      Map.has_key?(map, :body) ->
        %{map | body: remap_with_gamma(map.body)}
      Map.has_key?(map, :value) ->
        %{map | value: remap_with_gamma(map.value)}
      true ->
        map
    end
  end

  def remap_with_gamma([computation | rest], new_ast \\ []) do
    comp =
      computation
      |> remap_with_gamma

    case comp do
      %ESTree.MethodDefinition{} -> remap_with_gamma(rest, new_ast ++ [comp])
      %ESTree.ClassDeclaration{} -> remap_with_gamma(rest, new_ast ++ [comp])
      _ -> remap_with_gamma(rest, new_ast ++ [generate_gamma_charge(comp), comp])
    end
  end

  def remap_with_gamma([], new_ast), do: new_ast

  @doc """
    Takes in a computation provided by ESTree, and returns a call to the
    `UltraDark.Contract.charge_gamma` function defined in contracts/Contract.js,
    with an amount proportionate to the computational complexity of the computation.
  """
  def generate_gamma_charge(computation) do
    computation
    |> gamma_for_computation
    |> (&generate_from_source("UltraDark.charge_gamma(#{&1})").body).()
    |> List.first()
  end

  def gamma_for_computation(%ESTree.BinaryExpression{operator: operator}), do: compute_gamma_for_operator(operator)
  def gamma_for_computation(%ESTree.UpdateExpression{operator: operator}), do: compute_gamma_for_operator(operator)
  def gamma_for_computation(%ESTree.ExpressionStatement{expression: expression}), do: gamma_for_computation(expression)
  def gamma_for_computation(%ESTree.ReturnStatement{argument: argument}), do: gamma_for_computation(argument)
  def gamma_for_computation(%ESTree.VariableDeclaration{declarations: declarations}), do: gamma_for_computation(declarations)
  def gamma_for_computation(%ESTree.VariableDeclarator{init: %{value: value}}), do: calculate_gamma_for_declaration(value)
  # def gamma_for_computation(%ESTree.AssignmentExpression{ left: left }), do: IEx.pry
  def gamma_for_computation(%ESTree.CallExpression{}), do: 0
  def gamma_for_computation([first | rest]), do: gamma_for_computation(rest, [gamma_for_computation(first)])
  def gamma_for_computation([first | rest], gamma_list), do: gamma_for_computation(rest, [gamma_for_computation(first) | gamma_list])
  def gamma_for_computation([], gamma_list), do: Enum.reduce(gamma_list, fn gamma, acc -> acc + gamma end)
  def gamma_for_computation(other) do
    IO.warn("Gamma for computation not implemented for: #{other.type}")
    # IEx.pry
    0
  end

  @doc """
    Takes in a variable declaration and returns the gamma necessary to store the data
    within the contract. The cost is mapped to 2500 gamma per byte
  """
  @spec calculate_gamma_for_declaration(any) :: number
  def calculate_gamma_for_declaration(value) do
    # Is there a cleaner way to calculate the memory size of any var?
    (value |> :erlang.term_to_binary() |> byte_size) * 2500
  end

  @doc """
    Takes in a binary tree expression and returns the amount of gamma necessary
    in order to perform the expression
  """
  @spec compute_gamma_for_operator(atom) :: number | {:error, tuple}
  defp compute_gamma_for_operator(operator) when operator in @base, do: 2
  defp compute_gamma_for_operator(operator) when operator in @low, do: 3
  defp compute_gamma_for_operator(operator) when operator in @medium, do: 5
  defp compute_gamma_for_operator(operator) when operator in @medium_high, do: 6
  defp compute_gamma_for_operator(operator), do: {:error, {:no_compute_or_update_expression_gamma, operator}}


  @doc """
    Sanitizes the names of variables and functions within a contract to ensure that
    it is sandboxed. This way, if someone wanted to set gamma = 0 in their contract
    in effort to attempt to have the computations run for free, they couldn't, since
    the variable `gamma` in the contract would be compiled to `sanitized_gamma`
    before the contract is run.
  """
  def sanitize_computation(%ESTree.Identifier{name: name} = computation) when name in @excluded_identifiers, do: computation
  def sanitize_computation(%ESTree.Identifier{name: name} = computation), do: %{computation | name: @sanitize_prefix <> name}
  def sanitize_computation(%ESTree.MemberExpression{object: %{name: "UltraDark"}} = computation), do: computation

  def sanitize_computation(map) when is_map(map) do
    Map.keys(map)
    |> Enum.map(fn key -> %{key => sanitize_computation(Map.get(map, key))} end)
    |> Enum.reduce(map, fn mapping, acc ->
      [{k, v}] = Map.to_list(mapping)
      %{acc | k => v}
    end)
  end

  def sanitize_computation(list) when is_list(list), do: sanitize_computation(list, [])
  def sanitize_computation([first | rest], sanitized), do: sanitize_computation(rest, sanitized ++ [sanitize_computation(first)])
  def sanitize_computation([], sanitized), do: sanitized
  def sanitize_computation(computation), do: computation
end
