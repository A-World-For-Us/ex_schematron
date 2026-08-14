# Smoke test: every XPath expression in the schematron corpus must parse.
#
#   mix run scripts/parse_corpus.exs <dir-with-sch-files>

defmodule CorpusWalk do
  alias ExSchematron.Xml

  @expression_attrs ["test", "context", "select", "value"]

  def expressions(sch_path) do
    doc = sch_path |> File.read!() |> Xml.parse!()

    for {_id, node} <- doc.nodes,
        node.kind == :element,
        attr <- Xml.attributes(doc, node.id),
        {nil, attr_local} <- [attr.name],
        attr_local in @expression_attrs do
      {elem(node.name, 1), attr_local, attr.value}
    end
  end
end

[corpus_dir] = System.argv()

sch_files =
  corpus_dir
  |> Path.join("**/*.sch")
  |> Path.wildcard()
  |> Enum.sort()

{total, failures} =
  Enum.reduce(sch_files, {0, []}, fn path, {total, failures} ->
    expressions = CorpusWalk.expressions(path)

    failures =
      Enum.reduce(expressions, failures, fn {element, attr, source}, acc ->
        try do
          ExSchematron.XPath.Parser.parse!(source)
          acc
        rescue
          error -> [{path, element, attr, source, Exception.message(error)} | acc]
        end
      end)

    IO.puts("#{Path.basename(path)}: #{length(expressions)} expressions")
    {total + length(expressions), failures}
  end)

IO.puts("\n#{total} expressions, #{length(failures)} failures")

for {path, element, attr, source, message} <- Enum.take(failures, 20) do
  IO.puts("\n--- #{Path.basename(path)} <#{element} #{attr}=...>\n#{String.slice(source, 0, 200)}\n=> #{message}")
end

if failures != [], do: System.halt(1)
