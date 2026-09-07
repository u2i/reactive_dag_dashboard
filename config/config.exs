import Config

# Ash 3.33 requires an explicit choice and refuses to compile a resource
# without one. It reaches this library only through `test/support`, which
# defines Ash resources for the fixture graph — and those are compiled at BUILD
# time, before `test_helper.exs` runs, so the setting cannot live there.
#
# `:codepoints` is Ash's own recommendation: it is how SQL data layers count,
# so validation agrees with the database and `max_length` actually bounds the
# size of a stored value. `:mixed` preserves the pre-3.33 behaviour, under which
# a single grapheme can hold unboundedly many combining characters and
# `max_length` bounds nothing.
#
# Nothing this library SHIPS uses string constraints — a host's own config wins
# for a host's own resources, and this file is not part of the published
# package's runtime configuration.
config :ash, default_string_length_count: :codepoints
