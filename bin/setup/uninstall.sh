#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

echo "Uninstalling pscp..."

if [[ ! -f /usr/local/bin/pscp ]]; then
  echo "pscp is not installed!"
  exit 1
fi

rm /usr/local/bin/pscp
rm -r /usr/local/bin/pscp.d

echo "Uninstall finished successfully."