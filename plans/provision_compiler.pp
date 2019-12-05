plan install_puppet::provision_compiler(
  TargetSpec $master,
  TargetSpec $compiler,
  $ssldir = '/etc/puppetlabs/puppet/ssl',
) {
  $master.apply_prep
  $master_fqdn = run_task('facts', $master).first['networking']['fqdn']

  $gpg_url = 'http://apt.puppetlabs.com/pubkey.gpg'

  # Get the facts from facts::bash that we need to build urls for installing repos and packages
  $compiler_facts = run_task('facts::bash', $compiler)
  $os_family = $compiler_facts.first.value['os']['family']
  $compiler_name = $compiler_facts.first.value['os']['name']
  $major_version = $compiler_facts.first.value['os']['release']['major']

  case $os_family {
    'debian': {
      $codename = $compiler_facts.first.value['os']['distro']['codename']
      $repo_url = "deb http://apt.puppetlabs.com $codename puppet"
    }
    'redhat', 'sles', 'suse', 'fedora': {
      case $compiler_name {
        'fedora': {
          $repo_url = "http://yum.puppetlabs.com/puppet/puppet-release-fedora-${major_version}.noarch.rpm"
          $repo_url = 'http://yum.puppetlabs.com/puppet/sles/$releasever_major/$basearch/'
        }
        'sles', 'suse': {
          $extra_args = '-f -g -n puppet'
          $repo_url = 'http://yum.puppetlabs.com/puppet/sles/$releasever_major/$basearch/'
        }
        default: {
          $repo_url = "http://yum.puppetlabs.com/puppet/puppet-release-el-${major_version}.noarch.rpm"
        }
      }
    }
    default: { fail_plan("Unsupported platform ${os_family}") }
  }

  $gpg_result = run_task(
    'repo_tasks::install_gpg_key', $compiler, gpg_url => $gpg_url
  )

  # TODO: check here in the plan or in the install task?
  # probably the task
  #$repo_check = run_task('repo_tasks::query_repo', $master, name => 'puppet').first
  #if empty($repo_check['repos']) {
    $repo_result = run_task(
      'repo_tasks::install_repo', $compiler, $os_family, repo_url => $repo_url, name => 'puppet'
    )
  #}

  # puppetserver and puppet-agent need to be installed in any scenario
  $package_out = ['puppetserver', 'puppet-agent'].map |$p| {
    $out = run_task('package', $compiler, action => 'install', name => $p).first
    $tmp = { $p => $out.value }
    $tmp
  }

  # Use apply_prep to get the id of the user and fqdn
  $compiler.apply_prep

  # fqdn may be different if we're running on the localhost transport
  $compiler_fqdn = run_task('facts', $compiler).first['networking']['fqdn']
  run_task(
    'puppet_conf', $compiler, action => set, section => main, setting => server, value => "$master_fqdn"
  )
  run_task(
    'puppet_conf', $compiler, action => set, section => main, setting => ca_server, value => "$master_fqdn"
  )
  run_task(
    'puppet_conf', $compiler, action => set, section => main, setting => cacrl, value => "$ssldir/crl.pem"
  )

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

  # Summarize the output of package and service tasks by combining the hashes
  return deep_merge( { 'packages' => $package_out }, { 'services' => $service_out } )
}
