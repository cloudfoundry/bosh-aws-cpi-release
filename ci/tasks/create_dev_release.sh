#!/usr/bin/env bash

set -e -x

mkdir out

echo "building CPI release..."
cd bosh-cpi-repo
bosh create release --name $cpi_release_name --version 0.0.0 --with-tarball

mv dev_releases/$cpi_release_name/$cpi_release_name-0.0.0.tgz ../out/$cpi_release_name.tgz
