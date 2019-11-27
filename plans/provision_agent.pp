plan install_puppet::provision_agent(
  TargetSpec $master,
  TargetSpec $targets,
  $gpg_url = 'http://apt.puppetlabs.com/pubkey.gpg',
) {
  # TODO: agent version, error checking, comments on how tf this works
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
      run_task('repo_tasks::install_repo', $target_group.keys,
        $k, repo_url => $val, name => 'puppet', _catch_errors => true)
    }
  }
  run_task('package', $vals.keys, action => 'install', name => 'puppet-agent')

  run_task('puppet_conf', $vals.keys, action => set, section => agent, setting => server, value => $master)
  run_task('run_agent::run_agent', $vals.keys, retries => 1, _catch_errors => true)
  run_task('sign_cert::sign_cert', $master, agent_certnames => $targets, _catch_errors => true)
  run_task('run_agent::run_agent', $vals.keys)
}
