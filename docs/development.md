## Development

The release requires the Ruby gem Bundler (used by the vendoring script):

```
gem install bundler
```

With bundler installed, run the vendoring script:

```
./scripts/vendor_gems
```

Then create the BOSH release:

```
bosh create release --force
```

The release is now ready for use. If everything works, commit the changes including the updated gems.

### Manually deploy bosh director

1. Claim env from pool
  1. `cd ~/workspace/bosh-cpi-environments`
  1. `git mv aws/unclaimed/SOME_ENV aws/claimed/`
  1. `git ci -m "manually claiming SOME_ENV for testing on #STORY_ID"`
  1. `git push`
1. Create a file containing necessary environment variables in `~/scratch`
  1. `source ~/scratch/YOUR_ENV_FILE`
1. Generate bosh-init manifest and Artifacts
  1. `METADATA_FILE=~/workspace/bosh-cpi-environments/aws/claimed/SOME_ENV \
       OUTPUT_DIR=~/scratch/OUTPUT_DIR \
       ./ci/tasks/prepare-director.sh`
1. Deploy with bosh-init
  1. `cd ~/scratch/OUTPUT_DIR`
  1. `bosh-init deploy director.yml`

### Manually run lifecycle tests

1. Claim env from pool
1. Create a file containing necessary environment variables in `~/scratch`
1. Run tests
  1. `RSPEC_ARGUMENTS=spec/integration/lifecycle_spec.rb \
        METADATA_FILE=~/workspace/bosh-cpi-environments/aws/claimed/SOME_ENV \
        ./ci/tasks/run-integration.sh`

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
