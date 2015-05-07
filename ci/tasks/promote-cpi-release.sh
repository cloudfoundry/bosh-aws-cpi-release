#!/usr/bin/env bash

set -e -x

cd bosh-cpi-release

cat > config/private.yml << EOF
---
blobstore:
  s3:
    access_key_id: $aws_access_key_id
    secret_access_key: $aws_secret_access_key
EOF

bosh finalize release bosh-cpi-dev-release/$cpi_release

# Be extra careful about not committing private.yml
rm config/private.yml

git diff | cat
git add .

git config --global user.email $git_email
git config --global user.name $git_user
git commit -m "New final release"
