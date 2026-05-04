deps:
  mix deps.get

test:
  mix test

_mix_format:
  mix format

_mix_check:
  mix check

_git_status:
  git status

docs:
  mix rdmx.update README.md
  # rg rdmx guides -l0 | xargs -0 -n 1 mix rdmx.update
  mix docs --warnings-as-errors

migrate:
  MIX_ENV=test mix ecto.migrate --repo Crown.TestRepo

check: deps _mix_format _mix_check docs _git_status