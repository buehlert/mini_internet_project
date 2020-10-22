#!/bin/bash
#
# adds BGP configurations to enable/disable BGP hijacks
# hijack targets defined in ./config/add_hijacks.txt

set -o errexit
set -o pipefail
set -o nounset

DIRECTORY="$1"

# read configs
readarray hijacks < "${DIRECTORY}"/config/add_hijacks.txt

n_hijacks=${#hijacks[@]}

for ((i=0;i<n_hijacks;i++)); do
    hijack_i=(${hijacks[$i]})
    grp="${hijack_i[0]}"
    router="${hijack_i[1]}"
    prefix="${hijack_i[2]}"
    next_hop="${hijack_i[3]}"
    prepending="${hijack_i[4]}"

    location="${DIRECTORY}"/groups/g"${grp}"/"${router}"/add_hijack.sh

    if [ -f $location ]; then
        rm $location
        touch $location
        chmod +x $location
    fi

done

for ((i=0;i<n_hijacks;i++)); do
    hijack_i=(${hijacks[$i]})
    grp="${hijack_i[0]}"
    router="${hijack_i[1]}"
    prefix="${hijack_i[2]}"
    next_hop="${hijack_i[3]}"
    prepending="${hijack_i[4]}"

    IFS=',' read -r -a to_prepend <<< "${prepending}"
    n_ases=${#to_prepend[@]}
    prepend_string=""
    for ((n=0;n<n_ases;n++)); do
        prepend_string="${prepend_string} ${to_prepend[n]}"
    done

    location="${DIRECTORY}"/groups/g"${grp}"/"${router}"/add_hijack.sh

    echo "#!/bin/bash" >> "${location}"
    echo "vtysh -c 'conf t' \\" >> "${location}"

    # add static route and add hijacked prefix to OWN_PREFIX route-map
    echo "-c 'ip route 212.0.0.0/22 "${next_hop}"' \\" >> "${location}"
    echo "-c 'ip route 212.1.0.0/22 "${next_hop}"' \\" >> "${location}"
    echo "-c 'ip route 212.2.0.0/22 "${next_hop}"' \\" >> "${location}"
    echo "-c 'ip prefix-list OWN_PREFIX seq "$((100+$i))" permit "${prefix}"' \\" >> "${location}"

    # uncomment if not done outside of the script
    # echo "-c 'route-map HIJACK permit 5' \\" >> "${location}"
    # echo "-c 'set as-path prepend"${prepend_string}"' \\" >> "${location}"
    # echo "-c 'exit' \\" >> "${location}"
    
    # echo "# enable/disable hijack" >> "${location}"
    # echo "# conf t" >> "${location}"
    # echo "# router bgp "${grp}"" >> "${location}"
    # echo "# network "${prefix}" route-map HIJACK" >> "${location}"
    # echo "# no network "${prefix}" route-map HIJACK" >> "${location}"

done

for ((i=0;i<n_hijacks;i++)); do
    hijack_i=(${hijacks[$i]})
    grp="${hijack_i[0]}"
    router="${hijack_i[1]}"
    prefix="${hijack_i[2]}"
    next_hop="${hijack_i[3]}"
    prepending="${hijack_i[4]}"

    location="${DIRECTORY}"/groups/g"${grp}"/"${router}"/add_hijack.sh

    echo "-c 'exit' \\" >> "${location}"
    echo "-c 'write'" >> "${location}"

    docker cp "${location}" "${grp}"_"${router}"router:/home/add_hijacks.sh
    docker exec -d "${grp}"_"${router}"router bash ./home/add_hijacks.sh &

done
