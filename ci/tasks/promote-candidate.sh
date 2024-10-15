#!/usr/bin/env bash

set -e

: ${AWS_ACCESS_KEY_ID:?}
: ${AWS_SECRET_ACCESS_KEY:?}
: ${AWS_ASSUME_ROLE_ARN:?}

version_to_cut=$(cat release-version-semver/version)

cp -r bosh-cpi-src promoted/repo

dev_release=$(echo $PWD/bosh-cpi-release/*.tgz)

pushd promoted/repo
  echo creating config/private.yml with blobstore secrets
  cat > config/private.yml << EOF
---
blobstore:
  provider: s3
  options:
    access_key_id: $AWS_ACCESS_KEY_ID
    secret_access_key: $AWS_SECRET_ACCESS_KEY
    assume_role_arn: $AWS_ASSUME_ROLE_ARN
EOF

  echo "finalizing CPI release..."
  bosh finalize-release "${dev_release}" --version "${version_to_cut}"

  rm config/private.yml

  git diff | cat
  git add .

  git config --global user.email cf-bosh-eng@pivotal.io
  git config --global user.name CI
  git commit -m "New final release v${version_to_cut}"
popd

echo "" > release-metadata/empty-file-to-clear-release-notes
cat <<EOF > release-metadata/release-name
v${version_to_cut}
EOF
