#!/usr/bin/env bash
set -eu -o pipefail
set -x

go run github.com/genevieve/leftovers/cmd/leftovers@latest \
  --debug \
  --no-confirm \
  --iaas=aws \
  --filter=awscpi
