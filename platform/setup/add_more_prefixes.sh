#!/bin/bash
#
# adds additional prefixes to existing hosts (with new interface)
# prefixes defined in ./config/additional_prefixes.txt

set -o errexit
set -o pipefail
set -o nounset

DIRECTORY="$1"

# read configs
readarray prefixes < "${DIRECTORY}"/config/additional_prefixes.txt

prefix_numbers=${#prefixes[@]}

for ((i=0;i<prefix_numbers;i++)); do
    prefix_i=(${prefixes[$i]})
    grp="${prefix_i[0]}"
    router="${prefix_i[1]}"
    throughput="${prefix_i[2]}"
    delay="${prefix_i[3]}"
    loss="${prefix_i[4]}"
    ip_prefix="${prefix_i[5]}"
    num="${prefix_i[6]}"

    IFS='/' read -r -a address <<< "${ip_prefix}"
    IFS='.' read -r -a ip_parts <<< "${address[0]}"
    prefix_host="${ip_parts[0]}"".""${ip_parts[1]}"".""${ip_parts[2]}"".1/""${address[1]}"
    prefix_router="${ip_parts[0]}"".""${ip_parts[1]}"".""${ip_parts[2]}"".2/""${address[1]}"
    ip_host="${ip_parts[0]}"".""${ip_parts[1]}"".""${ip_parts[2]}"".1"
    ip_router="${ip_parts[0]}"".""${ip_parts[1]}"".""${ip_parts[2]}"".2"

    ./setup/ovs-docker.sh add-link add_if_"${num}" "${grp}"_"${router}"router \
        add_if_"${num}" "${grp}"_"${router}"host --number="${num}"
    ./setup/ovs-docker.sh mod-interface-properties add_if_"${num}" "${grp}"_"${router}"router \
            --delay="${delay}" --throughput="${throughput}" --loss="${loss}" --number="${num}"
    ./setup/ovs-docker.sh mod-interface-properties add_if_"${num}" "${grp}"_"${router}"host \
            --delay="${delay}" --throughput="${throughput}" --ipaddress="${prefix_host}" \
            --loss="${loss}" --number="${num}" --flowgrind="${ip_host}"

    # make sure that incoming traffic exits over same interface and not uses default gateway
    location="${DIRECTORY}"/groups/additional_prefix_setup.sh
    echo "ip netns exec "\$PID" echo "$((100+$num))" table"${num}" >> /etc/iproute2/rt_tables" >> $location
    echo "ip netns exec "\$PID" ip rule add from "${ip_host}" table table"${num}"" >> $location
    echo "ip netns exec "\$PID" ip route add default via "${ip_router}" dev add_if_"${num}" table table"${num}"" >> $location

done

chmod +x groups/additional_prefix_setup.sh
./groups/additional_prefix_setup.sh

for ((i=0;i<prefix_numbers;i++)); do
    prefix_i=(${prefixes[$i]})
    grp="${prefix_i[0]}"
    router="${prefix_i[1]}"
    throughput="${prefix_i[2]}"
    delay="${prefix_i[3]}"
    loss="${prefix_i[4]}"
    ip_prefix="${prefix_i[5]}"
    num="${prefix_i[6]}"

    IFS='/' read -r -a address <<< "${ip_prefix}"
    IFS='.' read -r -a ip_parts <<< "${address[0]}"
    prefix_host="${ip_parts[0]}"".""${ip_parts[1]}"".""${ip_parts[2]}"".1/""${address[1]}"
    prefix_router="${ip_parts[0]}"".""${ip_parts[1]}"".""${ip_parts[2]}"".2/""${address[1]}"

    location="${DIRECTORY}"/groups/g"${grp}"/"${router}"/add_config_prefixes.sh

    if [ ! -f $location ]; then
        touch $location
        chmod +x $location
        echo "#!/bin/bash" >> "${location}"
        echo "vtysh -c 'conf t' \\" >> "${location}"
    fi

    echo "-c 'interface add_if_"${num}"' \\" >> "${location}"
    echo "-c 'ip address "${prefix_router}"' \\" >> "${location}"
    echo "-c 'exit' \\" >> "${location}"
    echo "-c 'router ospf' \\" >> "${location}"
    echo "-c 'network "${ip_prefix}" area 0' \\" >> "${location}"
    echo "-c 'exit' \\" >> "${location}"
    echo "-c 'router bgp "${grp}"' \\" >> "${location}"
    echo "-c 'network "${ip_prefix}"' \\" >> "${location}"
    echo "-c 'exit' \\" >> "${location}"
    echo "-c 'ip prefix-list OWN_PREFIX seq "$((10+$num))" permit "${ip_prefix}"' \\" >> "${location}"

done

for ((i=0;i<prefix_numbers;i++)); do
    prefix_i=(${prefixes[$i]})
    grp="${prefix_i[0]}"
    router="${prefix_i[1]}"
    throughput="${prefix_i[2]}"
    delay="${prefix_i[3]}"
    loss="${prefix_i[4]}"
    ip_prefix="${prefix_i[5]}"
    num="${prefix_i[6]}"

    location="${DIRECTORY}"/groups/g"${grp}"/"${router}"/add_config_prefixes.sh
    echo "-c 'exit' \\" >> "${location}"
    echo "-c 'write' \\" >> "${location}"
    echo "-c 'clear ip bgp *' \\" >> "${location}"

    docker cp "${location}" "${grp}"_"${router}"router:/home/add_config_prefixes.sh
    docker exec -d "${grp}"_"${router}"router bash ./home/add_config_prefixes.sh &

done
