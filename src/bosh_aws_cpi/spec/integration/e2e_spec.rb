require 'open3'
require 'json'
require 'yaml'

describe 'Bosh - AWS CPI End 2 End tests' do
  before(:all) do
    config_filename = ENV['E2E_CONFIG_FILENAME']            || raise('Missing E2E configuration file')
    configuration = File.open(config_filename) { |f| JSON.parse(f.read) }
    @director_ip = configuration['director_ip']             || raise('missing configuration entry: "director_ip"')
    @manifest_filename = configuration['manifest_filename'] || raise('missing configuration entry: "manifest_filename"')
    @director_username = configuration['director_username'] || raise('missing configuration entry: "director_username"')
    @director_password = configuration['director_password'] || raise('missing configuration entry: "director_password"')
    @stemcell = configuration['stemcell']                   || raise('missing configuration entry: "stemcell"')
    @release = configuration['release']                     || raise('missing configuration entry: "release"')
    @deployment_name = configuration['deployment_name']     || raise('missing configuration entry: "deployment_name"')

    run_command("bosh -n target #{@director_ip}")
    run_command("bosh login #{@director_username} #{@director_password}")
    run_command("bosh upload stemcell #{@stemcell} --skip-if-exists")
    run_command("bosh deployment #{@manifest_filename}")
  end

  after(:all) do
    run_command("bosh -n delete deployment #{@deployment_name}")
    run_command('bosh -n cleanup --all')
  end

  context 'with dynamic networking' do

    context 'with IAM instance profile' do
      it 'properly sets IAM instance profile' do
        run_command('bosh -n deploy')
        run_command('bosh run errand iam-instance-profile-test')
      end

      context 'with raw ephemeral disk' do
        let(:manifest) { YAML.load_file(@manifest_filename) }

        after(:each) do
          File.open(@manifest_filename,'w') do |h|
            h.write manifest.to_yaml
          end
        end

        it 'properly sets up raw ephemeral disk' do
          new_manifest = manifest.dup
          new_manifest['resource_pools'].first['cloud_properties']['raw_instance_storage'] = true
          File.open(@manifest_filename,'w') do |h|
            h.write new_manifest.to_yaml
          end

          run_command('bosh -n deploy')
          run_command('bosh run errand raw-ephemeral-disk-test')
        end
      end
    end
  end

  def run_command(command)
    puts "\nRunning command '#{command}'..."

    start_time = Time.now
    stdout_string, stderr_string, status = Open3.capture3(command)
    finish_time = Time.now

    stdout_string.split(/\n/).map do |line|
      puts "stdout: #{line}"
    end

    stderr_string.split(/\n/).map do |line|
      puts "stderr: #{line}"
    end

    puts "...'#{command}' exited with status #{status.exitstatus} after #{compute_duration(start_time, finish_time)}\n"
    expect(status.exitstatus).to be(0)
  end

  def compute_duration(start, finish)
    seconds = (finish - start) % 60
    minutes = (((finish - start) / 60)).to_i
    sprintf("%02d:%02d (MM:SS)", minutes, seconds)
  end
end
