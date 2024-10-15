#!/usr/bin/env bash
set -eu -o pipefail

semver=$(cat version-semver/number)
cpi_release_name="bosh-aws-cpi"

pushd bosh-cpi-src
  echo "building CPI release..."
  bosh create-release \
    --name "${cpi_release_name}" \
    --version "${semver}" \
    --tarball "../candidate/${cpi_release_name}-${semver}.tgz"
popd
