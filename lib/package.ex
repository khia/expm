defmodule Expm.Package.Decoder do
  defexception SecurityException, message: nil
  def decode({ :__block__, _, [b] }) when is_list(b) do
    decode(b)
  end    
  def decode(list) when is_list(list) do
    lc i inlist list, do: decode(i)
  end  
  def decode({:access,l1,[{:__aliases__,l2,[:Expm,:Package]}|rest]}) do
    {:access,l1,[{:__aliases__,l2,[:Expm,:Package]}|decode_1(rest)]}
  end
  def decode(v) do
    raise SecurityException.new(message: "#{Macro.to_binary(v)} is not allowed")  
  end

  defp decode_1({ :{}, b, c }) do
    {:{}, b, decode_1(c) }
  end

  defp decode_1({ _a, _b, _c }=v) do
    raise SecurityException.new(message: "#{Macro.to_binary(v)} is not allowed")
  end

  defp decode_1({ a, b }) do
    { decode_1(a), decode_1(b) }
  end

  defp decode_1(list) when is_list(list) do
    lc i inlist list, do: decode_1(i)
  end

  defp decode_1(other) do
    other
  end
end

defrecord Expm.Package, 
  metadata: [],
  # required
  name: nil,
  description: nil,
  version: nil,
  keywords: [],
  maintainers: [],
  contributors: [],
  bugs: [],
  licenses: [],
  repositories: [],
  dependencies: [],
  # optional
  homepage: nil,
  platforms: [],
  directories: ["src","lib","priv","include"] do

    @type name :: binary
    @type spec :: list(term)
    @type filter :: spec
    @type version :: term

  import Expm.Utils

  deflist keywords, keyword
  deflist maintainers, maintainer  
  deflist contributors, contributor
  deflist bugs, bug
  deflist licenses, license
  deflist repositories, repository
  deflist dependencies, dependency
  deflist directories, directory
  deflist platforms, platform

  def encode(rec) do
    inspect(rec)
  end

  def decode(text) do
    ast = Code.string_to_ast! text
    {v, _} = Code.eval_quoted Expm.Package.Decoder.decode(ast)
    v
  end

  def publish(repo, package) do
    Expm.Repository.put repo, package
  end

  def fetch(repo, package) do
    case Enum.reverse(versions(repo, package)) do
     [] -> :not_found
     [top|_] -> fetch(repo, package, top)
    end
  end

  def fetch(repo, package, version) do
    if is_binary(version) and 
       Regex.match?(%r/^[a-z]+.*/i,version) do # symbolic name
      version = binary_to_atom(version) ## FIXME?
    end

    Expm.Repository.get repo, package, version
  end

  def versions(repo, package) do
    List.sort(Expm.Repository.versions repo, package)
  end

  def filter(repo, package) do
    pkgs = 
    Enum.reduce Expm.Repository.list(repo, package),
                [],
                fn(package, acc) ->
                  case :proplists.get_value(package.name, acc, nil) do
                    nil -> [{package.name, package}|acc]
                    another_package ->
                      if another_package.version < package.version do
                         [{package.name, package}|(acc -- [{package.name, another_package}])]
                      else
                         acc
                      end
                  end
                end
    pkgs = lc {_, pkg} inlist pkgs, do: pkg
    pkgs = List.sort pkgs, fn(pkg1, pkg2) -> pkg1.name <= pkg2.name end
  end

  def all(repo) do
    filter repo, Expm.Package[_: :_]
  end

  def search(repo, keyword) do
    pkgs = all(repo)
    re = %r/.*#{keyword}.*/i
    Enum.filter pkgs, fn(pkg) ->
                        Regex.match?(re,pkg.name || "") or
                        Regex.match?(re,pkg.description || "") or
                        Enum.any?(String.split(pkg.keywords, %r(,|\s), global: true),
                                  fn(kwd) -> Regex.match?(re, kwd) end)
                      end
  end

  def read(file // "package.exs") do
    {:ok, bin} = File.read(file)
    {pkg, _} = Code.eval bin
    pkg
  end

end