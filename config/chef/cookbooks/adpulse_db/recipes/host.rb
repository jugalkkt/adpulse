#
# Cookbook:: adpulse_db
# Recipe:: host
#
# AWS VM host side of the database node: a host directory for backup exports
# and log rotation for Docker's JSON container logs.

host_attrs = node['adpulse_db']['host']

directory host_attrs['backup_dir'] do
  owner 'root'
  group 'root'
  mode '0750'
  recursive true
end

file '/etc/logrotate.d/adpulse-docker' do
  owner 'root'
  group 'root'
  mode '0644'
  content <<~ROTATE
    # Managed by Chef (Cinc), adpulse_db::host
    /var/lib/docker/containers/*/*-json.log {
      daily
      rotate 7
      maxsize 50M
      compress
      delaycompress
      missingok
      notifempty
      copytruncate
    }
  ROTATE
end

file '/etc/adpulse-db-host-report.txt' do
  owner 'root'
  group 'root'
  mode '0644'
  content <<~REPORT
    AdPulse DB host settings, managed by Chef (Cinc), recipe adpulse_db::host
    backup dir: #{host_attrs['backup_dir']} (root, 0750)
    logrotate: /var/lib/docker/containers/*/*-json.log daily, 7 kept, max 50M, compressed
  REPORT
end
