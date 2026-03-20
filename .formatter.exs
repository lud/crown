[
  plugins: [Quokka],
  quokka: [
    autosort: [],
    exclude: [
      # quokka sucks at formatting config
      :configs,
      # Do not turn assert into refute
      :tests
    ]
  ],
  import_deps: [:ecto, :ecto_sql],
  force_do_end_blocks: true,
  inputs: ["*.{ex,exs}", "{config,lib,test,tmp}/**/*.{ex,exs}"]
]
