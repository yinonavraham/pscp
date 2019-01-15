#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

function __shellcheck {
  docker run -v "$PWD:/mnt" koalaman/shellcheck:stable "$1"
}

function __ensureInstalled {
  if ! command -v "$1" > /dev/null; then
    echo "ERROR: Not installed (at least not in PATH): $1"
    exit 1
  fi
}

function __appendDelimited {
  local original="$1"
  local delimiter="$2"
  local suffix="$3"
  if [[ -z "${original}" ]]; then
    echo "${suffix}"
  else
    echo "${original}${delimiter}${suffix}"
  fi
}

function __shellcheckAppendIfFailed {
  local script="$1"
  local origFailedScripts="$2"
  local failedScripts="${origFailedScripts}"
  local scriptDir
  local scriptFile
  local originalPwd
  scriptDir="$(dirname "${script}")"
  scriptFile="$(basename "${script}")"
  originalPwd="$(pwd)"

  echo "LINT: ${script}" >&2
  cd "${scriptDir}"
  __shellcheck "${scriptFile}" >&2 || failedScripts="$(__appendDelimited "$failedScripts" ", " "${script}")"
  [[ "${failedScripts}" == "${origFailedScripts}" ]] && echo "PASS: ${script}" >&2 || echo "FAIL: ${script}" >&2
  echo "${failedScripts}"

  cd "${originalPwd}"
}

__ensureInstalled docker

cd ..
failedScripts=''
failedScripts=$(__shellcheckAppendIfFailed "test/lint.sh" "${failedScripts}")
failedScripts=$(__shellcheckAppendIfFailed "bin/pscp.sh" "${failedScripts}")
failedScripts=$(__shellcheckAppendIfFailed "bin/setup/install.sh" "${failedScripts}")
failedScripts=$(__shellcheckAppendIfFailed "bin/setup/uninstall.sh" "${failedScripts}")

if [[ -n "${failedScripts}" ]]; then
  echo "The following scripts have lint errors: ${failedScripts}"
  echo "Overall LINT result: FAIL"
  exit 1
fi

echo "Overall LINT result: PASS"