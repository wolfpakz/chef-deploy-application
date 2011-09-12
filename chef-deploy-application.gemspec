# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "chef-deploy-application"

Gem::Specification.new do |s|
  s.name        = "chef-deploy-application"
  s.version     = Chef::Application::DeployApplication::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Daniel Porter"]
  s.email       = ["wolfpakz@gmail.com"]
  s.homepage    = ""
  s.summary     = %q{Deploy a single application using the application community cookbook.}
  s.description = %q{Executes a chef-client run with only the application's role and the application cookbook in the run list.  For example, for the application "foo" the run list would be: role:foo application}

  s.rubyforge_project = "chef-deploy-application"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  s.add_dependency('chef', '~> 0.10.4')
end
