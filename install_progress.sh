#!/bin/bash
cd $(dirname $0)

username="nexus"

if [ ! -f "workspace/iplist.txt" ]; then
      echo "Error: workspace/iplist.txt does not exist."
      exit 1
fi

if [ "$(id -u)" != "0" ]; then
   if [ ! -f "hosts.txt" ]; then
        touch hosts.txt
   else
        cat /dev/null > hosts.txt
   fi
else
   if [ ! -f "hosts.txt" ]; then
      touch hosts.txt &&  chmod 666 hosts.txt
   else
      cat /dev/null > hosts.txt
   fi
fi

hosts=$(awk '{split($3, parts, "/"); print parts[1]}' workspace/iplist.txt | grep -v '^$')
for host in ${hosts[*]}
do
   grep -wqF "$host" hosts.txt || echo "$host" >> hosts.txt
done

machines=()
while IFS= read -r line; do
      machines+=("$line")
done < hosts.txt

for machine in "${machines[@]}"
do
     sudo -u $username ssh-keygen -f "/home/${username}/.ssh/known_hosts" -R "$machine" > /dev/null 2>&1
     sudo -u $username ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${username}@$machine" "echo 'SSH to $machine successful'" 2>/dev/null
     if [ $? -eq 0 ]; then
        echo
     else
         echo "Failed to SSH to $machine"
	 grep -vxF "$machine" hosts.txt > /tmp/hosts.tmp && mv /tmp/hosts.tmp hosts.txt
     fi
done
echo -e "Generating hosts.txt"

# ssh localhost
manager_ip=$(grep "manager_ip" workspace/config.yaml | cut -d ":" -f 2 | tr -d '[:space:]')
sudo -u $username ssh-keygen -f "/home/${username}/.ssh/known_hosts" -R "$manager_ip" > /dev/null 2>&1
sudo -u $username ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${username}@$manager_ip" "echo 'SSH to $manager_ip successful'" 2>/dev/null
if [ $? -eq 0 ]; then
        sudo -u $username ssh "${username}@$manager_ip" "exit"
fi
