# @summary OS baseline baked into the adpulse-base container image.
#
# Creates the unprivileged adpulse user and its directories, installs the
# runtime packages, and applies hardening that is safe inside a container:
# login.defs umask, setuid/setgid removal (allow-list) and no world-writable
# files outside /tmp. Writes /etc/adpulse/hardening-report.txt.
#
# @param uid
#   uid and gid of the adpulse user and group.
# @param packages
#   Packages that must be present.
# @param umask
#   UMASK value enforced in /etc/login.defs.
# @param suid_allowlist
#   Absolute paths allowed to keep setuid/setgid bits. Empty by default:
#   nothing in the image needs privilege escalation.
class adpulse::base (
  Integer[1000]        $uid            = 10001,
  Array[String[1]]     $packages       = ['ca-certificates', 'tzdata', 'python3', 'python3-venv', 'curl'],
  Pattern[/\A0[0-7]{2}\z/] $umask      = '027',
  Array[Pattern[/\A\//]] $suid_allowlist = [],
) {
  group { 'adpulse':
    ensure => present,
    gid    => $uid,
  }

  user { 'adpulse':
    ensure     => present,
    uid        => $uid,
    gid        => $uid,
    home       => '/opt/adpulse',
    shell      => '/usr/sbin/nologin',
    managehome => false,
    require    => Group['adpulse'],
  }

  file { '/opt/adpulse':
    ensure  => directory,
    owner   => 'adpulse',
    group   => 'adpulse',
    mode    => '0750',
    require => User['adpulse'],
  }

  file { '/etc/adpulse':
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  file { '/var/log/adpulse':
    ensure  => directory,
    owner   => 'adpulse',
    group   => 'adpulse',
    mode    => '0750',
    require => User['adpulse'],
  }

  package { $packages:
    ensure => installed,
  }

  exec { 'login.defs umask':
    command => "/usr/bin/sed -ri 's/^UMASK[[:space:]]+.*/UMASK\\t\\t${umask}/' /etc/login.defs",
    unless  => "/usr/bin/grep -Eq '^UMASK[[:space:]]+${umask}\$' /etc/login.defs",
  }

  file { '/usr/local/sbin/adpulse-fs-hardening':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0750',
    content => epp('adpulse/fs-hardening.sh.epp', { 'suid_allowlist' => $suid_allowlist }),
  }

  # Runs after packages so newly installed binaries are covered too.
  exec { 'filesystem hardening':
    command   => '/usr/local/sbin/adpulse-fs-hardening fix',
    unless    => '/usr/local/sbin/adpulse-fs-hardening check',
    logoutput => true,
    require   => [File['/usr/local/sbin/adpulse-fs-hardening'], Package[$packages]],
  }

  file { '/etc/adpulse/hardening-report.txt':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('adpulse/hardening-report.txt.epp', {
      'uid'            => $uid,
      'packages'       => $packages,
      'umask'          => $umask,
      'suid_allowlist' => $suid_allowlist,
    }),
    require => [Exec['login.defs umask'], Exec['filesystem hardening']],
  }
}
