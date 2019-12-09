plan install_puppet::provision_compiler(
  TargetSpec $master,
  TargetSpec $compiler,
  $ssldir = '/etc/puppetlabs/puppet/ssl',
  $gpg_url = 'http://apt.puppetlabs.com/pubkey.gpg',
  # The major puppet version to install.  An empty string defaults to 'puppet', which is latest
  $puppet_version = undef,
  # The puppet-agent package version to install, e.g. 6.11.0
  $puppet_agent_version = undef,
  # The puppetserver package version to install, e.g. 6.7.2
  $puppet_server_version = undef,
  # server and ca_server entries to use in puppet.conf.  Defaults to the master's fqdn
  $server = undef,
  $ca_server = undef,
) {
  $master.apply_prep
  $master_fqdn = run_task('facts', $master).first['networking']['fqdn']

  $server_conf = $server ? {
    undef => $master_fqdn,
    default => $server
  }
  $ca_server_conf = $ca_server ? {
    undef => $master_fqdn,
    default => $ca_server
  }

  # Get the facts from facts::bash that we need to build urls for installing repos and packages
  $compiler_facts = run_task('facts::bash', $compiler)
  $os_family = $compiler_facts.first.value['os']['family']
  $compiler_name = $compiler_facts.first.value['os']['name']
  $major_version = $compiler_facts.first.value['os']['release']['major']

  case $os_family {
    'debian': {
      $repo_url = "deb http://apt.puppetlabs.com $codename puppet${puppet_version}"
    }
    'redhat', 'sles', 'suse', 'fedora': {
      case $compiler_name {
        'fedora': {
          $repo_url = "http://yum.puppetlabs.com/puppet${puppet_version}-release-fedora-${major_version}.noarch.rpm"
        }
        'sles', 'suse': {
          $repo_url = "http://yum.puppetlabs.com/puppet${puppet_version}/sles/\$releasever_major/\$basearch/"
        }
        default: {
          $repo_url = "http://yum.puppetlabs.com/puppet${puppet_version}-release-el-${major_version}.noarch.rpm"
        }
      }
    }
    default: { warning("Unsupported platform ${os_family}") }
  }

  $gpg_result = run_task(
    'repo_tasks::install_gpg_key', $compiler, gpg_url => $gpg_url
  )

  $repo_result = run_task(
    'repo_tasks::install_repo', $compiler, $os_family, repo_url => $repo_url, name => 'puppet'
  )

  if $puppet_agent_version {
    run_task('package', $compiler, action => 'install', name => 'puppet-agent', version => $puppet_agent_version)
  }
  else {
    run_task('package', $compiler, action => 'install', name => 'puppet-agent')
  }
  if $puppet_server_version {
    run_task('package', $compiler, action => 'install', name => 'puppetserver', version => $puppet_server_version)
  }
  else {
    run_task('package', $compiler, action => 'install', name => 'puppetserver')
  }

  # Use apply_prep to get the id of the user and fqdn
  $compiler.apply_prep

  # fqdn may be different if we're running on the localhost transport
  $compiler_fqdn = run_task('facts', $compiler).first['networking']['fqdn']
  run_task(
    'puppet_conf', $compiler, action => set, section => main, setting => server, value => "$server_conf"
  )
  run_task(
    'puppet_conf', $compiler, action => set, section => main, setting => ca_server, value => "$server_conf"
  )
  run_task(
    'puppet_conf', $compiler, action => set, section => main, setting => cacrl, value => "$ssldir/crl.pem"
  )

  # Disable CA functions on the compiler
  apply($compiler) {
    file_line {'disable_ca_1':
      ensure => absent,
      path => '/etc/puppetlabs/puppetserver/services.d/ca.cfg',
      line => 'puppetlabs.services.ca.certificate-authority-service/certificate-authority-service',
    }
    file_line {'disable_ca_2':
      ensure => present,
      path => '/etc/puppetlabs/puppetserver/services.d/ca.cfg',
      line => 'puppetlabs.services.ca.certificate-authority-disabled-service/certificate-authority-disabled-service',
    }
  }

  run_task('run_agent::run_agent', $compiler, retries => 1, _catch_errors => true)
  run_task('sign_cert::sign_cert', $master, agent_certnames => $compiler_fqdn)
  run_task('run_agent::run_agent', $compiler, retries => 1)

  $services = ['puppetserver', 'puppet']
  $services.each |$s| {
    run_task('service::linux', $compiler, action => 'start', name => $s)
  }

  $service_out = $services.map |$s| {
    $out = run_task('service::linux', $compiler, action => 'status', name => $s).first
    $tmp = { $s => $out.value }
    $tmp
  }

  $package_out = ['puppetserver', 'puppet-agent'].map |$p| {
    $out = run_task('package', $compiler, action => 'status', name => $p).first
    $tmp = { $p => $out.value }
    $tmp
  }

  # Summarize the output of package and service tasks by combining the hashes
  return deep_merge( { 'packages' => $package_out }, { 'services' => $service_out } )
}
