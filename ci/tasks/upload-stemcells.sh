#!/usr/bin/env bash

set -e

: ${BOSH_CLIENT:?}
: ${BOSH_CLIENT_SECRET:?}
: ${STEMCELL_NAME:?}
: ${HEAVY_STEMCELL_NAME:?}
: ${METADATA_FILE:=environment/metadata}

# inputs
stemcell_path="$(realpath stemcell/*.tgz)"
heavy_stemcell_path="$(realpath heavy-stemcell/*.tgz)"
bosh_cli=$(realpath bosh-cli/bosh-cli-*)
chmod +x $bosh_cli

export DIRECTOR_IP=$(jq -e --raw-output ".DirectorEIP" "${METADATA_FILE}")
export BOSH_ENVIRONMENT="${DIRECTOR_IP//./-}.sslip.io"

time $bosh_cli -n upload-stemcell "${stemcell_path}"
time $bosh_cli -n upload-stemcell "${heavy_stemcell_path}"
