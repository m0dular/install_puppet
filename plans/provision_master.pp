plan install_puppet::provision_master(
  TargetSpec $master,
  Optional[String] $install_puppetdb = undef,
) {
  $gpg_url = 'http://apt.puppetlabs.com/pubkey.gpg'

  $master_facts = run_task('facts', $master)
  $os_family = $master_facts.first.value['os']['family']
  $name = $master_facts.first.value['os']['name']

  case $os_family {
    'debian': {
      $gpg_result = run_task(
        'install_puppet::install_gpg_key', $master, name => $os_family, gpg_url => $gpg_url
      )

      $codename = $master_facts.first.value['os']['codename']
      $repo_url = "deb http://apt.puppetlabs.com $codename puppet"
    }
    'redhat', 'sles', 'suse', 'fedora': {
      case $name {
        'fedora': {
          #TODO
          $extra_args = '-f -g -n puppet'
          $repo_url = 'http://yum.puppetlabs.com/puppet/sles/$releasever_major/$basearch/'
          $install_name = 'fedora'
        }
        'sles', 'suse': {
          $extra_args = '-f -g -n puppet'
          $repo_url = 'http://yum.puppetlabs.com/puppet/sles/$releasever_major/$basearch/'
          $install_name = 'sles'
        }
        default: {
          $install_name = 'el'
          $repo_url = "http://yum.puppetlabs.com/puppet/puppet-release-${install_name}-${major_version}.noarch.rpm"
        }
      }
      $gpg_result = run_task(
        'install_puppet::install_gpg_key', $master, name => $os_family, gpg_url => $gpg_url
      )

      $major_version = $master_facts.first.value['os']['release']['major']
    }
    default: { fail_plan("Unsupported platform ${os_family}") }
  }

  $repo_result = run_task(
    'install_puppet::install_repo', $master, platform => $os_family, repo_url => $repo_url, name => 'puppet', extra_args => $extra_args
  )

  $package_out = ['puppetserver', 'puppet-agent'].map |$p| {
    $out = run_task('package', $master, action => 'install', name => $p).first
    $tmp = { $p => $out.value }
    $tmp
  }

  run_task('puppet_conf', $master, action => set, section => agent, setting => server, value => $master)
  run_task('service', $master, action => 'start', name => 'puppetserver').first

  if $install_puppetdb {
    $services = ['puppetserver', 'puppetdb', 'puppet']

    run_command('/opt/puppetlabs/bin/puppet module install puppetlabs-puppetdb', $master, _run_as => 'root')

    apply($master) {
      file {'/etc/puppetlabs/code/environments/production/manifests/site.pp':
        ensure  => present,
        content => epp('install_puppet/site.pp.epp', { 'hostname' => $master } )
      }
    }

    run_task('install_puppet::run_agent', $master)
  }
  else {
    $services = ['puppetserver', 'puppet']
  }

  $service_out = $services.map |$s| {
    $out = run_task('service', $master, action => 'status', name => $s).first
    $tmp = { $s => $out.value }
    $tmp
  }

  return deep_merge( { 'packages' => $package_out }, { 'services' => $service_out } )
}
