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
install_unix_timestamps_mcp: true
ENDFILE

cat > roles/moodle_mcp/tasks/main.yml << 'ENDFILE'
---
- name: Install system dependencies
  ansible.builtin.apt:
    name: [python3, python3-pip, python3-venv, git, curl, ca-certificates]
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
ENDFILE

cat > roles/moodle_mcp/handlers/main.yml << 'ENDFILE'
---
- name: Restart moodle-mcp-server
  ansible.builtin.systemd:
    name: "{{ mcp_service_name }}"
    state: restarted
    daemon_reload: true
ENDFILE

cat > roles/moodle_mcp/templates/moodle-mcp.env.j2 << 'ENDFILE'
MOODLE={{ moodle_url }}
TOKEN={{ moodle_token }}
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

echo "All files created! Now run:"
echo "  git add . && git commit -m 'Add Ansible playbook' && git push"
