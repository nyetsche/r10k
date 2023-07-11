require 'git_utils'
require 'r10k_utils'
require 'master_manipulator'
test_name 'RK-242 '#'- C87652 - Specify the proxy in the r10k.yaml'

confine(:to, :platform => ['el', 'sles'])

#Init
master_platform = fact_on(master, 'osfamily')
master_certname = on(master, puppet('config', 'print', 'certname')).stdout.rstrip
env_path = on(master, puppet('config print environmentpath')).stdout.rstrip
r10k_fqp = get_r10k_fqp(master)

git_repo_path = '/git_repos'
git_repo_name = 'environments'
git_control_remote = File.join(git_repo_path, "#{git_repo_name}.git")
git_environments_path = '/root/environments'
last_commit = git_last_commit(master, git_environments_path)
git_provider = ENV['GIT_PROVIDER']

local_files_root_path = ENV['FILES'] || 'files'

git_manifest_template_path = File.join(local_files_root_path, 'pre-suite', 'git_config.pp.erb')
git_manifest = ERB.new(File.read(git_manifest_template_path)).result(binding)

r10k_config_path = get_r10k_config_file_path(master)
r10k_config_bak_path = "#{r10k_config_path}.bak"

case master_platform
  when 'RedHat'
    pkg_manager = 'yum'
  when 'Suse'
    pkg_manager = 'zypper'
end

install_squid = "#{pkg_manager} install -y squid"
remove_squid = "#{pkg_manager} remove -y squid"
squid_log = "/var/log/squid/access.log"

#In-line files
r10k_conf = <<-CONF
cachedir: '/var/cache/r10k'
git:
  provider: '#{git_provider}'
sources:
  control:
    basedir: "#{env_path}"
    remote: "#{git_control_remote}"
forge:
  proxy: "http://#{master.hostname}:3128"
CONF

#Manifest
site_pp_path = File.join(git_environments_path, 'manifests', 'site.pp')
site_pp = create_site_pp(master_certname, '  include peonly')

#Verification
squid_log_regex = /CONNECT forgeapi.puppet.com:443/
notify_message_regex = /I am in the production environment, this is a PE only module/

#Teardown
teardown do
  step 'remove license file'
  on(master, 'rm -f /etc/puppetlabs/license.key')

  step 'Restore "git" Package'
  on(master, puppet('apply'), :stdin => git_manifest, :acceptable_exit_codes => [0,2])

  step 'Restore Original "r10k" Config'
  on(master, "mv #{r10k_config_bak_path} #{r10k_config_path}")

  clean_up_r10k(master, last_commit, git_environments_path)

  step 'Remove Squid'
  on(master, puppet("apply -e 'service {'squid' : ensure => stopped}'"))
  on(master, remove_squid)
end

#Setup
step 'Stub the forge'
stub_forge_on(master)

step 'Backup Current "r10k" Config'
on(master, "mv #{r10k_config_path} #{r10k_config_bak_path}")

step 'Update the "r10k" Config'
create_remote_file(master, r10k_config_path, r10k_conf)

step 'Download license file from artifactory'
curl_on(master, 'https://artifactory.delivery.puppetlabs.net/artifactory/generic/r10k_test_license.key -o /etc/puppetlabs/license.key')

step 'Checkout "production" Branch'
git_on(master, 'checkout production', git_environments_path)

step 'Inject New "site.pp" to the "production" Environment'
inject_site_pp(master, site_pp_path, site_pp)

step 'Copy Puppetfile to "production" Environment with PE only module'
create_remote_file(master, "#{git_environments_path}/Puppetfile", 'mod "ztr-peonly"')

step 'Push Changes'
git_add_commit_push(master, 'production', 'add Puppetfile', git_environments_path)

step 'Install and configure squid proxy'
on(master, install_squid)

step 'turn off the firewall'
on(master, puppet("apply -e 'service {'iptables' : ensure => stopped}'"))

step 'start squid proxy'
on(master, puppet("apply -e 'service {'squid' : ensure => running}'"))

#Tests
step 'Deploy "production" Environment via r10k'
on(master, "#{r10k_fqp} deploy environment -p")

step 'Read the squid logs'
on(master, "cat #{squid_log}") do |result|
  assert_match(squid_log_regex, result.stdout, 'Proxy logs did not indicate use of the proxy.')
end

agents.each do |agent|
  step "Run Puppet Agent"
  on(agent, puppet('agent', '--test', '--environment production'), :acceptable_exit_codes => [0,2]) do |result|
    assert_no_match(/Error:/, result.stderr, 'Unexpected error was detected!')
    assert_match(notify_message_regex, result.stdout, 'Expected message not found!')
  end
end
