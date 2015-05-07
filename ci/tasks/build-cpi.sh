#!/usr/bin/env bash

set -e -x

echo "building CPI release..."
pushd bosh-cpi-release
bosh create release --name $cpi_release_name --version 0.0.0 --with-tarball
popd

mkdir out
mv bosh-cpi-release/dev_releases/$cpi_release_name/$cpi_release_name-0.0.0.tgz out/$cpi_release_name.tgz
