plan install_puppet::provision_agent(
  TargetSpec $master,
  TargetSpec $targets,
  # Same key regardless of platform
  $gpg_url = 'http://apt.puppetlabs.com/pubkey.gpg',
  # The major puppet version to install.  An empty string defaults to 'puppet', which is latest
  $puppet_version = undef,
  # The package version to install, e.g. 6.11.0
  $puppet_agent_version = undef,
  # server and ca_server entries to use in puppet.conf.  Defaults to the master's fqdn
  $server = undef,
  $ca_server = undef,
) {
  # Get the fqdn of the master for use in puppet.conf on agents
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

  $gpg_out = run_task('repo_tasks::install_gpg_key', $targets, gpg_url => $gpg_url, _catch_errors => true)

  $urls = get_targets($gpg_out.ok_set.names).map |$n| {

    # Get the facts from facts::bash that we need to build urls for installing repos and packages
    $node_facts = run_task('facts::bash', $n)
    $os_family = $node_facts.first.value['os']['family']
    $node_name = $node_facts.first.value['os']['name']
    $major_version = $node_facts.first.value['os']['release']['major']
    $codename = $node_facts.first.value['os']['distro']['codename']

    case $os_family {
      'debian': {
        $repo_url = "deb http://apt.puppetlabs.com $codename puppet${puppet_version}"
      }
      'redhat', 'sles', 'suse', 'fedora': {
        case $node_name {
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
    # Creates hashes of { platform => repo url } pairs
    $tmp = { $os_family => { $n.name => $repo_url } }
    $tmp
  }

  # Unpack and recursively merge together the { platform => repo url } hashes
  # Because the values are hashes, they will be merged together to form hashes like:
  #    { RedHat =>
  #      { fqdn_1 => url_1,
  #        fqnd_2 => url_1
  #      }
  #    }
  $platforms = deep_merge(**$urls, {})

  # Then create a hash consisting of { fqnd => repo_url } pairs
  $vals = $platforms.values.reduce({}) |$memo, $value| { $memo + $value }

  # Iterate over each unique repo url, which is contained in the value of the $platforms hash
  # Create hashes consisting of identical repo_urls by comparing their values to the set of unique repo urls
  # This allows us to run the install_repo task concurrently on nodes that share the same url
  # "Bubble" the results up so we can get all of the task results in $repo_out
  $repo_out = $platforms.map |$k,$v| {
    $tmp_1 = values($v).unique.map |$val| {
      $target_group = $vals.filter |$k,$v| { $v == $val }
      $tmp_2 = run_task('repo_tasks::install_repo', $target_group.keys,
        $k, repo_url => $val, name => 'puppet', _catch_errors => true)
      $tmp_2
    }
    $tmp_1.reduce |$memo, $value| { $memo + $value }
  }.reduce |$memo, $value| { $memo + $value }

  if $puppet_agent_version {
    $package_out = run_task('package', $vals.keys, action => 'install', name => 'puppet-agent', version => $puppet_agent_version, _catch_errors => true)
  }
  else {
   $package_out = run_task('package', $vals.keys, action => 'install', name => 'puppet-agent')
  }

  run_task('puppet_conf', $package_out.ok_set.names, action => set, section => agent, setting => server, value => $server_conf, _catch_errors => true)
  run_task('puppet_conf', $package_out.ok_set.names, action => set, section => agent, setting => ca_server, value => $ca_server_conf, _catch_errors => true)

  # Get the fqdns of agent from their puppet.conf and turn it into a comma separated string
  $agent_conf = run_task('puppet_conf', $package_out.ok_set.names, action => get, section => agent, setting => certname)
  $agent_fqdns = $agent_conf.map |$a| { $a.value['status'] }.join(',')

  # The initial agent run that requests a cert will be expected to not have a 0 exit code
  run_task('run_agent::run_agent', $package_out.ok_set.names, retries => 1, _catch_errors => true)
  $cert_out = run_task('sign_cert::sign_cert', $master, agent_certnames => $agent_fqdns, _catch_errors => true)
  $agent_out = run_task('run_agent::run_agent', $package_out.ok_set.names, _catch_errors => true)

  # Merge together a hash of all possible failed steps
  # Include an empty hash if err_set is empty to avoid crunching the right side of the hash
  $failure = deep_merge(
    $gpg_out.error_set.names ? {
      [] => {},
      default => { 'failure' => $gpg_out.error_set.map |$result| {
        { $result.target.name => $result.value }
        }.reduce |$memo, $value| { $memo + $value }
      }
    },
    $repo_out.error_set.names ? {
      [] => {},
      default => { 'failure' => $repo_out.error_set.map |$result| {
        { $result.target.name => $result.value }
        }.reduce |$memo, $value| { $memo + $value }
      }
    },
    $package_out.error_set.names ? {
      [] => {},
      default => { 'failure' => $package_out.error_set.map |$result| {
        { $result.target.name => $result.value }
        }.reduce |$memo, $value| { $memo + $value }
      }
    },
    $cert_out.error_set.names ? {
      [] => {},
      default => { 'failure' => $cert_out.error_set.map |$result| {
        { $result.target.name => $result.value }
        }.reduce |$memo, $value| { $memo + $value }
      }
    },
    $agent_out.error_set.names ? {
      [] => {},
      default => { 'failure' => $agent_out.error_set.map |$result| {
        { $result.target.name => $result.value }
        }.reduce |$memo, $value| { $memo + $value }
      }
    }
  )

  return deep_merge($failure, { 'success' => $agent_out.ok_set.names })
}
