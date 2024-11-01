#!/usr/bin/env bash
set -eu -o pipefail

pushd bosh-cpi-src/src/bosh_aws_cpi

  bundle install

  bundle exec rake rubocop

  bundle exec rake spec:unit

popd