#!/usr/bin/env bash

set -e

source bosh-cpi-src/ci/utils.sh
source /etc/profile.d/chruby.sh
chruby 2.1.2

semver=`cat version-semver/number`

pushd bosh-cpi-src
  echo "running unit tests"
  pushd src/bosh_aws_cpi
    bundle install
    bundle exec rspec spec/unit/*
  popd

  cpi_release_name="bosh-aws-cpi"

  echo "building CPI release..."
  bosh2 create-release --name $cpi_release_name --version $semver --tarball ../candidate/$cpi_release_name-$semver.tgz
popd
