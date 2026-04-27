#!/bin/sh

# вывод скрипта в лог-файл
exec > /var/log/bastion-setup.log 2>&1
set -x

echo "--- Setup Cloudflare tunnel ---"

fallocate -l 512M /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

/usr/local/bin/cloudflared service install ${tunnel_token}

echo "Complete install)"