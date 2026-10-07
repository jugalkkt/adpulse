# PostgreSQL settings (rendered into /etc/adpulse-db/postgresql.conf)
default['adpulse_db']['shared_buffers'] = '128MB'
default['adpulse_db']['max_connections'] = 50
default['adpulse_db']['log_min_duration_statement'] = '200ms'
default['adpulse_db']['statement_timeout'] = '5s'
default['adpulse_db']['password_encryption'] = 'scram-sha-256'

# Client networks allowed in pg_hba.conf (scram-sha-256 only). One per
# environment's Docker network; see docs/DECISIONS.md D018.
default['adpulse_db']['allowed_cidrs'] = %w(172.28.10.0/24 172.28.20.0/24 172.28.30.0/24)

# Backups
default['adpulse_db']['backup_dir'] = '/backups'
default['adpulse_db']['textfile_dir'] = '/textfile'
default['adpulse_db']['backup_interval_seconds'] = 300
default['adpulse_db']['backup_retention_count'] = 6
default['adpulse_db']['backup_quota_bytes'] = 200 * 1024 * 1024
default['adpulse_db']['metrics_refresh_seconds'] = 15

# Host-side settings for the AWS VM (recipe adpulse_db::host, Phase 12)
default['adpulse_db']['host']['backup_dir'] = '/srv/adpulse/backups'
