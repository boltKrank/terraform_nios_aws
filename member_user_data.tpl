#cloud-config
write_files:
  - path: /etc/infoblox/join_info.json
    content: |
      {
        "grid_master": "${master_ip}",
        "token":       "${token}"
      }
runcmd:
  - /usr/local/sbin/infoblox-join-grid.sh --input /etc/infoblox/join_info.json
