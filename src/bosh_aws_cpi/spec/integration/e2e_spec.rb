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

    bosh("-n target #{@director_ip}")
    bosh("login #{@director_username} #{@director_password}")
    bosh_uuid = bosh("status --uuid")
    edit_manifest { |manifest| manifest["director_uuid"] = bosh_uuid.strip }
    bosh("upload stemcell #{@stemcell} --skip-if-exists")
    bosh("upload release #{@release} --skip-if-exists")
    bosh("deployment #{@manifest_filename}")
    bosh('-n deploy')
  end

  after(:all) do
    bosh("-n delete deployment #{@deployment_name}")
    bosh('-n cleanup --all')
  end

  context 'with dynamic networking' do
    context 'with IAM instance profile' do
      it 'properly sets IAM instance profile' do
        bosh('run errand iam-instance-profile-test')
      end

      context 'with raw ephemeral disk' do
        it 'properly sets up raw ephemeral disk' do
          bosh('run errand raw-ephemeral-disk-test')
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

    stdout_string
  end

  def bosh(args)
    run_command("bosh #{args}")
  end

  def compute_duration(start, finish)
    seconds = (finish - start) % 60
    minutes = (((finish - start) / 60)).to_i
    sprintf("%02d:%02d (MM:SS)", minutes, seconds)
  end

  def edit_manifest
    manifest = YAML.load_file(@manifest_filename)
    yield manifest
    File.open(@manifest_filename,'w') do |h|
      h.write manifest.to_yaml
    end
  end
end
