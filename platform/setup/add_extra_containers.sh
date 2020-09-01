#!/bin/bash
#
# add extra host containers to one AS to allow for more prefixes/IPs to be used

set -o errexit
set -o pipefail
set -o nounset

DIRECTORY="$1"
source "${DIRECTORY}"/config/subnet_config.sh

readarray hosts < "${DIRECTORY}"/config/add_extra_containers.txt

host_numbers=${#hosts[@]}

if [ -f "${DIRECTORY}"/groups/additional_host_container_setup.sh ]; then
    rm "${DIRECTORY}"/groups/additional_host_container_setup.sh
fi

for ((k=0;k<host_numbers;k++)); do
    host_k=(${hosts[$k]})
    as_number="${host_k[0]}"
    router_name="${host_k[1]}"
    container_name="${host_k[2]}"
    prefix="${host_k[3]}"
    prefix_announced="${host_k[4]}"
    throughput="${host_k[5]}"
    delay="${host_k[6]}"
    seq="${host_k[7]}"

    subnet_dns="$(subnet_router_DNS "${as_number}" "dns")"

    # start host
    docker run -itd --net='none' --dns="${subnet_dns%/*}"  \
        --name="${as_number}""_""${container_name}""host" --cap-add=NET_ADMIN \
        --cpus=2 --pids-limit 100 --hostname "${container_name}""_host" \
        --sysctl net.ipv4.icmp_ratelimit=0 \
        --sysctl net.ipv4.conf.default.rp_filter=0 \
        --sysctl net.ipv4.conf.all.rp_filter=0 \
        -v /etc/timezone:/etc/timezone:ro \
        -v /etc/localtime:/etc/localtime:ro buehlert/d_host \

    # add link
    IFS='/' read -r -a prefix_parts <<< "${prefix}"
    IFS='.' read -r -a ip_parts <<< "${prefix_parts[0]}"
    host_ip_address="${ip_parts[0]}"".""${ip_parts[1]}"".""${ip_parts[2]}"".1"
    subnet_host="${host_ip_address}""/""${prefix_parts[1]}"
    router_ip_address="${ip_parts[0]}"".""${ip_parts[1]}"".""${ip_parts[2]}"".2"
    subnet_router="${router_ip_address}""/""${prefix_parts[1]}"

    ./setup/ovs-docker.sh add-link "host""${container_name}" "${as_number}"_"${router_name}"router \
        "${router_name}""router" "${as_number}"_"${container_name}"host --number2=1

    ./setup/ovs-docker.sh mod-interface-properties "host""${container_name}" "${as_number}"_"${router_name}"router \
        --delay="${delay}" --throughput="${throughput}" --number2=1
    ./setup/ovs-docker.sh mod-interface-properties "${router_name}""router" "${as_number}"_"${container_name}"host \
        --delay="${delay}" --throughput="${throughput}" --number2=1

    # set default ip address and default gw in host
    echo "docker exec -d "${as_number}"_"${container_name}"host ifconfig "${router_name}"router "${subnet_host}" up" >> "${DIRECTORY}"/groups/additional_host_container_setup.sh
    echo "docker exec -d "${as_number}"_"${container_name}"host ip route add default via "${router_ip_address} >> "${DIRECTORY}"/groups/additional_host_container_setup.sh
    ./setup/ovs-docker.sh mod-interface-properties "${router_name}""router" "${as_number}"_"${container_name}"host \
    --flowgrind="${host_ip_address}" --number2=1

done

chmod +x "${DIRECTORY}"/groups/additional_host_container_setup.sh
./"${DIRECTORY}"/groups/additional_host_container_setup.sh

for ((k=0;k<host_numbers;k++)); do
    host_k=(${hosts[$k]})
    as_number="${host_k[0]}"
    router_name="${host_k[1]}"
    container_name="${host_k[2]}"
    prefix="${host_k[3]}"
    prefix_announced="${host_k[4]}"
    throughput="${host_k[5]}"
    delay="${host_k[6]}"
    seq="${host_k[7]}"

    IFS='/' read -r -a prefix_parts <<< "${prefix}"
    IFS='.' read -r -a ip_parts <<< "${prefix_parts[0]}"
    host_ip_address="${ip_parts[0]}"".""${ip_parts[1]}"".""${ip_parts[2]}"".1"
    subnet_host="${host_ip_address}""/""${prefix_parts[1]}"
    router_ip_address="${ip_parts[0]}"".""${ip_parts[1]}"".""${ip_parts[2]}"".2"
    subnet_router="${router_ip_address}""/""${prefix_parts[1]}"

    # add corresponding router config
    location="${DIRECTORY}"/groups/g"${as_number}"/"${router_name}"/add_extra_hosts.sh

    if [ -f $location ]; then
        rm $location
    fi

    if [ ! -f $location ]; then
        touch $location
        chmod +x $location
        echo "#!/bin/bash" >> "${location}"
        echo "vtysh -c 'conf t' \\" >> "${location}"
    fi

    echo " -c 'interface host"${container_name}"' \\" >> "${location}"
    echo " -c 'ip address "${subnet_router}"' \\" >> "${location}"
    echo " -c 'exit' \\" >> "${location}"

    echo " -c 'ip prefix-list OWN_PREFIX seq "${seq}" permit "${prefix_announced}"' \\" >> "${location}"

    echo " -c 'router bgp "${as_number}"' \\" >> "${location}"
    echo " -c 'network "${prefix_announced}"' \\" >> "${location}"
    echo " -c 'exit' \\" >> "${location}"
    echo " -c 'exit' \\" >> "${location}"

    docker cp "${location}" "${as_number}"_"${router_name}"router:/home/add_hijacks.sh
    docker exec -d "${as_number}"_"${router_name}"router bash ./home/add_hijacks.sh &

done
