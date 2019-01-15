#!/usr/bin/env bash

set -e

echo "Installing pscp..."

if [[ -f /usr/local/bin/pscp ]]; then
  echo "pscp already installed!"
  exit 1
fi

if [[ ! -d /usr/local/bin ]]; then
  mkdir -p /usr/local/bin
fi

mkdir -p /usr/local/bin/pscp.d

curl -fsSL https://raw.githubusercontent.com/yinonavraham/pscp/master/bin/pscp.sh -o /usr/local/bin/pscp.d/pscp.sh
curl -fsSL https://raw.githubusercontent.com/yinonavraham/pscp/master/bin/setup/uninstall.sh -o /usr/local/bin/pscp.d/uninstall.sh
chmod +x /usr/local/bin/pscp.d/*.sh

ln -s /usr/local/bin/pscp.d/pscp.sh /usr/local/bin/pscp

if [[ "$(which pscp)" == '' ]]; then
  echo "pscp installation failed!"
  exit 1
fi

echo "Installation finished successfully. Use pscp --help for usage information."