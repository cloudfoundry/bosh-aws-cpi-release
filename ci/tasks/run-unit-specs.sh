#!/usr/bin/env bash
set -eu -o pipefail

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/../.." && pwd )"
REPO_PARENT="$( cd "${REPO_ROOT}/.." && pwd )"

pushd "${REPO_PARENT}/bosh-aws-cpi-release/src/bosh_aws_cpi"

  bundle install

  bundle exec rake rubocop

  bundle exec rake spec:unit

popd
