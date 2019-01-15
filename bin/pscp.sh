#!/bin/bash
set -e

DEFAULT_LOCAL_TMP_DIR='/tmp'
DEFAULT_REMOTE_TMP_DIR='/tmp'
DEFAULT_PARALLELISM=10
VERBOSE=${VERBOSE:-false}

file=''
dest=''
dest_host=''
dest_path=''
parallelism=$DEFAULT_PARALLELISM
local_tmp_dir=$DEFAULT_LOCAL_TMP_DIR
remote_tmp_dir=$DEFAULT_REMOTE_TMP_DIR
verify_checksum=true
measure_time=false
stats_file=''
skip_cleanup=false
setup_cmd=''
tx_name="pscp_$(date +%s)"

function usage {
  local scriptname=`basename "$0"`
  echo "Parallel Secure Copy - copy file in chunks"
  echo ""
  echo "Usage:"
  echo "  ${scriptname} [OPTIONS] FILE DEST"
  echo ""
  echo "Arguments"
  echo "  FILE  The local file to copy"
  echo "  DEST  The destination to copy to."
  echo "        This is the same as usually provided to scp."
  echo "        For example: myuser@other-host:/path/to/dest_file"
  echo ""
  echo "Options"
  echo "  -p,--parallelism=<value>  Set the parallelism level (default: $DEFAULT_PARALLELISM)."
  echo "                            This is the number of chunks the file will be split to."
  echo "     --no-verify            Skip checksum verification after the transfer."
  echo '     --no-cleanup           Skip cleanup of the temporary files created during the transfer.'
  echo "     --timing               Measure the total transfer time in seconds."
  echo "     --stats-file=<file>    Write (append) transfer statistics to a file in CSV format."
  echo "                            The file has the following columns:"
  echo "                            Size (B),Parallelism,Transfer Time (Sec),Assembly Time (Sec)"
  echo "     --setup=<command>      Run a setup command:"
  echo "                              uninstall  - uninstall pscp"
  echo "                              update     - update pscp to its latest version"
  echo "     --verbose              Show verbose output."
  echo "  -h,--help                 Show this help."
  echo ""
  echo "Examples"
  echo "  ${scriptname} myfile myuser@some-other-host:/path/to/"
  echo "    Will transfer a file named 'myfile' in the local directory to the target host"
  echo "    named 'some-other-host' to the destination path '/path/to/myfile', authenticating"
  echo "    as user 'myuser'. This uses the default settings (e.g. parallelism: ${DEFAULT_PARALLELISM})"
  echo ""
  exit 0
}

function logVerbose {
  if [[ "${VERBOSE}" == true ]]; then
    echo "$@"
  fi
}

function exitWithError {
  echo "ERROR: $1"
  exit ${2:-1}
}

function strIndexOf {
  local prefix="${1%%$2*}"
  [[ "$prefix" == "$1" ]] && echo -1 || echo "${#prefix}"
}

function optionValue {
  local i=$(strIndexOf "$1" =)
  i=$((i+1))
  echo "${1:$i}"
}

function installMe {
  curl -s https://raw.githubusercontent.com/yinonavraham/pscp/master/bin/setup/install.sh | bash
}

function uninstallMe {
  if [[ -f /usr/local/bin/pscp.d/uninstal.sh ]]; then
    /usr/local/bin/pscp.d/uninstal.sh
  else
    logVerbose "Local uninstall script not found. Falling back to downloading and executing latest script from github."
    curl -s https://raw.githubusercontent.com/yinonavraham/pscp/master/bin/setup/uninstall.sh | bash
  fi
}

function updateMe {
  echo "Updating pscp..."
  uninstallMe
  installMe
}

function parseArgs {
  local i=1
  local arg_index=1
  while [ "$i" -le "$#" ]; do
    eval "arg=\${$i}"
    logVerbose "arg $i : $arg"

    if [[ "$arg" == '-'* ]]; then
      case "$arg" in
      	-h|--help)
          usage
          ;;
      	-p=*|--parallelism=*)
          parallelism="$(optionValue $arg)"
          ;;
        --no-verify)
          verify_checksum=false
          ;;
        --no-cleanup)
          skip_cleanup=true
          ;;
        --timing)
          measure_time=true
          ;;
        --stats-file=*)
          stats_file="$(optionValue $arg)"
          ;;
        --setup=*)
          setup_cmd="$(optionValue $arg)"
          ;;
        --verbose)
          VERBOSE=true
          ;;
        *)
          exitWithError "Unknown option or missing a value: $arg"
          ;;
      esac
    else
      case $arg_index in
        1) file="$arg"
           ;;
        2) dest="$arg"
           local colonIndex=$(strIndexOf "$dest" :)
           dest_host="${dest:0:$colonIndex}"
           dest_path="${dest:$((colonIndex+1))}"
           ;;
        *) exitWithError "Unexpected argument: $arg"
           ;;
      esac
      arg_index=$((arg_index+1))
    fi

    i=$((i+1))
  done

  logVerbose "File:         ${file}"
  logVerbose "Destination:  ${dest} (host: $dest_host , path: $dest_path)"
  logVerbose "Parallelism:  ${parallelism}"
}

function errorIfEmpty {
  if [ -z $2 ]; then
  	exitWithError "$1"
  fi
}

function errorIfNotNumber {
  if ! [[ "$2" =~ ^[0-9]+$ ]]; then
    exitWithError "$1 (not a number)"
  fi
}

function errorIfNotNumberBetween {
  local msg="$1"
  local min=$2
  local max=$3
  local num=$4
  errorIfNotNumber "$msg" $num
  if [[ $num -lt $min ]] || [[ $num -gt $max ]]; then
    exitWithError "$msg (not in range)"
  fi
}

function errorIfNotFile {
  local msg=$1
  local file=$2
  if ! [[ -f "$file" ]]; then
    exitWithError "$msg"
  fi
}

function validateArgs {
  errorIfEmpty "FILE argument is required!" $file
  errorIfEmpty "DEST argument is required!" $dest
  errorIfNotFile "File does not exist or not a regular file: $file" $file
  errorIfNotNumberBetween "parallelism must be a number in the range: [1..20] (got: ${parallelism})" 1 20 $parallelism
}

function wcReturnResult {
  local result=$(wc "$@" | sed 's/^ *//g' | sed 's/  *.*//g')
  echo $result
}

function calcFileSize {
  local size=$(wcReturnResult -c "$file")
  echo $size
}

function calcChunkSize {
  local size=$(calcFileSize)
  local chunk=$((size/parallelism + 1))
  echo $chunk
}

function stripFileName {
  local filepath="$1"
  i=$(strIndexOf "$filepath" /)
  while [[ i -ge 0 ]]; do
    filepath="${filepath:$((i+1))}"
    i=$(strIndexOf "$filepath" /)
  done
  echo "$filepath"
}

function scpPartFile {
  local partFile="$1"
  local remoteTxDir="$2"
  local counterFile="$3"
  local destPartPath="${remoteTxDir}/$(stripFileName "$partFile")"
  local partDest="${dest_host}:${destPartPath}"
  logVerbose "Starting scp $partFile $partDest"
  scp "$partFile" "${partDest}"
  logVerbose "Finished scp $partFile $partDest"
  echo "$partFile" >> "$counterFile"
}

function waitForCounter {
  local counterFile="$1"
  local start=$(date +%s)
  i=1
  while [ ! -f "$counterFile" ] || [[ "$(wcReturnResult -l "${counterFile}")" != "${parallelism}" ]]; do
    sleep 0.5
    if [[ $((i % 10)) -eq 0 ]]; then 
      logVerbose "Waiting for transaction to finish (started $(($(date +%s)-start)) seconds ago)"
    fi
    i=$((i+1))
  done
}

function calcLocalFileChecksum {
  shasum "$1" | sed 's/  *.*//g'
}

function execRemote {
  local remoteHost="$1"
  local cmd="$2"
  ssh -t "$remoteHost" "$cmd"
}

function calcRemoteFileChecksum {
  local remoteHost="$1"
  local remoteFile="$2"
  local shaLine=$(execRemote "$remoteHost" "shasum $remoteFile" | tail -1)
  echo "$shaLine" | sed 's/  *.*//g'
}

function handleSetupCommand {
  if [[ ! -z "$setup_cmd" ]]; then
    logVerbose "Handling setup command: $setup_cmd"
    case $setup_cmd in
      uninstall)
        uninstallMe
        ;;
      update)
        updateMe
        ;;
      *)
        exitWithError "Unexpected setup command: $setup_cmd"
        ;;
    esac
    exit 0
  fi
}

########################################################

parseArgs "$@"
handleSetupCommand
validateArgs

# Create local transaction directory
logVerbose "Transaction name: $tx_name"
local_tx_dir="$local_tmp_dir/$tx_name"
logVerbose "Local transaction temporary directory: $local_tx_dir"
mkdir -p $local_tx_dir

# Calculate the file size and the average chunk (part) size
total_size=$(calcFileSize)
chunk=$(calcChunkSize)
logVerbose "Total size: ${total_size} bytes - $((parallelism-1)) chunks of ${chunk} bytes, 1 chunck of $((total_size-(parallelism-1)*chunks)) bytes"

# Split the file to several parts of chunk size into the local transaction directory
local_file_name=$(stripFileName "$file")
logVerbose "File name: $local_file_name"
part_file_prefix="${local_tx_dir}/${local_file_name}_" 
logVerbose "Splitting file to ${parallelism} parts with the following prefix: $part_file_prefix"
split -b $chunk "$file" "$part_file_prefix"

# Resolve the remote file path
remote_file_path="$([[ "$(stripFileName "$dest_path")" == "" ]] && echo "${dest_path}${local_file_name}" || echo "$dest_path")"
remote_tx_dir="${remote_tmp_dir}/${tx_name}"
logVerbose "Remote file path: $remote_file_path , Remote TX directory: $remote_tx_dir"
execRemote "$dest_host" "mkdir $remote_tx_dir"

start_transfer_time="$(date +%s)"
counter_file="${local_tx_dir}/.counter"
for f in "${part_file_prefix}"*; do
  scpPartFile "$f" "$remote_tx_dir" "$counter_file" &
done
waitForCounter "$counter_file"
end_transfer_time="$(date +%s)"
transfer_time="$((end_transfer_time - start_transfer_time))"
logVerbose "Transfer time: $transfer_time seconds"

execRemote "$dest_host" "cat ${remote_tx_dir}/${local_file_name}_* > ${remote_file_path}"
end_assembly_time="$(date +%s)"
assembly_time="$((end_assembly_time - end_transfer_time))"
logVerbose "Assembly time: $assembly_time seconds"

if [[ "$measure_time" == "true" ]]; then 
  echo "Timing:"
  echo "  Transfer: $transfer_time seconds"
  echo "  Assembly: $assembly_time seconds"
fi

if [[ "$verify_checksum" != "false" ]]; then
  local_file_checksum=$(calcLocalFileChecksum "$file")
  logVerbose "Local file checksum: $local_file_checksum"
  remote_file_checksum=$(calcRemoteFileChecksum "$dest_host" "$remote_file_path")
  logVerbose "Remote file checksum: $remote_file_checksum"
  if [[ "$local_file_checksum" != "$remote_file_checksum" ]]; then
    exitWithError "Transfer failed (checksum mismatch)"
  fi
fi

if [[ ! -z "$stats_file" ]]; then
  size=$(calcFileSize)
  echo "${size},${parallelism},${transfer_time},${assembly_time}" >> "$stats_file"
fi

if [[ "$skip_cleanup" != "true" ]]; then
  logVerbose "Deleting all files in the local transaction directory: ${local_tx_dir}"
  rm -r "${local_tx_dir}"
  logVerbose "Deleting all files in the remote transaction directory: ${dest_host}:${local_tx_dir}"
  execRemote "${dest_host}" "rm -r ${remote_tx_dir}"
else 
  logVerbose "Skipping cleanup"
fi
