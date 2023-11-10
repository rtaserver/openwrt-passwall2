#!/bin/sh

CONFIG=passwall2
LOG_FILE=/tmp/log/$CONFIG.log
LOCK_FILE_DIR=/tmp/lock

flag=0

echolog() {
local d="$(date "+%Y-%m-%d %H:%M:%S")"
#echo -e "$d: $1"
echo -e "$d: $1" >> $LOG_FILE
}

config_n_get() {
local ret=$(uci -q get "${CONFIG}.${1}.${2}" 2>/dev/null)
echo "${ret:=$3}"
}

test_url() {
localurl=$1
local try=1
[ -n "$2" ] && try=$2
local timeout=2
[ -n "$3" ] && timeout=$3
local extra_params=$4
curl --help all | grep "\-\-retry-all-errors" > /dev/null
[ $? == 0 ] && extra_params="--retry-all-errors ${extra_params}"
status=$(/usr/bin/curl -I -o /dev/null -skL --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0 .0.0 Safari/537.36" ${extra_params} --connect-timeout ${timeout} --retry ${try} -w %{http_code} "$url")
case "$status" in
204)
status=200
;;
esac
echo $status
}

test_proxy() {
result=0
status=$(test_url "${probe_url}" ${retry_num} ${connect_timeout} "-x socks5h://127.0.0.1:${socks_port}")
if [ "$status" = "200" ]; then
result=0
else
status2=$(test_url "https://www.baidu.com" ${retry_num} ${connect_timeout})
if [ "$status2" = "200" ]; then
result=1
else
result=2
ping -c 3 -W 1 223.5.5.5 > /dev/null 2>&1
[ $? -eq 0 ] && {
result=1
}
fi
fi
echo $result
}

test_node() {
local node_id=$1
local _type=$(echo $(config_n_get ${node_id} type nil) | tr 'A-Z' 'a-z')
[ "${_type}" != "nil" ] && {
local _tmp_port=$(/usr/share/${CONFIG}/app.sh get_new_port 61080 tcp,udp)
/usr/share/${CONFIG}/app.sh run_socks flag="test_node_${node_id}" node=${node_id} bind=127.0.0.1 socks_port=${_tmp_port} config_file=test_node_${node_id}.json
local curlx="socks5h://127.0.0.1:${_tmp_port}"
sleep 1s
_proxy_status=$(test_url "${probe_url}" ${retry_num} ${connect_timeout} "-x $curlx")
pgrep -af "test_node_${node_id}" | awk '! /socks_auto_switch\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
rm -rf "/tmp/etc/${CONFIG}/test_node_${node_id}.json"
if [ "${_proxy_status}" -eq 200 ]; then
return 0
fi
}
return 1
}

test_auto_switch() {
flag=$(expr $flag + 1)
local b_nodes=$1
local now_node=$2
[ -z "$now_node" ] && {
local f="/tmp/etc/$CONFIG/id/socks_${id}"
if [ -f "${f}" ]; then
now_node=$(cat ${f})
else
#echolog "Auto-switch detection: unknown error"
return 1
fi
}
	
[ $flag -le 1 ] && {
main_node=$now_node
}

status=$(test_proxy)
if [ "$status" == 2 ]; then
echolog "Automatic switching detection: Unable to connect to the network, please check whether the network is normal!"
return 2
fi
	
#Check whether the master node can be used
if [ "$restore_switch" == "1" ] && [ "$main_node" != "nil" ] && [ "$now_node" != "$main_node" ]; then
test_node ${main_node}
[ $? -eq 0 ] && {
#The master node is normal, switch to the master node
echolog "Automatic switching detection: ${id} main node [$(config_n_get $main_node type): [$(config_n_get $main_node remarks)]] is normal, switch to the main node!"
/usr/share/${CONFIG}/app.sh socks_node_switch flag=${id} new_node=${main_node}
[ $? -eq 0 ] && {
echolog "Automatic switching detection: ${id} node switching completed!"
}
return 0
}
fi
	
if [ "$status" == 0 ]; then
#echolog "Automatic switching detection: ${id}[$(config_n_get $now_node type): [$(config_n_get $now_node remarks)]] is normal."
return 0
elif [ "$status" == 1 ]; then
echolog "Automatic switching detection: ${id}[$(config_n_get $now_node type):[$(config_n_get $now_node remarks)]] is abnormal, switch to the next backup node detection!"
local new_node
in_backup_nodes=$(echo $b_nodes | grep $now_node)
# Determine whether the current node exists in the backup node list
if [ -z "$in_backup_nodes" ]; then
# If it does not exist, set the first node as the new node
new_node=$(echo $b_nodes | awk -F ' ' '{print $1}')
else
# If it exists, set the next backup node as the new node
#local count=$(expr $(echo $b_nodes | grep -o ' ' | wc -l) + 1)
local next_node=$(echo $b_nodes | awk -F "$now_node" '{print $2}' | awk -F " " '{print $1}')
if [ -z "$next_node" ]; then
new_node=$(echo $b_nodes | awk -F ' ' '{print $1}')
else
new_node=$next_node
fi
fi
test_node ${new_node}
if [ $? -eq 0 ]; then
[ "$restore_switch" == "0" ] && {
uci set $CONFIG.${id}.node=$new_node
[ -z "$(echo $b_nodes | grep $main_node)" ] && uci add_list $CONFIG.${id}.autoswitch_backup_node=$main_node
uci commit $CONFIG
}
echolog "Automatic switching detection: ${id}[$(config_n_get $new_node type): [$(config_n_get $new_node remarks)]] is normal, switch to this node!"
/usr/share/${CONFIG}/app.sh socks_node_switch flag=${id} new_node=${new_node}
[ $? -eq 0 ] && {
echolog "Automatic switching detection: ${id} node switching completed!"
}
return 0
else
test_auto_switch "${b_nodes}" ${new_node}
fi
fi
}

start() {
id=$1
LOCK_FILE=${LOCK_FILE_DIR}/${CONFIG}_socks_auto_switch_${id}.lock
main_node=$(config_n_get $id node nil)
socks_port=$(config_n_get $id port 0)
delay=$(config_n_get $id autoswitch_testing_time 30)
sleep 5s
connect_timeout=$(config_n_get $id autoswitch_connect_timeout 3)
retry_num=$(config_n_get $id autoswitch_retry_num 1)
restore_switch=$(config_n_get $id autoswitch_restore_switch 0)
probe_url=$(config_n_get $id autoswitch_probe_url "https://www.google.com/generate_204")
backup_node=$(config_n_get $id autoswitch_backup_node nil)
while [ -n "$backup_node" -a "$backup_node" != "nil" ]; do
[ -f "$LOCK_FILE" ] && {
sleep 6s
continue
}
touch $LOCK_FILE
backup_node=$(echo $backup_node | tr -s ' ' '\n' | uniq | tr -s '\n' ' ')
test_auto_switch "$backup_node"
rm -f $LOCK_FILE
sleep ${delay}
done
}

start $@

