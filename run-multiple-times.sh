#!/bin/bash

set -e

max_runs=10
command_sequence=(
    "echo 'command 1'"
    "echo 'command 2'"
)

while getopts "n:" opt; do
    case $opt in
        n) max_runs="$OPTARG" ;;
        *) echo "Usage: $0 [-n times]"; exit 1 ;;
    esac
done

for ((run=1; run<=max_runs; run++)); do
    echo -e "\n\e[34m==== No. ${run} running ====\e[0m"

    for cmd in "${command_sequence[@]}"; do
        echo -e "\e[33mExecute command: ${cmd}\e[0m"
        if ! eval "$cmd"; then
            echo -e "\e[31mError: No. ${run} running failed, command: ${cmd}\e[0m"
            exit 1
        fi
    done
done

echo -e "\n\e[32m✓ All ${max_runs} times of running success!\e[0m"
