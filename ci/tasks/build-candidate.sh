#!/usr/bin/env bash

set -e

source bosh-cpi-src/ci/utils.sh

semver=`cat version-semver/number`

pushd bosh-cpi-src
  echo "running unit tests"
  pushd src/bosh_aws_cpi
    bundle install
    bundle exec rspec spec/unit/*
    ./vendor_gems
  popd

  cpi_release_name="bosh-aws-cpi"

  echo "building CPI release..."
  bosh create-release --name $cpi_release_name --version $semver --tarball ../candidate/$cpi_release_name-$semver.tgz
popd
