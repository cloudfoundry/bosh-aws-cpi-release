require 'spec_helper'
require 'json'
require 'yaml'

describe 'cpi.json.erb' do
  let(:cpi_specification_file) { File.absolute_path(File.join(jobs_root, 'aws_cpi/spec')) }
  let(:cpi_api_version) { 2 }

  subject(:parsed_json) do
    context_hash = YAML.load_file(cpi_specification_file)
    context = TemplateEvaluationContext.new(context_hash, manifest)
    renderer = ERBRenderer.new(context)
    parsed_json = JSON.parse(renderer.render(cpi_json_erb))
    parsed_json
  end

  let(:jobs_root) { File.join(File.dirname(__FILE__), '../../../../../../../../', 'jobs') }
  let(:cpi_json_erb) { File.read(File.absolute_path(File.join(jobs_root, 'aws_cpi/templates/cpi.json.erb'))) }
  let(:manifest) do
    {
      'properties' => {
        'aws' => {
          'default_key_name' => 'the_default_key_name',
          'default_security_groups' => ['security_group_1'],
          'region' => 'moon'
        },
        'registry' => {
          'host' => 'registry-host.example.com',
          'username' => 'admin',
          'password' => 'admin'
        },
        'blobstore' => {
          'address' => 'blobstore-address.example.com',
          'agent' => {
            'user' => 'agent',
            'password' => 'agent-password'
          }
        },
        'nats' => {
          'address' => 'nats-address.example.com',
          'password' => 'nats-password'
        }
      }
    }
  end

  it 'is able to render the erb given most basic manifest properties' do
    expect(subject).to eq(
      'cloud' => {
        'plugin'=>'aws',
        'properties' => {
          'aws' => {
            'credentials_source' => 'static',
            'access_key_id' => nil,
            'secret_access_key' => nil,
            'session_token' => nil,
            'default_iam_instance_profile' => nil,
            'default_key_name'=>'the_default_key_name',
            'default_security_groups'=>['security_group_1'],
            'region' => 'moon',
            'max_retries' => 8,
            'extend_ebs_volume_wait_time_factor' => 4,
            'encrypted' => false,
            'kms_key_arn' => nil
          },
          'registry' => {
            'endpoint' => 'http://admin:admin@registry-host.example.com:25777',
            'user' => 'admin',
            'password' => 'admin'
          },
          'agent' => {
            'ntp'=> %w(0.pool.ntp.org 1.pool.ntp.org),
            'blobstore' => {
              'provider' => 'dav',
              'options' => {
                'endpoint' => 'http://blobstore-address.example.com:25250',
                'user' => 'agent',
                'password' => 'agent-password'
              }
            },
            'mbus'=>'nats://nats:nats-password@nats-address.example.com:4222'
          },
          'debug'=> {
            'cpi'=> {
              'api_version'=> cpi_api_version
            },
          },
        }
      }
    )
  end

  context 'when api_version is provided in the manifest' do
    let(:cpi_api_version) { 42 }

    before do
      manifest['properties'].merge!({
        'debug'=> {
          'cpi'=> {
            'api_version'=> cpi_api_version
          },
        },
      })
    end

    it 'renders the api_version' do
      expect(subject['cloud']['properties']['debug']['cpi']['api_version']).to eq(42)
    end
  end

  context 'when api_version is NOT provided in the manifest' do
    it 'renders the DEFAULT api_version(2)' do
      expect(subject['cloud']['properties']['debug']['cpi']['api_version']).to eq(cpi_api_version)
    end
  end

  context 'when the registry password includes special characters' do
    special_chars_password = '=!@#$%^&*/-+?='
    before do
      manifest['properties']['registry']['password'] = special_chars_password
    end

    it 'encodes the password with special characters in the registry URL' do
      registry_uri = URI(subject['cloud']['properties']['registry']['endpoint'])
      expect(URI.decode_www_form_component(registry_uri.password)).to eq(special_chars_password)
    end
  end

  context 'when the encrypted property is provided' do
    before do
      manifest['properties']['aws']['encrypted'] = true
    end

    it 'propagates its value to cpi.json' do
      expect(subject['cloud']['properties']['aws']['encrypted']).to eq(true)
    end
  end

  context 'when the kms_key_arn property is provided' do
    let(:kms_key_arn) { 'arn:aws:kms:us-east-1:XXXXXX:key/e1c1f008-779b-4ebe-8116-0a34b77747dd' }
    before do
      manifest['properties']['aws']['kms_key_arn'] = kms_key_arn
    end

    it 'propagates its value to cpi.json' do
      expect(subject['cloud']['properties']['aws']['kms_key_arn']).to eq(kms_key_arn)
    end
  end

  context 'when credentials are provided in aws properties' do
    before do
      manifest['properties']['aws'].merge!({
        'access_key_id' => 'some key',
        'secret_access_key' => 'some secret'
      })
    end

    it 'is able to render the erb given access key id and secret access key' do
      expect(subject['cloud']['properties']['aws']['credentials_source']).to eq('static')
      expect(subject['cloud']['properties']['aws']['access_key_id']).to eq('some key')
      expect(subject['cloud']['properties']['aws']['secret_access_key']).to eq('some secret')
      expect(subject['cloud']['properties']['aws']['session_token']).to be_nil
    end

    context 'including a session_token' do
      before do
        manifest['properties']['aws'].merge!({
          'session_token' => 'some token'
        })
      end

      it 'is able to render the erb given access key id and secret access key' do
        expect(subject['cloud']['properties']['aws']['session_token']).to eq('some token')
      end
    end
  end

  context 'given an alternate credential source' do
    before do
      manifest['properties']['aws']['credentials_source'] = 'custom'
    end

    it 'overrides the default value' do
      expect(subject['cloud']['properties']['aws']['credentials_source']).to eq('custom')
    end
  end

  context 'given a default_iam_instance_profile' do
    it 'uses the value set' do
      manifest['properties']['aws']['default_iam_instance_profile'] = 'some_default_instance_profile'
      expect(subject['cloud']['properties']['aws']['default_iam_instance_profile']).to eq('some_default_instance_profile')
    end
  end

  context 'given a customized extend_ebs_volume_wait_time_factor' do
    before do
      manifest['properties']['aws']['extend_ebs_volume'] ||= {}
      manifest['properties']['aws']['extend_ebs_volume']['wait_time_factor'] = 77
    end

    it 'uses the value set' do
      expect(subject['cloud']['properties']['aws']['extend_ebs_volume_wait_time_factor']).to eq(77)
    end
  end

  context 'when using a dav blobstore' do
    let(:rendered_blobstore) { subject['cloud']['properties']['agent']['blobstore'] }

    it 'renders agent user/password for accessing blobstore' do
      expect(rendered_blobstore['options']['user']).to eq('agent')
      expect(rendered_blobstore['options']['password']).to eq('agent-password')
    end

    context 'when enabling signed URLs' do
      before do
        manifest['properties']['blobstore']['agent'].delete('user')
        manifest['properties']['blobstore']['agent'].delete('password')
      end

      it 'does not render agent user/password for accessing blobstore' do
        expect(rendered_blobstore['options']['user']).to be_nil
        expect(rendered_blobstore['options']['password']).to be_nil
      end
    end
  end

  context 'when using an s3 blobstore' do
    let(:rendered_blobstore) { subject['cloud']['properties']['agent']['blobstore'] }

    context 'when provided a minimal configuration' do
      before do
        manifest['properties']['blobstore'].merge!({
          'provider' => 's3',
          'bucket_name' => 'my_bucket',
          'access_key_id' => 'blobstore-access-key-id',
          'secret_access_key' => 'blobstore-secret-access-key',
        })
      end

      it 'renders the s3 provider section with the correct defaults' do
        expect(rendered_blobstore).to eq(
          {
            'provider' => 's3',
            'options' => {
              'bucket_name' => 'my_bucket',
              'credentials_source' => 'static',
              'access_key_id' => 'blobstore-access-key-id',
              'secret_access_key' => 'blobstore-secret-access-key',
              'session_token' => nil,
              'use_ssl' => true,
              'port' => 443,
            }
          }
        )
      end
    end

    context 'when provided a minimal configuration with env_or_profile credentials source' do
      before do
        manifest['properties']['blobstore'].merge!({
          'provider' => 's3',
          'bucket_name' => 'my_bucket',
          'credentials_source' => 'env_or_profile',
        })
      end

      it 'renders the s3 provider section with the correct defaults' do
        expect(rendered_blobstore).to eq(
          {
            'provider' => 's3',
            'options' => {
              'bucket_name' => 'my_bucket',
              'credentials_source' => 'env_or_profile',
              'access_key_id' => nil,
              'secret_access_key' => nil,
              'session_token' => nil,
              'use_ssl' => true,
              'port' => 443,
            }
          }
        )
      end
    end

    context 'when provided a maximal configuration' do
      before do
        manifest['properties']['blobstore'].merge!(
          'provider' => 's3',
          'bucket_name' => 'my_bucket',
          'credentials_source' => 'blobstore-credentials-source',
          'access_key_id' => 'blobstore-access-key-id',
          'secret_access_key' => 'blobstore-secret-access-key',
          'session_token' => 'blobstore-session-token',
          's3_region' => 'blobstore-region',
          'use_ssl' => false,
          's3_port' => 21,
          'host' => 'blobstore-host',
          'ssl_verify_peer' => true,
          's3_signature_version' => '11',
          'server_side_encryption' => 'AES256',
          'sse_kms_key_id' => 'kms-key'
        )
      end

      it 'renders the s3 provider section correctly' do
        expect(rendered_blobstore).to eq(
          {
            'provider' => 's3',
            'options' => {
              'bucket_name' => 'my_bucket',
              'credentials_source' => 'blobstore-credentials-source',
              'access_key_id' => 'blobstore-access-key-id',
              'secret_access_key' => 'blobstore-secret-access-key',
              'session_token' => nil,
              'region' => 'blobstore-region',
              'use_ssl' => false,
              'host' => 'blobstore-host',
              'port' => 21,
              'ssl_verify_peer' => true,
              'signature_version' => '11',
              'server_side_encryption' => 'AES256',
              'sse_kms_key_id' => 'kms-key'
            }
          }
        )
      end

      it 'prefers the agent properties when they are both included' do
        manifest['properties']['agent'] = {
          'blobstore' => {
            'credentials_source' => 'agent-credentials-source',
            'access_key_id' => 'agent_access_key_id',
            'secret_access_key' => 'agent_secret_access_key',
            'session_token' => 'agent_session_token',
            's3_region' => 'agent-region',
            'use_ssl' => true,
            's3_port' => 42,
            'host' => 'agent-host',
            'ssl_verify_peer' => true,
            's3_signature_version' => '99',
            'server_side_encryption' => 'from-agent',
            'sse_kms_key_id' => 'from-agent'
          }
        }

        manifest['properties']['blobstore'].merge!({
          'credentials_source' => 'blobstore-credentials-source',
          'access_key_id' => 'blobstore_access_key_id',
          'secret_access_key' => 'blobstore_secret_access_key',
          'session_token' => 'blobstore_session_token',
          's3_region' => 'blobstore-region',
          'use_ssl' => false,
          's3_port' => 21,
          'host' => 'blobstore-host',
          'ssl_verify_peer' => false,
          's3_signature_version' => '11',
          'server_side_encryption' => 'from-root',
          'sse_kms_key_id' => 'from-root'
        })

        expect(rendered_blobstore['options']['access_key_id']).to eq('agent_access_key_id')
        expect(rendered_blobstore['options']['secret_access_key']).to eq('agent_secret_access_key')
        expect(rendered_blobstore['options']['credentials_source']).to eq('agent-credentials-source')
        expect(rendered_blobstore['options']['region']).to eq('agent-region')
        expect(rendered_blobstore['options']['use_ssl']).to be true
        expect(rendered_blobstore['options']['port']).to eq(42)
        expect(rendered_blobstore['options']['host']).to eq('agent-host')
        expect(rendered_blobstore['options']['ssl_verify_peer']).to be true
        expect(rendered_blobstore['options']['signature_version']).to eq('99')
        expect(rendered_blobstore['options']['server_side_encryption']).to eq('from-agent')
        expect(rendered_blobstore['options']['sse_kms_key_id']).to eq('from-agent')
      end
    end

  end

  context 'when using a local blobstore' do
    let(:rendered_blobstore) { subject['cloud']['properties']['agent']['blobstore'] }

    context 'when provided a minimal configuration' do
      before do
        manifest['properties']['blobstore'].merge!({
          'provider' => 'local',
          'path' => '/fake/path',
        })
      end

      it 'renders the local provider section with the correct defaults' do
        expect(rendered_blobstore).to eq(
          {
            'provider' => 'local',
            'options' => {
              'blobstore_path' => '/fake/path',
            }
          }
        )
      end
    end
    context 'when provided an incomplete configuration' do
      before do
        manifest['properties']['blobstore'].merge!({
          'provider' => 'local',
        })
      end

      it 'raises an error' do
        expect { rendered_blobstore }.to raise_error(/Can't find property 'blobstore.path'/)
      end
    end
  end

  context 'when no blobstore is provided' do
    before do
      manifest['properties'].delete('blobstore')
    end

    it 'should NOT add any blobstore properties' do
      expect(subject['cloud']['properties']['blobstore']).to be_nil
    end
  end

  context 'when registry is NOT provided' do
    before do
      properties = manifest['properties']
      properties.delete('registry')
      manifest['properties'] = properties
    end

    it 'should NOT add registry in options' do
      expect(subject['cloud']['properties']['registry']).to eq(nil)
    end
  end

  context 'when partial registry is provided' do
    before do
      manifest['properties']['registry'].delete('username')
    end

    it 'raises template rendering error' do
      expect {
        subject
      }.to raise_error(/Can't find property 'registry.username'/)
    end
  end

  context 'when nats information is not provided' do
    before do
      manifest['properties'].delete('nats')
    end

    it 'should NOT add mbus properties' do
      expect(subject['cloud']['properties']['agent']['mbus']).to be_nil
    end
  end
end

class TemplateEvaluationContext
  attr_reader :name, :index
  attr_reader :properties, :raw_properties
  attr_reader :spec
  def initialize(spec, manifest)
    @name = spec['job']['name'] if spec['job'].is_a?(Hash)
    @index = spec['index']
    properties = {}
    spec['properties'].each do |name, x|
      default = x['default']
      copy_property(properties, manifest['properties'], name, default)
    end
    @properties = openstruct(properties)
    @raw_properties = properties
    @spec = openstruct(spec)
  end

  def recursive_merge(hash, other)
    hash.merge(other) do |_, old_value, new_value|
      if old_value.class == Hash && new_value.class == Hash
        recursive_merge(old_value, new_value)
      else
        new_value
      end
    end
  end

  def get_binding
    binding.taint
  end

  def p(*args)
    names = Array(args[0])
    names.each do |name|
      result = lookup_property(@raw_properties, name)
      return result unless result.nil?
    end
    return args[1] if args.length == 2
    raise UnknownProperty.new(names)
  end

  def if_p(*names)
    values = names.map do |name|
      value = lookup_property(@raw_properties, name)
      return ActiveElseBlock.new(self) if value.nil?
      value
    end
    yield *values
    InactiveElseBlock.new
  end

  private

  def copy_property(dst, src, name, default = nil)
    keys = name.split('.')
    src_ref = src
    dst_ref = dst
    keys.each do |key|
      src_ref = src_ref[key]
      break if src_ref.nil? # no property with this name is src
    end
    keys[0..-2].each do |key|
      dst_ref[key] ||= {}
      dst_ref = dst_ref[key]
    end
    dst_ref[keys[-1]] ||= {}
    dst_ref[keys[-1]] = src_ref.nil? ? default : src_ref
  end

  def openstruct(object)
    case object
      when Hash
        mapped = object.inject({}) { |h, (k,v)| h[k] = openstruct(v); h }
        OpenStruct.new(mapped)
      when Array
        object.map { |item| openstruct(item) }
      else
        object
    end
  end

  def lookup_property(collection, name)
    keys = name.split('.')
    ref = collection
    keys.each do |key|
      ref = ref[key]
      return nil if ref.nil?
    end
    ref
  end

  class UnknownProperty < StandardError
    def initialize(names)
      @names = names
      super("Can't find property '#{names.join("', or '")}'")
    end
  end

  class ActiveElseBlock
    def initialize(template)
      @context = template
    end
    def else
      yield
    end
    def else_if_p(*names, &block)
      @context.if_p(*names, &block)
    end
  end

  class InactiveElseBlock
    def else; end
    def else_if_p(*_)
      InactiveElseBlock.new
    end
  end
end

class ERBRenderer
  def initialize(context)
    @context = context
  end

  def render(erb_content)
    erb = ERB.new(erb_content)
    erb.result(@context.get_binding)
  end
end
