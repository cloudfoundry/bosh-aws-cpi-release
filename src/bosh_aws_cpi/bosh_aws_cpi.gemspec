# coding: utf-8
Gem::Specification.new do |s|
  s.name         = 'bosh_aws_cpi'
  s.version      = '2.1.0'
  s.platform     = Gem::Platform::RUBY
  s.summary      = 'BOSH AWS CPI'
  s.description  = 'BOSH AWS CPI'
  s.author       = 'VMware'
  s.homepage     = 'https://github.com/cloudfoundry/bosh'
  s.license      = 'Apache 2.0'
  s.email        = 'support@cloudfoundry.com'
  s.required_ruby_version = Gem::Requirement.new('>= 1.9.3')

  s.files        = Dir['README.md', 'lib/**/*', 'scripts/**/*'].select{ |f| File.file? f }
  s.require_path = 'lib'
  s.bindir       = 'bin'
  s.executables  = %w(aws_cpi bosh_aws_console)

  s.add_dependency 'aws-sdk',       '1.60.2'
  s.add_dependency 'bosh_common'
  s.add_dependency 'bosh_cpi'
  s.add_dependency 'bosh-registry'
  s.add_dependency 'httpclient',    '=2.4.0'
  s.add_dependency 'yajl-ruby',     '>=0.8.2'
end
