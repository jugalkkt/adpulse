# @summary Hardening for the AWS EC2 host (aws-prod).
#
# Applied by ansible/playbooks/aws_bootstrap.yml with `puppet apply`, after
# Docker is installed. Self-contained (no Forge modules).
#
# @param deploy_ssh_key
#   Public key line for the `adpulse` deploy user.
# @param allowed_tcp_ports
#   Ports ufw allows (added BEFORE ufw is enabled, so SSH is never cut off).
#   Note: ports published by Docker bypass ufw; the AWS security group is the
#   real boundary (docs/SECURITY.md).
# @param journald_max_use
#   journald disk cap.
class adpulse::host (
  String[1]            $deploy_ssh_key,
  Array[Integer[1]]    $allowed_tcp_ports = [22, 80],
  String[1]            $journald_max_use  = '200M',
) {
  # ---- deploy user (key only, no password)
  user { 'adpulse':
    ensure     => present,
    shell      => '/bin/bash',
    home       => '/home/adpulse',
    managehome => true,
    groups     => ['docker'],
    password   => '!',
  }

  file { ['/home/adpulse/.ssh']:
    ensure  => directory,
    owner   => 'adpulse',
    group   => 'adpulse',
    mode    => '0700',
    require => User['adpulse'],
  }

  file { '/home/adpulse/.ssh/authorized_keys':
    ensure  => file,
    owner   => 'adpulse',
    group   => 'adpulse',
    mode    => '0600',
    content => "${deploy_ssh_key}\n",
  }

  # ---- sshd: keys only, no root. Drop-in sorts first, so it wins over cloud-init's.
  file { '/etc/ssh/sshd_config.d/10-adpulse.conf':
    ensure       => file,
    owner        => 'root',
    group        => 'root',
    mode         => '0644',
    content      => @(SSHD),
      # Managed by Puppet (adpulse::host)
      PermitRootLogin no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PubkeyAuthentication yes
      X11Forwarding no
      MaxAuthTries 3
      LoginGraceTime 30
      | SSHD
    validate_cmd => '/usr/sbin/sshd -t -f /etc/ssh/sshd_config',
    notify       => Exec['reload sshd'],
  }

  exec { 'reload sshd':
    command     => '/usr/bin/systemctl reload ssh',
    refreshonly => true,
  }

  # ---- firewall: allow first, then enable
  package { 'ufw':
    ensure => installed,
  }

  $allowed_tcp_ports.each |Integer $port| {
    exec { "ufw allow ${port}/tcp":
      command => "/usr/sbin/ufw allow ${port}/tcp",
      unless  => "/usr/sbin/ufw show added | /usr/bin/grep -qx 'ufw allow ${port}/tcp'",
      require => Package['ufw'],
      before  => Exec['ufw enable'],
    }
  }

  exec { 'ufw default deny incoming':
    command => '/usr/sbin/ufw default deny incoming',
    unless  => "/usr/bin/grep -q '^DEFAULT_INPUT_POLICY=\"DROP\"' /etc/default/ufw",
    require => Package['ufw'],
    before  => Exec['ufw enable'],
  }

  exec { 'ufw enable':
    command => '/usr/sbin/ufw --force enable',
    unless  => "/usr/sbin/ufw status | /usr/bin/grep -q '^Status: active'",
  }

  # ---- automatic security updates
  package { 'unattended-upgrades':
    ensure => installed,
  }

  file { '/etc/apt/apt.conf.d/20auto-upgrades':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => "APT::Periodic::Update-Package-Lists \"1\";\nAPT::Periodic::Unattended-Upgrade \"1\";\n",
    require => Package['unattended-upgrades'],
  }

  # ---- kernel hardening (ip_forward stays on: Docker needs it)
  file { '/etc/sysctl.d/90-adpulse.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => @(SYSCTL),
      # Managed by Puppet (adpulse::host)
      net.ipv4.conf.all.accept_redirects = 0
      net.ipv4.conf.default.accept_redirects = 0
      net.ipv4.conf.all.send_redirects = 0
      net.ipv4.conf.all.accept_source_route = 0
      net.ipv4.icmp_echo_ignore_broadcasts = 1
      net.ipv4.tcp_syncookies = 1
      kernel.kptr_restrict = 2
      kernel.dmesg_restrict = 1
      fs.protected_hardlinks = 1
      fs.protected_symlinks = 1
      | SYSCTL
    notify  => Exec['apply sysctl'],
  }

  exec { 'apply sysctl':
    command     => '/usr/sbin/sysctl --system',
    refreshonly => true,
  }

  # ---- bounded logs
  file { '/etc/systemd/journald.conf.d':
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  file { '/etc/systemd/journald.conf.d/90-adpulse.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => "[Journal]\nSystemMaxUse=${journald_max_use}\nMaxRetentionSec=7day\n",
    notify  => Exec['restart journald'],
  }

  exec { 'restart journald':
    command     => '/usr/bin/systemctl restart systemd-journald',
    refreshonly => true,
  }

  # ---- report
  file { '/etc/adpulse':
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  file { '/etc/adpulse/hardening-report.txt':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('adpulse/host-report.txt.epp', {
      'ports'   => $allowed_tcp_ports,
      'journal' => $journald_max_use,
    }),
  }
}
