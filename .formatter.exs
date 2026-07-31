locals_without_parens = [
  field: 2,
  field: 3,
  embeds_one: 2,
  embeds_one: 3,
  embeds_many: 3
]

[
  inputs: ["{mix,.formatter}.exs", "{bench,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
