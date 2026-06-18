#!/bin/bash
cd $(dirname $0)
clear
# delete_logs of dnsmasq(docker)
delete_logs() {
    if [ ! -d "workspace/log" ]; then
        mkdir -p "workspace/log"
    fi
    logs=("workspace/log/dnsmasq.log")

    for log in "${logs[@]}"; do
        if [ -f "$log" ]; then
            rm "$log"
        fi
    done
}

# Function to check the iplist.txt format
check_iplist_format() {
    file_path="$1"
    # Check if the file exists
    if [ ! -f "$file_path" ]; then
        echo "Warning: File $file_path does not exist."
        return 1
    fi
    while IFS= read -r line; do
        fields=($line) # Split the line into fields
        # Check if the number of fields is 5
        if [ ${#fields[@]} -ne 5 ]; then
            echo "Incorrect format on line iplist.txt: $line"
            continue
        fi
        # Check if the 3rd column is a valid IP address with subnet mask
        if ! echo "${fields[2]}" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$'; then
            echo "Invalid IP address with subnet mask in the 3rd column on line of iplist.txt: $line"
            continue
        fi

        # Check if the DNS column is a valid IP address
        if [ "${fields[4]}" != "none" ] && ! echo "${fields[4]}" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$'; then
            echo "Invalid DNS in the 4th column on line of iplist.txt: $line"
            continue
        fi
    done <"$file_path"
}

delete_logs
check_iplist_format "workspace/iplist.txt"

CONFIG_FILE="workspace/config.yaml"
if [ -f "$CONFIG_FILE" ]; then
    iso=$(grep "iso" "$CONFIG_FILE" | cut -d ":" -f 2 | tr -d '[:space:]')
    if [ -n "$iso" ] && [ ! -f "workspace/${iso}" ]; then
        echo "Error: ISO not exist: workspace/${iso}"
        echo "Please download the ISO file and place it in the workspace directory."
        exit 1
    fi

    manager_ip=$(grep "manager_ip" "$CONFIG_FILE" | cut -d ":" -f 2 | tr -d '[:space:]')
    manager_nic=$(grep "manager_nic" "$CONFIG_FILE" | cut -d ":" -f 2 | tr -d '[:space:]')

    if [ -n "$manager_nic" ] && [ ! -d "/sys/class/net/$manager_nic" ]; then
        echo "Error: manager_nic '$manager_nic' does not exist on this node."
        exit 1
    fi

    if [ -n "$manager_ip" ]; then
        if ! ip addr show "$manager_nic" 2>/dev/null | grep -q "$manager_ip"; then
            echo "Error: manager_ip '$manager_ip' is not configured on '$manager_nic'."
            exit 1
        fi
    fi
fi

if docker ps -a --format '{{.Image}}' | grep -q "ainexus-lite:v1.0"; then
    docker stop $(docker ps -a -q --filter ancestor=ainexus-lite:v1.0) >/dev/null
    docker rm $(docker ps -a -q --filter ancestor=ainexus-lite:v1.0) >/dev/null
    docker rmi ainexus-lite:v1.0 >/dev/null
fi


if type uname >/dev/null 2>&1; then
    arch=$(uname -m)
    case "$arch" in
    aarch64)
        docker import ainexus-lite-arm ainexus-lite:v1.0 >/dev/null &
        pid=$!
        while ps -p $pid >/dev/null; do
            echo -n "*"
            sleep 2
        done
        echo
        ;;
    amd64 | x86_64)
        docker import ainexus-lite ainexus-lite:v1.0 >/dev/null &
        pid=$!
        while ps -p $pid >/dev/null; do
            echo -n "*"
            sleep 2
        done
        echo
        ;;
    *)
        echo "[Error]: Processor $arch is not supported"
        exit 1
        ;;
    esac
fi

docker run --name podsys-lite --privileged=true -it --network=host -v $PWD/workspace:/workspace ainexus-lite:v1.0 /bin/bash

sleep 1
if docker ps -a --format '{{.Image}}' | grep -q "ainexus-lite:v1.0"; then
    docker stop $(docker ps -a -q --filter ancestor=ainexus-lite:v1.0) >/dev/null
    docker rm $(docker ps -a -q --filter ancestor=ainexus-lite:v1.0) >/dev/null
    docker rmi ainexus-lite:v1.0 >/dev/null
fi
