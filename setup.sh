#!/bin/bash
set -e
mkdir -p group_vars roles/moodle_mcp/{tasks,handlers,templates}

cat > playbook.yml << 'ENDFILE'
---
- name: Install Moodle MCP Server on Ubuntu
  hosts: moodle_mcp
  become: true

  roles:
    - moodle_mcp
ENDFILE

cat > inventory.ini << 'ENDFILE'
[moodle_mcp]
# Replace with your Ubuntu server IP or hostname
# Example:
# 192.168.1.100 ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_rsa
ENDFILE

cat > group_vars/moodle_mcp.yml << 'ENDFILE'
# Moodle MCP Server Configuration
moodle_url: "https://your-moodle-site.com"
moodle_token: "your_webservice_token"
mcp_user: moodle-mcp
mcp_group: moodle-mcp
python_min_version: "3.11"
mcp_server_repo: "git+https://github.com/lmscloud-io/moodle-mcp-server"
mcp_server_command: "moodle-mcp-server"
mcp_service_name: moodle-mcp-server

# SSE transport (for Claude.ai Connectors / Open WebUI)
mcp_transport: sse
mcp_host: "127.0.0.1"
mcp_port: 8000

# Domain for HTTPS (must point to server's public IP)
mcp_domain: "mcp.your-domain.com"
certbot_email: "your-email@example.com"

# Bearer token - generate with: openssl rand -hex 32
mcp_bearer_token: "CHANGE_ME_generate_with_openssl_rand_hex_32"

install_unix_timestamps_mcp: true
ENDFILE

cat > roles/moodle_mcp/tasks/main.yml << 'ENDFILE'
---
- name: Install system dependencies
  ansible.builtin.apt:
    name:
      - python3
      - python3-pip
      - python3-venv
      - git
      - curl
      - ca-certificates
      - nginx
      - certbot
      - python3-certbot-nginx
    state: present
    update_cache: true

- name: Check Python3 version
  ansible.builtin.command: python3 --version
  register: python_version_output
  changed_when: false

- name: Verify Python version >= 3.11
  ansible.builtin.assert:
    that:
      - python_version_output.stdout | regex_search('\\d+\\.\\d+') | float >= 3.11
    fail_msg: "Python >= 3.11 is required. Found: {{ python_version_output.stdout }}"
    success_msg: "Python version check passed: {{ python_version_output.stdout }}"

- name: Create MCP service group
  ansible.builtin.group:
    name: "{{ mcp_group }}"
    system: true
    state: present

- name: Create MCP service user
  ansible.builtin.user:
    name: "{{ mcp_user }}"
    group: "{{ mcp_group }}"
    system: true
    shell: /usr/sbin/nologin
    home: "/home/{{ mcp_user }}"
    create_home: true
    state: present

- name: Install uv package manager
  ansible.builtin.shell: |
    curl -LsSf https://astral.sh/uv/install.sh | sh
  args:
    creates: "/home/{{ mcp_user }}/.local/bin/uv"
  become: true
  become_user: "{{ mcp_user }}"
  environment:
    HOME: "/home/{{ mcp_user }}"

- name: Ensure uv is available in PATH
  ansible.builtin.lineinfile:
    path: "/home/{{ mcp_user }}/.bashrc"
    line: 'export PATH="$HOME/.local/bin:$PATH"'
    create: true
    owner: "{{ mcp_user }}"
    group: "{{ mcp_group }}"
    mode: "0644"

- name: Pre-fetch moodle-mcp-server package via uvx
  ansible.builtin.command:
    cmd: "/home/{{ mcp_user }}/.local/bin/uvx --from {{ mcp_server_repo }} {{ mcp_server_command }} --help"
  become: true
  become_user: "{{ mcp_user }}"
  environment:
    HOME: "/home/{{ mcp_user }}"
    PATH: "/home/{{ mcp_user }}/.local/bin:/usr/local/bin:/usr/bin:/bin"
  register: uvx_prefetch
  changed_when: true
  failed_when: false

- name: Install Node.js for unix-timestamps-mcp (optional)
  when: install_unix_timestamps_mcp
  block:
    - name: Install Node.js
      ansible.builtin.apt:
        name: [nodejs, npm]
        state: present

- name: Create environment file for the service
  ansible.builtin.template:
    src: moodle-mcp.env.j2
    dest: "/etc/default/{{ mcp_service_name }}"
    owner: root
    group: "{{ mcp_group }}"
    mode: "0640"
  notify: Restart moodle-mcp-server

- name: Install systemd service unit
  ansible.builtin.template:
    src: moodle-mcp-server.service.j2
    dest: "/etc/systemd/system/{{ mcp_service_name }}.service"
    owner: root
    group: root
    mode: "0644"
  notify: Restart moodle-mcp-server

- name: Enable and start moodle-mcp-server
  ansible.builtin.systemd:
    name: "{{ mcp_service_name }}"
    enabled: true
    state: started
    daemon_reload: true

# --- Nginx reverse proxy with HTTPS and Bearer token auth ---

- name: Remove default nginx site
  ansible.builtin.file:
    path: /etc/nginx/sites-enabled/default
    state: absent
  notify: Reload nginx

- name: Deploy nginx config (HTTP only for initial certbot)
  ansible.builtin.template:
    src: nginx-mcp-initial.conf.j2
    dest: "/etc/nginx/sites-available/{{ mcp_service_name }}"
    owner: root
    group: root
    mode: "0644"
  notify: Reload nginx

- name: Enable nginx site
  ansible.builtin.file:
    src: "/etc/nginx/sites-available/{{ mcp_service_name }}"
    dest: "/etc/nginx/sites-enabled/{{ mcp_service_name }}"
    state: link
  notify: Reload nginx

- name: Ensure nginx is running
  ansible.builtin.systemd:
    name: nginx
    enabled: true
    state: started

- name: Flush handlers to apply nginx config before certbot
  ansible.builtin.meta: flush_handlers

- name: Obtain SSL certificate with certbot
  ansible.builtin.command:
    cmd: >
      certbot certonly --webroot
      -w /var/www/html
      -d {{ mcp_domain }}
      --email {{ certbot_email }}
      --agree-tos
      --non-interactive
    creates: "/etc/letsencrypt/live/{{ mcp_domain }}/fullchain.pem"

- name: Deploy full nginx config with SSL and Bearer auth
  ansible.builtin.template:
    src: nginx-mcp.conf.j2
    dest: "/etc/nginx/sites-available/{{ mcp_service_name }}"
    owner: root
    group: root
    mode: "0644"
  notify: Reload nginx

- name: Set up certbot auto-renewal cron
  ansible.builtin.cron:
    name: "Certbot renewal"
    minute: "30"
    hour: "2"
    job: "certbot renew --quiet --post-hook 'systemctl reload nginx'"
ENDFILE

cat > roles/moodle_mcp/handlers/main.yml << 'ENDFILE'
---
- name: Restart moodle-mcp-server
  ansible.builtin.systemd:
    name: "{{ mcp_service_name }}"
    state: restarted
    daemon_reload: true

- name: Reload nginx
  ansible.builtin.systemd:
    name: nginx
    state: reloaded
ENDFILE

cat > roles/moodle_mcp/templates/moodle-mcp.env.j2 << 'ENDFILE'
MOODLE={{ moodle_url }}
TOKEN={{ moodle_token }}
FASTMCP_TRANSPORT={{ mcp_transport }}
FASTMCP_HOST={{ mcp_host }}
FASTMCP_PORT={{ mcp_port }}
ENDFILE

cat > roles/moodle_mcp/templates/moodle-mcp-server.service.j2 << 'ENDFILE'
[Unit]
Description=Moodle MCP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={{ mcp_user }}
Group={{ mcp_group }}
EnvironmentFile=/etc/default/{{ mcp_service_name }}
Environment=HOME=/home/{{ mcp_user }}
Environment=PATH=/home/{{ mcp_user }}/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/home/{{ mcp_user }}/.local/bin/uvx --from {{ mcp_server_repo }} {{ mcp_server_command }}
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/{{ mcp_user }}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
ENDFILE

cat > roles/moodle_mcp/templates/nginx-mcp-initial.conf.j2 << 'ENDFILE'
server {
    listen 80;
    server_name {{ mcp_domain }};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 503 '{"error": "SSL not yet configured"}';
        add_header Content-Type application/json;
    }
}
ENDFILE

cat > roles/moodle_mcp/templates/nginx-mcp.conf.j2 << 'ENDFILE'
server {
    listen 80;
    server_name {{ mcp_domain }};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name {{ mcp_domain }};

    ssl_certificate /etc/letsencrypt/live/{{ mcp_domain }}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{{ mcp_domain }}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # Bearer token authentication
    set $auth_ok 0;
    if ($http_authorization = "Bearer {{ mcp_bearer_token }}") {
        set $auth_ok 1;
    }
    if ($auth_ok = 0) {
        return 401 '{"error": "Unauthorized"}';
    }

    # SSE endpoint
    location /sse {
        proxy_pass http://{{ mcp_host }}:{{ mcp_port }}/sse;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection '';
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 86400s;
        chunked_transfer_encoding off;
    }

    # MCP message endpoint
    location /messages/ {
        proxy_pass http://{{ mcp_host }}:{{ mcp_port }}/messages/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        return 404 '{"error": "Not found"}';
    }
}
ENDFILE

echo ""
echo "All files created! Next steps:"
echo "  1. Edit group_vars/moodle_mcp.yml with your values"
echo "  2. git add . && git commit -m 'Add HTTPS + Bearer auth for Claude.ai Connectors' && git push"
