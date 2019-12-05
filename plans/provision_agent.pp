plan install_puppet::provision_agent(
  TargetSpec $master,
  TargetSpec $targets,
  # Same key regardless of platform
  $gpg_url = 'http://apt.puppetlabs.com/pubkey.gpg',
) {
  $master.apply_prep
  $master_fqdn = run_task('facts', $master).first['networking']['fqdn']
  # TODO: agent version, error checking, comments on how tf this works, result aggregation
  $gpg_out = run_task('repo_tasks::install_gpg_key', $targets, gpg_url => $gpg_url)

  $foo = get_targets($targets).map |$n| {

    # Get the facts from facts::bash that we need to build urls for installing repos and packages
    $node_facts = run_task('facts::bash', $n)
    $os_family = $node_facts.first.value['os']['family']
    $node_name = $node_facts.first.value['os']['name']
    $major_version = $node_facts.first.value['os']['release']['major']
    $codename = $node_facts.first.value['os']['distro']['codename']

    case $os_family {
      'debian': {
        $repo_url = "deb http://apt.puppetlabs.com $codename puppet"
      }
      'redhat', 'sles', 'suse', 'fedora': {
        case $node_name {
          'fedora': {
            $repo_url = "http://yum.puppetlabs.com/puppet-release-fedora-${major_version}.noarch.rpm"
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
      default: { warning("Unsupported platform ${os_family}") }
    }
    $tmp = { $os_family => { $n.name => $repo_url } }
    $tmp
  }

  $platforms = deep_merge(**$foo, {})
  $vals = $platforms.values.reduce({}) |$memo, $value| { $memo + $value }

  $platforms.each |$k,$v| {
    values($v).unique.each |$val| {
      $target_group = $vals.filter |$k,$v| { $v == $val }
      #TODO: check if repo exists
      run_task('repo_tasks::install_repo', $target_group.keys,
        $k, repo_url => $val, name => 'puppet', _catch_errors => true)
    }
  }
  run_task('package', $vals.keys, action => 'install', name => 'puppet-agent')

  run_task('puppet_conf', $vals.keys, action => set, section => agent, setting => server, value => $master_fqdn)
  $agent_conf = run_task('puppet_conf', $vals.keys, action => get, section => agent, setting => certname)
  $agent_fqdns = $agent_conf.map |$a| { $a.value['status'] }.join(',')

  run_task('run_agent::run_agent', $vals.keys, retries => 1, _catch_errors => true)
  run_task('sign_cert::sign_cert', $master, agent_certnames => $agent_fqdns, _catch_errors => true)
  run_task('run_agent::run_agent', $vals.keys)
}
