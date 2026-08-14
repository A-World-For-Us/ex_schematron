# Generates mutant files of an XML invoice for differential testing with Saxon.
#
#   mix run scripts/gen_mutants.exs SOURCE.xml OUT_DIR

[source_path, out_dir] = System.argv()
File.mkdir_p!(out_dir)

mutants = ExSchematron.Mutator.mutants(File.read!(source_path), Path.basename(source_path, ".xml"))

for {name, xml} <- mutants, do: File.write!(Path.join(out_dir, name <> ".xml"), xml)

IO.puts("#{Path.basename(source_path)}: #{length(mutants)} mutants in #{out_dir}")
