# install_puppet

Super WIP set of Bolt tasks and plans to set up a FOSS Puppet master and agents

## Setup

Example commands to install Bolt and get started using the Plans:

```
mkdir Boltdir
cd !$
```

```
cat <<EOF >Puppetfile
mod 'm0dular-run_agent', '0.1.2'
mod 'puppetlabs-stdlib'
mod 'repo_tasks',
  :git => 'https://github.com/m0dular/repo_tasks.git'
mod 'install_puppet',
  :git => 'https://github.com/m0dular/install_puppet.git'
EOF
```

```
bolt puppetfile install
```

## Usage

```
bolt plan run install_puppet::provision_master master=<value> [install_puppetdb=<value>]

PARAMETERS:
- master: TargetSpec
- install_puppetdb: Optional[String]
```

```
bolt plan run install_puppet::provision_agent master=<value> targets=<value> [gpg_url=<value>]

PARAMETERS:
- master: TargetSpec
- targets: TargetSpec
- gpg_url: Any
```
