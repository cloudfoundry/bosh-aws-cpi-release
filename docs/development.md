## Development

### Unit tests

The CPI Ruby code has unit tests that can be run as follows.

```bash
./src/bosh_aws_cpi/bin/test-unit
```

### Running ERB job templates unit tests

The ERB templates rendered by the jobs of this Bosh Release have specific unit
tests that are run along with the other unit tests as instructed above. When
required, you can run them separately though, with this command:

```bash
./src/bosh_aws_cpi/bin/test-unit spec/unit/bosh_release
```

### Creating a Release

The release requires Ruby version 3.1.0 and the Ruby gem Bundler (used by the vendoring script):

```
gem install bundler
```

With bundler installed, run the vendoring script from `src/bosh_aws_cpi`:

```
./vendor_gems
```

Then create the BOSH release from the root directory:

```
bosh create-release --force
```

The release is now ready for use. If everything works, commit the changes including the updated gems.

### Manually run lifecycle tests

Our script uses terraform to prepare an environment on ec2 for lifecycle tests.
You must provide the proper access credentials as well as a KMS Key and Key
Pair fixture. Terraform will create all other required resources and destroy
them at the end of a successful test run. If tests fail, terraform will leave
the environment as is for debugging.

1. Create a `lifecycle.env` file containing the 4 required environment variables. The key
pair name must exist in the ec2 console; however, you do not need to have a copy
of it on your local system.
  ```bash
  export AWS_ACCESS_KEY_ID="AKIAINSxxxxxxxxxxxxx"
  export AWS_SECRET_ACCESS_KEY="LvgQOmCtjL1yhcxxxxxxxxxxxxxxxxxxxxxxxxxx"

  # KMS keys used for encrypted disk tests
  export BOSH_AWS_KMS_KEY_ARN="arn:aws:kms:us-east-1:..."
  export BOSH_AWS_KMS_KEY_ARN_OVERRIDE="arn:aws:kms:us-east-1:..."

  # Optionally use alternate region
  # export AWS_DEFAULT_REGION="us-west-1"

  # Optionally use STS Tokens
  # export AWS_SESSION_TOKEN="xxxxxxxx"
  ```
1. source your `lifecycle.env` file
  ```bash
  . ~/scratch/aws/lifecycle.env
  ```
1. Run tests
  ```bash
  src/bosh_aws_cpi/bin/test-integration
  ```
  * Use `RSPEC_ARGUMENTS` to run a subset of tests
    ```bash
    RSPEC_ARGUMENTS=spec/integration/lifecycle_spec.rb:247 src/bosh_aws_cpi/bin/test-integration
    ```
  * Use the `keep-alive` option to keep the terraform environment around even if tests are successful
    ```bash
    src/bosh_aws_cpi/bin/test-integration keep-alive
    ```
  * Use the `destroy` option to destroy the terraform environment without running tests
    ```bash
    src/bosh_aws_cpi/bin/test-integration destroy
    ```


This script will only terraform one environment per workstation. For example,
if your workstation was named `moncada`, it would create a VPC named
`moncada-local-integration` and associated resources.


### Ad-hoc testing

When you need to terraform a VPC but don't need to run tests (e.g. you're deploying a BOSH director for tests), do the following:

* comment-out the last two lines in `src/bosh_aws_cpi/bin/test-integration` (run tests & destroy environment)

```bash
. ~/scratch/aws/lifecycle.env
src/bosh_aws_cpi/bin/test-integration
bosh create-env ~/scratch/aws/bosh-minimal.yml \
  -v PublicSubnetID=$(jq -r '.modules[0].outputs.PublicSubnetID.value' < /tmp/integration-terraform-state-us-west-1.tfstate) \
  -v DeploymentEIP=$(jq -r '.modules[0].outputs.DeploymentEIP.value' < /tmp/integration-terraform-state-us-west-1.tfstate) \
  -v access_key_id=$AWS_ACCESS_KEY_ID \
  -v secret_access_key=$AWS_SECRET_ACCESS_KEY
```
* run `src/bosh_aws_cpi/bin/test-integration`

### Rubymine support

Given the `Bosh Release` nature of this project, the ruby project content is under `src/bosh_aws_cpi` which does not
work for RubyMine when trying to locate the Gemfile to run the RSpec tests.  To resolve this you can modify the
RubyMine project in the following way:

- Edit `Project Structure`
  - Go To: `Preferences` -> `Project: [project name]` -> `Project Structure`
  - Remove the existing Content Root which would by default be the Projects root
  - Add a new Context Root for each of the projects root folders except for `src`
  - Add a new Content Root `src/bosh_aws_cpi`
  - Select the `src/bosh_aws_cpi` content root and add the `spec` sub-folder as a `Tests` source
  - Save and exit the `Preferences` dialogue
- Edit `The default RSpec Run Configuration`
  - Open `Edit Configurations` dialog
  - Go into `defaults` -> `RSpec`
    - Go to the `Bundler` tab
      - ensure 'Run the script in the context of the bundle (bundle exec)' is checked
    - Go to the `Configuration` tab
      - set the `Working Directory` value to the path to `[project root]/src/bosh_aws_cpi`
    - Remove an temporary Rspec configurations that exist to ensure new defaults are applied to all test
    - Save and exit the `Run Configurations` dialogue
- Run a focused RSpec test to verify it works.
