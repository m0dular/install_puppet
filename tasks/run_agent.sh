#!/bin/bash
# shellcheck disable=SC2154,SC2034,SC1090

declare PT__installdir
source "$PT__installdir/deploy_pe/files/common.sh"
PUPPET_BIN=/opt/puppetlabs/bin

(( EUID == 0 )) || fail "This utility must be run as root"

lockfile="$("${PUPPET_BIN}/puppet" config print agent_catalog_run_lockfile)"
retries=5
wait_time=300

# Sleep in increments of 1 until either the lockfile is gone or we reach $wait_time
while [[ -e $lockfile ]] && (( wait_time > 0 )); do
  (( wait_time-- ))
  sleep 1
done

# Fail if the lock still exists
[[ -e $lockfile ]] && fail "Agent lockfile $lockfile still exists after waiting $wait_time seconds"

# Run Puppet until there are no changes, otherwise fail
for ((i = 0; i < retries; i++)); do
  "${PUPPET_BIN}/puppet" agent -t >/dev/null && {
    success '{ "status": "Successfully installed" }'
  }
done

fail "Failed to run Puppet in $retries attempts"
