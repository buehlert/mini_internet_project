#!/bin/bash
# Copyright (C) 2014 Nicira, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at:
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.



# original file at https://github.com/openvswitch/ovs/blob/master/utilities/ovs-docker
#
# Several changes have been made by Tino Rellstab and Thomas Holterbach
#
# The following changes have been made:
#   append ovs-vsctl add-port to ../groups/add_ports.sh
#   append all following comands to ../groups/ip_setup.sh
# this way all ports can be added in one go -> speeds up process by hours!!!
#
# The function add_port has been extended quite a lot for out platform
# We wrote the function connect_ports, so that a ovs switch can use to interconnect
# several pairs of containers (instead of one ovs switch for each pair of containers).
# Some other parts of the original file have been removed.

# Check for programs we'll need.
search_path () {
    save_IFS=$IFS
    IFS=:
    for dir in $PATH; do
        IFS=$save_IFS
        if test -x "$dir/$1"; then
            return 0
        fi
    done
    IFS=$save_IFS
    echo >&2 "$0: $1 not found in \$PATH, please install and try again"
    exit 1
}

ovs_vsctl () {
    ovs-vsctl --timeout=60 "$@"
}

create_netns_link () {
    mkdir -p /var/run/netns
    if [ ! -e /var/run/netns/"$PID" ]; then
        ln -s /proc/"$PID"/ns/net /var/run/netns/"$PID"
        trap 'delete_netns_link' 0
        for signal in 1 2 3 13 14 15; do
            trap 'delete_netns_link; trap - $signal; kill -$signal $$' $signal
        done
    fi
}

delete_netns_link () {
    rm -f /var/run/netns/"$PID"
}

add_port () {
    BRIDGE="$1"
    INTERFACE="$2"
    CONTAINER="$3"

    if [ -z "$BRIDGE" ] || [ -z "$INTERFACE" ] || [ -z "$CONTAINER" ]; then
        echo >&2 "$UTIL add-port: not enough arguments (use --help for help)"
        exit 1
    fi

    shift 3
    while [ $# -ne 0 ]; do
        case $1 in
            --ipaddress=*)
                ADDRESS=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --macaddress=*)
                MACADDRESS=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --gateway=*)
                GATEWAY=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --mtu=*)
                MTU=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --delay=*)
                DELAY=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --throughput=*)
                THROUGHPUT=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            *)
                echo >&2 "$UTIL add-port: unknown option \"$1\""
                exit 1
                ;;
        esac
    done

    if PID=`docker inspect -f '{{.State.Pid}}' "$CONTAINER"`; then :; else
        echo >&2 "$UTIL: Failed to get the PID of the container"
        exit 1
    fi

    create_netns_link

    echo "if [ \"$CONTAINER\" == \$container_name ]; then" >> groups/restart_container.sh
    echo "  echo \"Create Link for $CONTAINER ($INTERFACE) on bridge $BIRDGE\"" >> groups/restart_container.sh

    # Create a veth pair.
    ID=`uuidgen -s --namespace @url --name "${BRIDGE}_${INTERFACE}_${CONTAINER}" | sed 's/-//g'`
    PORTNAME="${ID:0:13}"

    echo "#ip link add "${PORTNAME}_l" type veth peer name "${PORTNAME}_c >> groups/ip_setup.sh

    ip link add "${PORTNAME}_l" type veth peer name "${PORTNAME}_c"
    echo "ip link delete "${PORTNAME}_l >> groups/delete_veth_pairs.sh

    # echo "  ip link delete "${PORTNAME}_l >> groups/restart_container.sh
    echo "  ip link add "${PORTNAME}_l" type veth peer name "${PORTNAME}_c >> groups/restart_container.sh

    echo "-- add-port "$BRIDGE" "${PORTNAME}_l" \\" >> groups/add_ports.sh
    echo "-- set interface "${PORTNAME}_l" external_ids:container_id="$CONTAINER" external_ids:container_iface="$INTERFACE" \\" >> groups/add_ports.sh

    echo "  ovs-vsctl del-port "$BRIDGE" "${PORTNAME}_l >> groups/restart_container.sh
    echo "  ovs-vsctl add-port "$BRIDGE" "${PORTNAME}_l >> groups/restart_container.sh
    echo "  ovs-vsctl set interface "${PORTNAME}_l" external_ids:container_id="$CONTAINER" external_ids:container_iface="$INTERFACE >> groups/restart_container.sh

    echo "ip link set "${PORTNAME}_l" up" >> groups/ip_setup.sh
    echo "  ip link set "${PORTNAME}_l" up" >> groups/restart_container.sh

    # Move "${PORTNAME}_c" inside the container and changes its name.
    echo "PID=$(docker inspect -f '{{.State.Pid}}' "$CONTAINER")">> groups/ip_setup.sh
    echo "create_netns_link" >> groups/ip_setup.sh
    echo "ip link set "${PORTNAME}_c" netns "\$PID"" >> groups/ip_setup.sh
    echo "ip netns exec "\$PID" ip link set dev "${PORTNAME}_c" name "$INTERFACE"" >> groups/ip_setup.sh
    echo "ip netns exec "\$PID" ip link set "$INTERFACE" up" >> groups/ip_setup.sh

    echo "  PID=\$(docker inspect -f '{{.State.Pid}}' "$CONTAINER")">> groups/restart_container.sh
    echo "  create_netns_link" >> groups/restart_container.sh
    echo "  ip link set "${PORTNAME}_c" netns "\$PID"" >> groups/restart_container.sh
    echo "  ip netns exec "\$PID" ip link set dev "${PORTNAME}_c" name "$INTERFACE"" >> groups/restart_container.sh
    echo "  ip netns exec "\$PID" ip link set "$INTERFACE" up" >> groups/restart_container.sh

    if [ -n "$MTU" ]; then
        ip netns exec "$PID" ip link set dev "$INTERFACE" mtu "$MTU"
        echo "  ip netns exec "$PID" ip link set dev "$INTERFACE" mtu "$MTU >> groups/restart_container.sh
    fi

    if [ -n "$ADDRESS" ]; then
        echo "ip netns exec "\$PID" ip addr add "$ADDRESS" dev "$INTERFACE"" >> groups/ip_setup.sh
        echo "  ip netns exec "\$PID" ip addr add "$ADDRESS" dev "$INTERFACE"" >> groups/restart_container.sh
    fi

    if [ -n "$MACADDRESS" ]; then
        echo "ip netns exec "$PID" ip link set dev "$INTERFACE" address "$MACADDRESS"" >> groups/ip_setup.sh
        echo "  ip netns exec "$PID" ip link set dev "$INTERFACE" address "$MACADDRESS"" >> groups/restart_container.sh
    fi

    if [ -n "$GATEWAY" ]; then
        echo "ip netns exec "$PID" ip route add default via "$GATEWAY"" >> groups/ip_setup.sh
        echo "  ip netns exec "$PID" ip route add default via "$GATEWAY"" >> groups/restart_container.sh
    fi

    if [ -n "$DELAY" ]; then
        echo "tc qdisc add dev "${PORTNAME}"_l root netem delay "${DELAY}" " >> groups/delay_throughput.sh
        echo "  tc qdisc add dev "${PORTNAME}"_l root netem delay "${DELAY}" " >> groups/restart_container.sh
    fi

    if [ -n "$THROUGHPUT" ]; then
        echo "echo -n \" -- set interface "${PORTNAME}"_l ingress_policing_rate="${THROUGHPUT}" \" >> groups/throughput.sh " >> groups/delay_throughput.sh
        echo "  ovs-vsctl set interface ${PORTNAME}_l ingress_policing_rate=${THROUGHPUT}" >> groups/restart_container.sh
    fi

    echo "fi" >> groups/restart_container.sh

}

add_link () {
    # TODO: add support for restarting container script

    INTERFACE_IN="$1"
    CONTAINER_IN="$2"
    INTERFACE_OUT="$3"
    CONTAINER_OUT="$4"

    # check that all required arguments are available
    if [ -z "$INTERFACE_IN" ] || [ -z "$CONTAINER_IN" ] || [ -z "$INTERFACE_OUT" ] || [ -z "$CONTAINER_OUT" ]; then
        echo >&2 "$UTIL add_link: not enough arguments (use --help for help)"
        exit 1
    fi

    # process optional arguments
    shift 4
    while [ $# -ne 0 ]; do
        case $1 in
            --number=*)
                NUM=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --number2=*)
                NUM2=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
        esac
    done

    FILE_OUT="groups/ip_setup.sh"

    if [ -n "$NUM" ]; then
        FILE_OUT="groups/additional_prefix_setup.sh"
        if [ ! -f $FILE_OUT ]; then
            touch $FILE_OUT
            echo "create_netns_link () { ">> $FILE_OUT
            echo "  mkdir -p /var/run/netns">> $FILE_OUT
            echo "  if [ ! -e /var/run/netns/"\$PID" ]; then">> $FILE_OUT
            echo "    ln -s /proc/"\$PID"/ns/net /var/run/netns/"\$PID"">> $FILE_OUT
            echo "    trap 'delete_netns_link' 0">> $FILE_OUT
            echo "    for signal in 1 2 3 13 14 15; do">> $FILE_OUT
            echo "      trap 'delete_netns_link; trap - \$signal; kill -\$signal \$\$' \$signal">> $FILE_OUT
            echo "     done">> $FILE_OUT
            echo "  fi">> $FILE_OUT
            echo "}">> $FILE_OUT
            echo " ">> $FILE_OUT
            echo "delete_netns_link () {">> $FILE_OUT
            echo "  rm -f /var/run/netns/"\$PID"">> $FILE_OUT
            echo "}">> $FILE_OUT
        fi
    fi

    if [ -n "$NUM2" ]; then
        FILE_OUT="groups/additional_host_container_setup.sh"
        if [ ! -f $FILE_OUT ]; then
            touch $FILE_OUT
            echo "create_netns_link () { ">> $FILE_OUT
            echo "  mkdir -p /var/run/netns">> $FILE_OUT
            echo "  if [ ! -e /var/run/netns/"\$PID" ]; then">> $FILE_OUT
            echo "    ln -s /proc/"\$PID"/ns/net /var/run/netns/"\$PID"">> $FILE_OUT
            echo "    trap 'delete_netns_link' 0">> $FILE_OUT
            echo "    for signal in 1 2 3 13 14 15; do">> $FILE_OUT
            echo "      trap 'delete_netns_link; trap - \$signal; kill -\$signal \$\$' \$signal">> $FILE_OUT
            echo "     done">> $FILE_OUT
            echo "  fi">> $FILE_OUT
            echo "}">> $FILE_OUT
            echo " ">> $FILE_OUT
            echo "delete_netns_link () {">> $FILE_OUT
            echo "  rm -f /var/run/netns/"\$PID"">> $FILE_OUT
            echo "}">> $FILE_OUT
        fi
    fi

    # make sure we can find PID of both containers
    if PID=`docker inspect -f '{{.State.Pid}}' "$CONTAINER_IN"`; then :; else
        echo >&2 "$UTIL: Failed to get the PID of the first container"
        exit 1
    fi

    if PID=`docker inspect -f '{{.State.Pid}}' "$CONTAINER_OUT"`; then :; else
        echo >&2 "$UTIL: Failed to get the PID of the second container"
        exit 1
    fi

    create_netns_link

    # Create a veth pair with "default" names as otherwise multiple interfaces would get the same name
    ID=`uuidgen -s --namespace @url --name "${INTERFACE_IN}_${CONTAINER_IN}" | sed 's/-//g'`
    PORTNAME="${ID:0:13}"
    if [ -n "$NUM" ]; then
        PORTNAME="${ID:0:13-${#NUM}-1}_$NUM"
    fi

    echo "#ip link add "${PORTNAME}_i" type veth peer name "${PORTNAME}_o"" >> $FILE_OUT
    ip link add "${PORTNAME}_i" type veth peer name "${PORTNAME}_o"

    # move INTERFACE_IN inside CONTAINER_IN
    echo "PID=$(docker inspect -f '{{.State.Pid}}' "${CONTAINER_IN}")">> $FILE_OUT
    echo "create_netns_link" >> $FILE_OUT
    echo "ip link set "${PORTNAME}_i" netns "\$PID"" >> $FILE_OUT
    echo "ip netns exec "\$PID" ip link set dev "${PORTNAME}_i" name "${INTERFACE_IN}"" >> $FILE_OUT
    echo "ip netns exec "\$PID" ip link set "${INTERFACE_IN}" up" >> $FILE_OUT

    # move INTERFACE_OUT inside CONTAINER_OUT
    echo "PID=$(docker inspect -f '{{.State.Pid}}' "${CONTAINER_OUT}")">> $FILE_OUT
    echo "create_netns_link" >> $FILE_OUT
    echo "ip link set "${PORTNAME}_o" netns "\$PID"" >> $FILE_OUT
    echo "ip netns exec "\$PID" ip link set dev "${PORTNAME}_o" name "${INTERFACE_OUT}"" >> $FILE_OUT
    echo "ip netns exec "\$PID" ip link set "${INTERFACE_OUT}" up" >> $FILE_OUT

    # add commands to delete
    echo "PID_IN=$(docker inspect -f '{{.State.Pid}}' "${CONTAINER_IN}")">> groups/delete_veth_pairs.sh
    echo "ip netns exec "\$PID_IN" ip link delete "${INTERFACE_IN}"" >> groups/delete_veth_pairs.sh
    echo "PID_IN=$(docker inspect -f '{{.State.Pid}}' "${CONTAINER_OUT}")">> groups/delete_veth_pairs.sh
    echo "ip netns exec "\$PID_OUT" ip link delete "${INTERFACE_OUT}"" >> groups/delete_veth_pairs.sh
}

mod_interface_properties () {
    # TODO: add support for restarting container script

    INTERFACE="$1"
    CONTAINER="$2"

    # check that all required arguments are available
    if [ -z "$INTERFACE" ] || [ -z "$CONTAINER" ]; then
        echo >&2 "$UTIL mod_interface_properties: not enough arguments (use --help for help)"
        exit 1
    fi

    # process optional arguments
    shift 2
    while [ $# -ne 0 ]; do
        case $1 in
            --number=*)
                NUM=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --number2=*)
                NUM2=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --ipaddress=*)
                ADDRESS=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --macaddress=*)
                MACADDRESS=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --gateway=*)
                GATEWAY=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --mtu=*)
                MTU=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --delay=*)
                DELAY=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --throughput=*)
                THROUGHPUT=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --flowgrind=*)
                FLOWGRIND=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --loss=*)
                LOSS=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            *)
                echo >&2 "$UTIL add-port: unknown option \"$1\""
                exit 1
                ;;
        esac
    done

    # make sure we can find PID of the container
    if PID=`docker inspect -f '{{.State.Pid}}' "$CONTAINER"`; then :; else
        echo >&2 "$UTIL: Failed to get the PID of the container"
        exit 1
    fi

    FILE_OUT="groups/ip_setup.sh"
    FILE_DELAY="groups/delay_throughput.sh"

    if [ -n "$NUM" ]; then
        FILE_OUT="groups/additional_prefix_setup.sh"
        FILE_DELAY="groups/additional_prefix_setup.sh"
        if [ ! -f $FILE_OUT ]; then
            touch $FILE_OUT
        fi
    fi

    if [ -n "$NUM2" ]; then
        FILE_OUT="groups/additional_host_container_setup.sh"
        FILE_DELAY="groups/additional_host_container_setup.sh"
        if [ ! -f $FILE_OUT ]; then
            touch $FILE_OUT
        fi
    fi

    # modify MTU
    if [ -n "$MTU" ]; then
        echo "PID=$(docker inspect -f '{{.State.Pid}}' "${CONTAINER}")">> $FILE_OUT
        echo "ip netns exec "\$PID" ip link set dev "${INTERFACE}" mtu "${MTU}"" >> $FILE_OUT
    fi

    # modify IP address
    if [ -n "$ADDRESS" ]; then
        echo "PID=$(docker inspect -f '{{.State.Pid}}' "${CONTAINER}")">> $FILE_OUT
        echo "ip netns exec "\$PID" ip addr add "${ADDRESS}" dev "${INTERFACE}"" >> $FILE_OUT
    fi

    # modify MAC address
    if [ -n "$MACADDRESS" ]; then
        echo "PID=$(docker inspect -f '{{.State.Pid}}' "${CONTAINER}")">> $FILE_OUT
        echo "ip netns exec "\$PID" ip link set dev "${INTERFACE}" address "${MACADDRESS}"" >> $FILE_OUT
    fi

    # add default gateway
    if [ -n "$GATEWAY" ]; then
        echo "PID=$(docker inspect -f '{{.State.Pid}}' "${CONTAINER}")">> $FILE_OUT
        echo "ip netns exec "\$PID" ip route add default via "${GATEWAY}"" >> $FILE_OUT
    fi

    # enable flowgrind server
    if [ -n "$FLOWGRIND" ]; then    
        echo "docker exec -d "${CONTAINER}" flowgrindd -b "${FLOWGRIND}"" >> $FILE_OUT
    fi

    # add delay, throughput and loss
    if [ -n "$DELAY" ] || [ -n "$THROUGHPUT" ] || [ -n "$LOSS" ]; then
        echo "PID=$(docker inspect -f '{{.State.Pid}}' "${CONTAINER}")">> $FILE_DELAY
        echo "ip netns exec "\$PID" tc qdisc del dev "${INTERFACE}" root" >> $FILE_DELAY

        to_add="ip netns exec "\$PID" tc qdisc add dev "${INTERFACE}" root netem limit 100000"
        if [ -n "$THROUGHPUT" ]; then
            to_add=""${to_add}" rate "${THROUGHPUT}""
        fi
        if [ -n "$DELAY" ]; then
            IFS=',' read -r -a delay_parts <<< "${DELAY}"
            if [ "${#delay_parts[@]}" == "2" ]; then
                to_add=""${to_add}" delay "${delay_parts[0]}"ms "${delay_parts[1]}"ms distribution pareto"
            else
                to_add=""${to_add}" delay "${delay_parts[0]}"ms"
            fi
        fi
        if [ -n "$LOSS" ]; then
            if [ "${LOSS}" != "0" ];then
                to_add=""${to_add}" loss "${LOSS}"%"
            fi
        fi

        echo "${to_add}" >> $FILE_DELAY
    fi
}

connect_ports () {
    BRIDGE="$1"
    INTERFACE1="$2"
    CONTAINER1="$3"
    INTERFACE2="$4"
    CONTAINER2="$5"

    if [ -z "$BRIDGE" ] || [ -z "$INTERFACE1" ] || [ -z "$CONTAINER1" ] || [ -z "$INTERFACE2" ] || [ -z "$CONTAINER2" ]; then
        echo >&2 "$UTIL connect-ports: not enough arguments (use --help for help)"
        exit 1
    fi

    ID1=`uuidgen -s --namespace @url --name ${BRIDGE}_${INTERFACE1}_${CONTAINER1} | sed 's/-//g'`
    PORTNAME1="${ID1:0:13}"
    ID2=`uuidgen -s --namespace @url --name ${BRIDGE}_${INTERFACE2}_${CONTAINER2} | sed 's/-//g'`
    PORTNAME2="${ID2:0:13}"

    echo "port_id1=\`ovs-vsctl get Interface ${PORTNAME1}_l ofport\`" >> groups/ip_setup.sh
    echo "port_id2=\`ovs-vsctl get Interface ${PORTNAME2}_l ofport\`" >> groups/ip_setup.sh

    echo "ovs-ofctl add-flow $BRIDGE in_port=\$port_id1,actions=output:\$port_id2" >> groups/ip_setup.sh
    echo "ovs-ofctl add-flow $BRIDGE in_port=\$port_id2,actions=output:\$port_id1" >> groups/ip_setup.sh

    echo "if [ \"$CONTAINER1\" == \$container_name ] || [ \"$CONTAINER2\" == \$container_name ]; then" >> groups/restart_container.sh
    echo "  echo \"Link between $CONTAINER1 ($INTERFACE1) and $CONTAINER2 ($INTERFACE2)\"" >> groups/restart_container.sh

    echo "  port_id1=\`ovs-vsctl get Interface ${PORTNAME1}_l ofport\`" >> groups/restart_container.sh
    echo "  port_id2=\`ovs-vsctl get Interface ${PORTNAME2}_l ofport\`" >> groups/restart_container.sh

    echo "  ovs-ofctl add-flow $BRIDGE in_port=\$port_id1,actions=output:\$port_id2" >> groups/restart_container.sh
    echo "  ovs-ofctl add-flow $BRIDGE in_port=\$port_id2,actions=output:\$port_id1" >> groups/restart_container.sh

    echo "fi" >> groups/restart_container.sh

}

UTIL=$(basename $0)
search_path ovs-vsctl
search_path docker
search_path uuidgen

if (ip netns) > /dev/null 2>&1; then :; else
    echo >&2 "$UTIL: ip utility not found (or it does not support netns),"\
             "cannot proceed"
    exit 1
fi

if [ "$1" == "add-port" ]; then
    shift
    $(add_port "$@")
elif [ "$1" == "connect-ports" ]; then
    shift
    $(connect_ports "$@")
elif [ "$1" == "mod-interface-properties" ]; then
    shift
    $(mod_interface_properties "$@")
elif [ "$1" == "add-link" ]; then
    shift
    $(add_link "$@")
fi
