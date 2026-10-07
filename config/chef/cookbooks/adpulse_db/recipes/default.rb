#
# Cookbook:: adpulse_db
# Recipe:: default
#
# Configures the PostgreSQL node baked into the adpulse-postgres image.
# Runs at image build time (cinc-client --local-mode); Cinc is removed afterwards.

attrs = node['adpulse_db']

directory '/etc/adpulse-db' do
  owner 'root'
  group 'postgres'
  mode '0750'
end

template '/etc/adpulse-db/postgresql.conf' do
  source 'postgresql.conf.erb'
  owner 'root'
  group 'postgres'
  mode '0640'
  variables(attrs: attrs)
end

template '/etc/adpulse-db/pg_hba.conf' do
  source 'pg_hba.conf.erb'
  owner 'root'
  group 'postgres'
  mode '0640'
  variables(cidrs: attrs['allowed_cidrs'])
end

# Runs once, on first start with an empty data directory (docker-entrypoint).
template '/docker-entrypoint-initdb.d/10-adpulse-roles.sh' do
  source 'init-roles.sh.erb'
  owner 'root'
  group 'root'
  mode '0755'
end

[attrs['backup_dir'], attrs['textfile_dir']].each do |dir|
  directory dir do
    owner 'postgres'
    group 'postgres'
    mode '0755'
  end
end

%w(adpulse-backup.sh adpulse-backup-metrics.sh adpulse-backup-loop.sh).each do |script|
  template "/usr/local/bin/#{script}" do
    source "#{script}.erb"
    owner 'root'
    group 'root'
    mode '0755'
    variables(attrs: attrs)
  end
end

file '/etc/adpulse-db/chef-report.txt' do
  owner 'root'
  group 'root'
  mode '0644'
  content <<~REPORT
    AdPulse database node, configured by Chef (Cinc), cookbook adpulse_db
    shared_buffers=#{attrs['shared_buffers']} max_connections=#{attrs['max_connections']}
    log_min_duration_statement=#{attrs['log_min_duration_statement']} statement_timeout=#{attrs['statement_timeout']}
    password_encryption=#{attrs['password_encryption']}
    pg_hba: scram-sha-256 from #{attrs['allowed_cidrs'].join(', ')}; local postgres via peer; no trust
    backups: every #{attrs['backup_interval_seconds']}s, keep #{attrs['backup_retention_count']}, quota #{attrs['backup_quota_bytes']} bytes
  REPORT
end
