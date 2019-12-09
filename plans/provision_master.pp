plan install_puppet::provision_master(
  TargetSpec $master,
  Optional[Boolean] $install_puppetdb = true,
  # The major puppet version to install.  An empty string defaults to 'puppet', which is latest
  $puppet_version = undef,
  # The puppet-agent package version to install, e.g. 6.11.0
  $puppet_agent_version = undef,
  # The puppetserver package version to install, e.g. 6.7.2
  $puppet_server_version = undef,
  # server and ca_server entries to use in puppet.conf.  Defaults to the master's fqdn
) {
  #TODO: PuppetDB version
  $gpg_url = 'http://apt.puppetlabs.com/pubkey.gpg'

  # Get the facts from facts::bash that we need to build urls for installing repos and packages
  $master_facts = run_task('facts::bash', $master)
  $os_family = $master_facts.first.value['os']['family']
  $master_name = $master_facts.first.value['os']['name']
  $major_version = $master_facts.first.value['os']['release']['major']

  case $os_family {
    'debian': {
      $codename = $master_facts.first.value['os']['distro']['codename']
      $repo_url = "deb http://apt.puppetlabs.com $codename puppet"
    }
    'redhat', 'sles', 'suse', 'fedora': {
      case $master_name {
        'fedora': {
          #TODO
          $extra_args = '-f -g -n puppet'
          $repo_url = 'http://yum.puppetlabs.com/puppet/sles/$releasever_major/$basearch/'
          $install_name = 'fedora'
        }
        'sles', 'suse': {
          $repo_url = "http://yum.puppetlabs.com/puppet${puppet_version}/sles/\$releasever_major/\$basearch/"
          $install_name = 'sles'
        }
        default: {
          $install_name = 'el'
          $repo_url = "http://yum.puppetlabs.com/puppet/puppet-release-${install_name}-${major_version}.noarch.rpm"
        }
      }

    }
    default: { fail_plan("Unsupported platform ${os_family}") }
  }

  $gpg_result = run_task(
    'repo_tasks::install_gpg_key', $master, gpg_url => $gpg_url
  )

  $repo_result = run_task(
    'repo_tasks::install_repo', $master, $os_family, repo_url => $repo_url, name => 'puppet'
  )

  if $puppet_agent_version {
    run_task('package', $master, action => 'install', name => 'puppet-agent', version => $puppet_agent_version)
  }
  else {
    run_task('package', $master, action => 'install', name => 'puppet-agent')
  }
  if $puppet_server_version {
    run_task('package', $master, action => 'install', name => 'puppetserver', version => $puppet_server_version)
  }
  else {
    run_task('package', $master, action => 'install', name => 'puppetserver')
  }

  # Use apply_prep to get the id of the user and fqdn
  $master.apply_prep

  # fqdn may be different if we're running on the localhost transport
  $master_fqdn = run_task('facts', $master).first['networking']['fqdn']
  run_task(
    'puppet_conf', $master, action => set, section => agent, setting => server, value => "$master_fqdn"
  )

  if $install_puppetdb {
    $packages = ['puppetserver', 'puppetdb', 'puppet']
    $services = ['puppetserver', 'puppetdb', 'puppet']

    # We have to start puppetserver before applying puppetdb classes
    run_task('service::linux', $master, action => 'start', name => 'puppetserver')

    # Installing this module and applying these two classes gives us a monolithic PuppetDB
    run_command('/opt/puppetlabs/bin/puppet module install puppetlabs-puppetdb', $master, _run_as                    => 'root')

    run_command('/opt/puppetlabs/bin/puppet apply -e "class{ \'puppetdb\':}"', $master, _run_as                             => 'root')
    run_command('/opt/puppetlabs/bin/puppet apply -e "class{ \'puppetdb::master::config\':}"', $master, _run_as                             => 'root')

    # Configure the master to store reports in PuppetDB and to submit them in its own agent runs
    run_task('puppet_conf', $master, action => set, section => master, setting => reports, value => 'puppetdb')
    run_task('puppet_conf', $master, action => set, section => agent, setting => report, value => 'true')

    # Populate puppetdb.conf with the auth needed to use 'puppet query'
    apply($master) {
      $user = "${facts['id']}"
      case $user {
        'root': { $home = '/root' }
        default: { $home = "/home/$user" }
      }

      ["$home/.puppetlabs", "$home/.puppetlabs/client-tools"].each |$f| {
        file {"$f":
          ensure => directory,
        }
      }

      file {"$home/.puppetlabs/client-tools/puppetdb.conf":
        ensure  => present,
        content => epp('install_puppet/puppetdb.pp.epp', { 'hostname' => "${facts['fqdn']}" } ),
      }
    }

    run_command('/opt/puppetlabs/puppet/bin/gem install --bindir /opt/puppetlabs/bin puppetdb_cli', $master, _run_as => 'root')

  }
  else {
    $packages = ['puppetserver', 'puppet']
    $services = ['puppetserver', 'puppet']
  }

  $services.each |$s| {
    run_task('service::linux', $master, action => 'start', name => $s)
  }
  run_task('run_agent::run_agent', $master)

  $package_out = ['puppetserver', 'puppet-agent'].map |$p| {
    $out = run_task('package', $master, action => 'status', name => $p).first
    $tmp = { $p => $out.value }
    $tmp
  }

  $service_out = $services.map |$s| {
    $out = run_task('service::linux', $master, action => 'status', name => $s).first
    $tmp = { $s => $out.value }
    $tmp
  }

  # Summarize the output of package and service tasks by combining the hashes
  return deep_merge( { 'packages' => $package_out }, { 'services' => $service_out } )
}
