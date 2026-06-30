deps:
  mix deps.get

test:
  mix test

format:
  mix format --migrate

readmix:
  mix rdmx.update README.md
  # rg rdmx guides -l0 | xargs -0 -n 1 mix rdmx.update

docs: readmix
  mix docs --warnings-as-errors

migrate:
  MIX_ENV=test mix ecto.create --repo Crown.TestRepo
  MIX_ENV=test mix ecto.migrate --repo Crown.TestRepo

_libdev_check:
  mix libdev.check

_git_status:
  git status

check: format readmix _libdev_check _git_status
