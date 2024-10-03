require 'spec_helper'
require 'json'
require 'yaml'
require 'ostruct'

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
          'default_security_groups' => ['security_group_1'],
          'region' => 'moon'
        },
        'registry' => {
          'host' => 'registry-host.example.com',
          'username' => 'admin',
          'password' => 'admin'
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
            'default_key_name'=>nil,
            'default_security_groups'=>['security_group_1'],
            'region' => 'moon',
            'role_arn' => nil,
            'max_retries' => 8,
            'encrypted' => false,
            'kms_key_arn' => nil,
            'metadata_options' => nil,
            'dualstack' => false
          },
          'registry' => {
            'endpoint' => 'http://admin:admin@registry-host.example.com:25777',
            'user' => 'admin',
            'password' => 'admin'
          },
          'agent' => {
            'ntp'=> %w(0.pool.ntp.org 1.pool.ntp.org),
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

  context 'enable dualstack to use different api endpoints' do
    before do
      manifest['properties']['aws']['dualstack'] = true
    end

    it 'overrides the default value' do
      expect(subject['cloud']['properties']['aws']['dualstack']).to eq(true)
    end
  end

  context 'given a default_iam_instance_profile' do
    it 'uses the value set' do
      manifest['properties']['aws']['default_iam_instance_profile'] = 'some_default_instance_profile'
      expect(subject['cloud']['properties']['aws']['default_iam_instance_profile']).to eq('some_default_instance_profile')
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
    binding
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
