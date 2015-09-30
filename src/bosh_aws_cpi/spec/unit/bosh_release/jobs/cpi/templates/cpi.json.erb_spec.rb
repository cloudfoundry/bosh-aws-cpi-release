require 'spec_helper'
require 'json'

describe 'cpi.json.erb' do
  let(:cpi_specification_file) { File.absolute_path(File.join(jobs_root, 'cpi/spec')) }

  subject(:parsed_json) do
    context_hash = YAML.load_file(cpi_specification_file)
    context = TemplateEvaluationContext.new(context_hash, manifest)
    renderer = ERBRenderer.new(context)
    parsed_json = JSON.parse(renderer.render(cpi_json_erb))
    parsed_json
  end

  let(:jobs_root) { File.join(File.dirname(__FILE__), '../../../../../../../../', 'jobs') }
  let(:cpi_json_erb) { File.read(File.absolute_path(File.join(jobs_root, 'cpi/templates/cpi.json.erb'))) }
  let(:manifest) do
    {
      'properties' => {
        'aws' => {
          'default_key_name' => 'the_default_key_name',
          'default_security_groups' => ['security_group_1'],
          'region' => 'moon'
        },
        'registry' => {
          'host' => 'registry_host.example.com',
          'username' => 'admin',
          'password' => 'admin',
        },
        'blobstore' => {
          'address' => 'blobstore_address.example.com',
          'agent' => {
            'user' => 'agent',
            'password' => 'agent-password'
          }
        },
        'nats' => {
          'address' => 'nats_address.example.com',
          'password' => 'nats-password'
        }
      }
    }
  end

  it 'is able to render the erb given most basic manifest properties' do
    expect(subject).to eq({
      'cloud'=>{
        'plugin'=>'aws',
        'properties'=> {
          'aws'=>{
            'credentials_source' => 'static',
            'access_key_id' => nil,
            'secret_access_key' => nil,
            'default_iam_instance_profile' => nil,
            'default_key_name'=>'the_default_key_name',
            'default_security_groups'=>['security_group_1'],
            'region'=>'moon'
          },
          'registry'=>{
            'endpoint'=>'http://admin:admin@registry_host.example.com:25777',
            'user'=>'admin',
            'password'=>'admin'
          },
          'agent'=>{
            'ntp'=>[
              '0.pool.ntp.org',
              '1.pool.ntp.org'
            ],
            'blobstore'=>{
              'provider'=>'dav',
              'options'=>{
                'endpoint'=>'http://blobstore_address.example.com:25250',
                'user'=>'agent',
                'password'=>'agent-password'
              }
            },
            'mbus'=>'nats://nats:nats-password@nats_address.example.com:4222'
          }
        }
      }
    })
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

  context 'when using an s3 blobstore' do
    let(:rendered_blobstore) { subject['cloud']['properties']['agent']['blobstore'] }
    before do
      manifest['properties']['blobstore']['provider'] = 's3'
      manifest['properties']['blobstore']['bucket_name'] = 'my_bucket'
      manifest['properties']['blobstore']['access_key_id'] = 'blobstore-access-key-id'
      manifest['properties']['blobstore']['secret_access_key'] = 'blobstore-secret-access-key'
      manifest['properties']['blobstore']['use_ssl'] = false
      manifest['properties']['blobstore']['s3_port'] = 21
      manifest['properties']['blobstore']['host'] = 'blobstore-host'
      manifest['properties']['blobstore']['s3_force_path_style'] = true
      manifest['properties']['blobstore']['ssl_verify_peer'] = true
      manifest['properties']['blobstore']['s3_multipart_threshold'] = 123
    end

    it 'renders the s3 provider section correctly' do
      expect(rendered_blobstore).to eq(
        {
          'provider' => 's3',
          'options' => {
            'bucket_name' => 'my_bucket',
            'credentials_source' => 'static',
            'access_key_id' => 'blobstore-access-key-id',
            'secret_access_key' => 'blobstore-secret-access-key',
            'use_ssl' => false,
            'host' => 'blobstore-host',
            'port' => 21,
            's3_force_path_style' => true,
            'ssl_verify_peer' => true,
            's3_multipart_threshold' => 123
          }
        }
      )
    end

    context 'and an alternate credentials source is provided in the blobstore properties' do
      it 'uses the overridden property' do
        manifest['properties']['blobstore']['credentials_source'] = 'blobstore_overridden'
        expect(rendered_blobstore['options']['credentials_source']).to eq('blobstore_overridden')
      end
    end

    context 'and an alternate credentials source is provided in the agent blobstore properties' do
      it 'uses the overridden property' do
        manifest['properties']['agent'] = {'blobstore' => {'credentials_source' => 'agent_overridden'}}
        expect(rendered_blobstore['options']['credentials_source']).to eq('agent_overridden')
      end
    end

    context 'and an alternate credentials source is provided in both the blobstore and agent blobstore properties' do
      it 'uses the overridden property' do
        manifest['properties']['blobstore']['credentials_source'] = 'blobstore_overridden'
        manifest['properties']['agent'] = {'blobstore' => {'credentials_source' => 'agent_overridden'}}
        expect(rendered_blobstore['options']['credentials_source']).to eq('agent_overridden')
      end
    end

    context 'when aws credentials are provided' do
      it 'includes them from the blobstore properties' do
        manifest['properties']['blobstore']['access_key_id'] = 'blobstore_access_key_id'
        manifest['properties']['blobstore']['secret_access_key'] = 'blobstore_secret_access_key'

        expect(rendered_blobstore['options']['access_key_id']).to eq('blobstore_access_key_id')
        expect(rendered_blobstore['options']['secret_access_key']).to eq('blobstore_secret_access_key')
      end

      it 'includes them from the agent blobstore properties' do
        manifest['properties']['agent'] = {
          'blobstore' => {
            'access_key_id' => 'agent_access_key_id',
            'secret_access_key' => 'agent_secret_access_key'
          }
        }

        expect(rendered_blobstore['options']['access_key_id']).to eq('agent_access_key_id')
        expect(rendered_blobstore['options']['secret_access_key']).to eq('agent_secret_access_key')
      end

      it 'prefers the agent properties when they are both included' do
        manifest['properties']['agent'] = {
          'blobstore' => {
            'access_key_id' => 'agent_access_key_id',
            'secret_access_key' => 'agent_secret_access_key',
            'use_ssl' => true,
            's3_port' => 42,
            'host' => 'agent-host',
            's3_force_path_style' => true,
            'ssl_verify_peer' => true,
            's3_multipart_threshold' => 33
          }
        }

        manifest['properties']['blobstore']['access_key_id'] = 'blobstore_access_key_id'
        manifest['properties']['blobstore']['secret_access_key'] = 'blobstore_secret_access_key'
        manifest['properties']['blobstore']['use_ssl'] = false
        manifest['properties']['blobstore']['s3_port'] = 21
        manifest['properties']['blobstore']['host'] = 'blobstore-host'
        manifest['properties']['blobstore']['s3_force_path_style'] = false
        manifest['properties']['blobstore']['ssl_verify_peer'] = false
        manifest['properties']['blobstore']['s3_multipart_threshold'] = 22

        expect(rendered_blobstore['options']['access_key_id']).to eq('agent_access_key_id')
        expect(rendered_blobstore['options']['secret_access_key']).to eq('agent_secret_access_key')
        expect(rendered_blobstore['options']['use_ssl']).to be true
        expect(rendered_blobstore['options']['port']).to eq(42)
        expect(rendered_blobstore['options']['host']).to eq('agent-host')
        expect(rendered_blobstore['options']['s3_force_path_style']).to be true
        expect(rendered_blobstore['options']['ssl_verify_peer']).to be true
        expect(rendered_blobstore['options']['s3_multipart_threshold']).to eq(33)
      end
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
