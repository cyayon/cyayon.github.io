#!/bin/sh
# Version 04062026
#set -u

# try to autodetect prod or failover
iface_prod="enp0s20f0" ; iface_fo="enp0s2"
ipprefix="192.168.40"
ipsuffix_prod="61" ; ipsuffix_fo="63"
if ip link show dev "$iface_prod" >/dev/null 2>&1 ; then
	check=$(ip addr show dev "$iface_prod" | grep "${ipprefix}.${ipsuffix_prod}" 2>/dev/null)
	if [ ! -z "$check" ] ; then
		iface="${iface_prod}" ; ipsuffix="${ipsuffix_prod}" ; me="!!!PRODUCTION!!!"
		echo "INFO: current host is $me interface:${iface} suffix:${ipsuffix}"
	fi
else
	if ip link show dev "$iface_fo" >/dev/null 2>&1 ; then
		check=$(ip addr show dev "$iface_fo" | grep "${ipprefix}.${ipsuffix_fo}" 2>/dev/null)
		if [ ! -z "$check" ] ; then
			iface="${iface_fo}" ; ipsuffix="${ipsuffix_fo}" ; me="FAILOVER"
			echo "INFO: current host is $me interface:${iface} suffix:${ipsuffix}"
		else
			echo "NOTICE: unable to detect current host (prod or failover)"
		fi
	fi
fi

# network definitions
[ -z "$iface" ] && iface="enp0s2" 	# hass:enp0s20f0 ; hass-fo:enp0s2(default)
[ -z "$ipsuffix" ] && ipsuffix="63"     # hass:61 ; hass-fo:63(default)
vlan="42"
vlanif="${iface}.${vlan}"
table_main="$vlan"			# should not be used (just in case for cleanup)
table_vlan="1${vlan}"
ip4addr="192.168.${vlan}.${ipsuffix}"
ip4gw="192.168.${vlan}.254"
ip4net="192.168.${vlan}.0/24"
ip6addr="fd11:0:0:${vlan}::${ipsuffix}"
ip6gw="fd11:0:0:${vlan}::254"
ip6net="fd11:0:0:${vlan}::/64"
# explicit rule priorities
prio_vlan_src="10042"
prio_main_src="10043"			# should not be used (just in case for cleanup)
prio_hassio="10044"			# should not be used (just in case for cleanup)
nmcli_vlan_prof="Supervisor ${vlanif}"

# current live config on base interface
cur4addr=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')
cur6addr=$(ip -6 addr show dev "$iface" 2>/dev/null | awk '/inet6 / && $2 !~ /^fe80:/ {sub(/\/.*/, "", $2); print $2; exit}')
cur4gw=$(ip -4 route show default dev "$iface" 2>/dev/null | awk '/^default via/ {print $3; exit}')
cur6gw=$(ip -6 route show default dev "$iface" 2>/dev/null | awk '/^default via/ {print $3; exit}')
[ -z "${cur4addr:-}" ] && echo "ERROR: unable to define IPv4 on $iface" && exit 8
[ -z "${cur6addr:-}" ] && echo "ERROR: unable to define IPv6 on $iface" && exit 8
[ -z "${cur4gw:-}" ] && echo "ERROR: unable to define IPv4 gateway on $iface" && exit 8
[ -z "${cur6gw:-}" ] && echo "ERROR: unable to define IPv6 gateway on $iface" && exit 8

echo
echo "Host           : $me"
echo "Base interface : $iface"
echo "Base IPv4      : $cur4addr via $cur4gw"
echo "Base IPv6      : $cur6addr via $cur6gw"
echo "VLAN interface : $vlanif (vlan ${vlan})"
echo "VLAN IPv4      : $ip4addr via $ip4gw"
echo "VLAN IPv6      : $ip6addr via $ip6gw"
echo "Tables         : vlan-src=$table_vlan"
echo

start_ip() { 
# Create VLAN via HAOS if missing
if ! ha network info "$vlanif" >/dev/null 2>&1; then
	echo "INFO: creating HAOS VLAN $vlanif"
	ha network vlan "$iface" "$vlan" --ipv4-method static --ipv6-method static --ipv4-address "${ip4addr}/32" --ipv6-address "${ip6addr}/128"
else
	echo "INFO: $vlanif already exists"
fi

if ! ip link show dev "$vlanif" >/dev/null 2>&1 ; then
	echo "FATAL: $vlanif not created or not visible"
	return 9
fi

echo "INFO: configuring routing table $table_vlan"
ip route replace "${ip4gw}/32" dev "$vlanif" table "$table_vlan" || return $?
ip route replace "$ip4net" dev "$vlanif" table "$table_vlan" || return $?
ip route replace default via "$ip4gw" dev "$vlanif" table "$table_vlan" || return $?
ip -6 route replace "${ip6gw}/128" dev "$vlanif" table "$table_vlan" || return $?
ip -6 route replace "$ip6net" dev "$vlanif" table "$table_vlan" || return $?
ip -6 route replace default via "$ip6gw" dev "$vlanif" table "$table_vlan" || return $?

echo "INFO: cleaning old policy rules and routes"
for prio in $prio_vlan_src $prio_main_src $prio_hassio; do
	while ip rule del priority "$prio" 2>/dev/null; do :; done
	while ip -6 rule del priority "$prio" 2>/dev/null; do :; done
done
ip rule del from "$ip4addr" lookup "$table_vlan" 2>/dev/null || true
ip rule del from "$cur4addr" to "$ip4net" lookup "$table_main" 2>/dev/null || true
ip rule del to "$ip4net" iif hassio lookup "$table_main" 2>/dev/null || true
ip -6 rule del from "$ip6addr" lookup "$table_vlan" 2>/dev/null || true
ip -6 rule del from "$cur6addr" to "$ip6net" lookup "$table_main" 2>/dev/null || true
ip -6 rule del to "$ip6net" iif hassio lookup "$table_main" 2>/dev/null || true
# Optional cleanup old table 42 runtime routes (just in case)
ip route del default via "$cur4gw" dev "$iface" table "$table_main" 2>/dev/null || true
ip -6 route del default via "$cur6gw" dev "$iface" table "$table_main" 2>/dev/null || true

# Add only source-VLAN rules
echo "INFO: adding VLAN source policy rules"
ip rule add priority "$prio_vlan_src" from "$ip4addr" lookup "$table_vlan" || return $?
ip -6 rule add priority "$prio_vlan_src" from "$ip6addr" lookup "$table_vlan" || return $?
echo "INFO: runtime VLAN routing applied"
}


start_nmcli() {
if ! which nmcli >/dev/null 2>&1 ; then
	echo "ERROR: nmcli not available"
	echo "To install : apk update ; apk add networkmanager-cli"
	return 9
fi

echo "INFO: adding persistent NetworkManager vlan configuration"
nmcli_main_prof="$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v dev="$iface" '$2 == dev {print $1; exit}' 2>/dev/null)"
if [ -z "$nmcli_main_prof" ]; then
	echo "ERROR: no active profile found for $iface"
	return 1
fi
echo "INFO: using existing base profile '$nmcli_main_prof' on '$iface'"
if ! nmcli -t -f NAME con show | grep -Fxq "$nmcli_vlan_prof"; then
	echo "INFO: creating VLAN profile '$nmcli_vlan_prof'"
	nmcli con add type vlan con-name "$nmcli_vlan_prof" ifname "$vlanif" dev "$iface" id "$vlan" || return $?
else
	echo "INFO: VLAN profile '$nmcli_vlan_prof' already exists"
fi

# Current design:
# - VLAN interface and VLAN IPs are persisted with NetworkManager.
# - VLAN IPs use /32 and /128 to avoid connected VLAN routes in main.
# - All VLAN routes are explicitly stored in table_vlan.
# - Only source-VLAN policy rules are needed.
# - The base profile is not modified.
echo "INFO: configuring NetworkManager profile $nmcli_vlan_prof"
nmcli con mod "$nmcli_vlan_prof"  vlan.parent "$iface"  vlan.id "$vlan"  connection.interface-name "$vlanif"  connection.autoconnect yes  ipv4.method manual  ipv4.addresses "${ip4addr}/32"  ipv4.never-default yes  ipv4.ignore-auto-dns yes  ipv4.may-fail no  ipv6.method manual ipv6.addresses "${ip6addr}/128"  ipv6.never-default yes  ipv6.ignore-auto-dns yes  ipv6.may-fail no || return $?
# Cleanup only the VLAN profile, because this script owns it.
nmcli con mod "$nmcli_vlan_prof" ipv4.routes "" ipv6.routes "" ipv4.routing-rules "" ipv6.routing-rules "" || return $?
# VLAN source table 142.
# Add on-link routes for gateways because IPs are /32 and /128.
#nmcli con mod "$nmcli_vlan_prof"  ipv4.route-table 0  ipv6.route-table 0  +ipv4.routes "${ip4gw}/32 0.0.0.0 table=${table_vlan}"  +ipv4.routes "${ip4net} 0.0.0.0 table=${table_vlan}" +ipv4.routes "0.0.0.0/0 ${ip4gw} table=${table_vlan}" +ipv6.routes "${ip6gw}/128 :: table=${table_vlan}" +ipv6.routes "${ip6net} :: table=${table_vlan}" +ipv6.routes "::/0 ${ip6gw} table=${table_vlan}" || return $?
# Source VLAN rules only.
#nmcli con mod "$nmcli_vlan_prof"  +ipv4.routing-rules "priority ${prio_vlan_src} from ${ip4addr} table ${table_vlan}" +ipv6.routing-rules "priority ${prio_vlan_src} from ${ip6addr} table ${table_vlan}" || return $?

nmcli con mod "$nmcli_vlan_prof" ipv4.route-table "$table_vlan" ipv6.route-table "$table_vlan" +ipv4.routes "${ip4gw}/32 0.0.0.0" +ipv4.routes "${ip4net} 0.0.0.0" +ipv4.routes "0.0.0.0/0 ${ip4gw}" +ipv6.routes "${ip6gw}/128 ::" +ipv6.routes "${ip6net} ::" +ipv6.routes "::/0 ${ip6gw}" || return $?
nmcli con mod "$nmcli_vlan_prof" +ipv4.routing-rules "priority ${prio_vlan_src} from ${ip4addr} table ${table_vlan}" +ipv6.routing-rules "priority ${prio_vlan_src} from ${ip6addr} table ${table_vlan}" || return $?



echo "INFO: cleaning old policy rules and routes"
# Runtime cleanup of old table_main method, just in case.
for prio in $prio_main_src $prio_hassio; do
	while ip rule del priority "$prio" 2>/dev/null; do :; done
	while ip -6 rule del priority "$prio" 2>/dev/null; do :; done
done
ip route del default via "$cur4gw" dev "$iface" table "$table_main" 2>/dev/null || true
ip -6 route del default via "$cur6gw" dev "$iface" table "$table_main" 2>/dev/null || true

echo "INFO: bringinp up (could freeze a few seconds)"
nmcli con up "$nmcli_vlan_prof" || return $?

echo "INFO: NetworkManager persistent VLAN config applied"
}


stop_ip() {
echo "INFO: removing runtime VLAN routing configuration"
# Rules: new model only needs VLAN source rules,
# but also remove old table_main rules for cleanup compatibility.
ip rule del from "$ip4addr" lookup "$table_vlan" 2>/dev/null || true
ip -6 rule del from "$ip6addr" lookup "$table_vlan" 2>/dev/null || true
# Old model cleanup, just in case
ip rule del from "$cur4addr" to "$ip4net" lookup "$table_main" 2>/dev/null || true
ip -6 rule del from "$cur6addr" to "$ip6net" lookup "$table_main" 2>/dev/null || true
ip rule del to "$ip4net" iif hassio lookup "$table_main" 2>/dev/null || true
ip -6 rule del to "$ip6net" iif hassio lookup "$table_main" 2>/dev/null || true
# Routes table_vlan
ip route del "${ip4gw}/32" dev "$vlanif" table "$table_vlan" 2>/dev/null || true
ip route del "$ip4net" dev "$vlanif" table "$table_vlan" 2>/dev/null || true
ip route del default via "$ip4gw" dev "$vlanif" table "$table_vlan" 2>/dev/null || true
ip -6 route del "${ip6gw}/128" dev "$vlanif" table "$table_vlan" 2>/dev/null || true
ip -6 route del "$ip6net" dev "$vlanif" table "$table_vlan" 2>/dev/null || true
ip -6 route del default via "$ip6gw" dev "$vlanif" table "$table_vlan" 2>/dev/null || true
# Old table_main cleanup, just in case
ip route del default via "$cur4gw" dev "$iface" table "$table_main" 2>/dev/null || true
ip -6 route del default via "$cur6gw" dev "$iface" table "$table_main" 2>/dev/null || true
# Rules priorities, just in case
for prio in $prio_vlan_src $prio_main_src $prio_hassio; do
	while ip rule del priority "$prio" 2>/dev/null; do :; done
	while ip -6 rule del priority "$prio" 2>/dev/null; do :; done
done
# Interface:
# Do not rely on "ha network update -e" here; it means enable in many HAOS contexts.
# If you want to remove a runtime-created VLAN, use ip link delete as best-effort.
ip link delete "$vlanif" 2>/dev/null || true
# ha interface                                                                                                                                                 
ha network update ${iface}.${vlan} --disabled 2>/dev/null || true                      
echo "INFO: runtime cleanup done"
}

stop_nmcli() {
# Check nmcli available
if ! which nmcli >/dev/null 2>&1 ; then
	echo "ERROR: nmcli not available"
	echo "To install : apk update ; apk add networkmanager-cli"
	return 9
fi

echo "INFO: removing persistent NetworkManager vlan configuration"
# Detect base profile if needed
nmcli_main_prof="$( nmcli -t -f NAME,DEVICE con show --active | awk -F: -v dev="$iface" '$2 == dev {print $1; exit}' 2>/dev/null )"

if [ -n "$nmcli_main_prof" ]; then
	echo "INFO: cleaning base profile '$nmcli_main_prof'"
	nmcli con mod "$nmcli_main_prof" ipv4.routing-rules ""  ipv6.routing-rules "" 2>/dev/null || true
	nmcli con mod "$nmcli_main_prof"  -ipv4.routes "0.0.0.0/0 ${cur4gw} table=${table_main}"  -ipv6.routes "::/0 ${cur6gw} table=${table_main}"  2>/dev/null || true
else
	echo "WARNING: no active base profile found for '$iface'"
fi

if nmcli -t -f NAME con show | grep -Fxq "$nmcli_vlan_prof"; then
	echo "INFO: disabling and cleaning VLAN profile '$nmcli_vlan_prof'"
	nmcli con down "$nmcli_vlan_prof" 2>/dev/null || true
	nmcli con delete "$nmcli_vlan_prof" 2>/dev/null || true
else
	echo "INFO: VLAN profile '$nmcli_vlan_prof' does not exist"
fi

# clean runtime, just in case
stop_ip || true

echo "INFO: NetworkManager cleanup done"
}

netinfo() {
echo
echo "=== ha network info vlan  ==="     
ha network info "$vlanif" 2>/dev/null || ha network info "${iface}.${vlan}" 2>/dev/null || true
echo
echo "=== nmcli connections ==="
if which nmcli >/dev/null 2>&1; then
	nmcli con show --active 2>/dev/null || true
	echo
	nmcli con show "$nmcli_main_prof" 2>/dev/null | grep -E 'connection.id|connection.interface-name|ipv4.method|ipv4.addresses|ipv4.routes|ipv4.routing-rules|ipv4.route-table|ipv6.method|ipv6.addresses|ipv6.routes|ipv6.routing-rules|ipv6.route-table' || true
	echo
	nmcli con show "$nmcli_vlan_prof" 2>/dev/null | grep -E 'connection.id|connection.interface-name|vlan.parent|vlan.id|ipv4.method|ipv4.addresses|ipv4.routes|ipv4.routing-rules|ipv4.route-table|ipv6.method|ipv6.addresses|ipv6.routes|ipv6.routing-rules|ipv6.route-table' || true
else
	echo "INFO: nmcli not available"
fi
echo
echo "=== addr ==="
ip addr show dev "$iface" 2>/dev/null || true
ip addr show dev "$vlanif" 2>/dev/null || true
echo
echo "=== rules ==="
ip rule show
ip -6 rule show
echo
echo "=== table $table_main ==="
ip route show table "$table_main"
ip -6 route show table "$table_main"
echo
echo "=== table $table_vlan ==="
ip route show table "$table_vlan"
ip -6 route show table "$table_vlan"
echo
echo "=== hassio rules ==="
ip rule show | grep -F "iif hassio" || true
ip -6 rule show | grep -F "iif hassio" || true
echo
echo "=== route tests ==="
echo "IPv4 default/base route to VLAN target:"
ip route get "192.168.${vlan}.100" 2>/dev/null || true
echo "IPv4 from base IP to VLAN target:"
ip route get "192.168.${vlan}.100" from "$cur4addr" 2>/dev/null || true
echo "IPv4 from VLAN IP to VLAN target:"
ip route get "192.168.${vlan}.100" from "$ip4addr" 2>/dev/null || true
echo "IPv6 default/base route to VLAN target:"
ip -6 route get "fd11:0:0:${vlan}::100" 2>/dev/null || true
echo "IPv6 from base IP to VLAN target:"
ip -6 route get "fd11:0:0:${vlan}::100" from "$cur6addr" 2>/dev/null || true
echo "IPv6 from VLAN IP to VLAN target:"
ip -6 route get "fd11:0:0:${vlan}::100" from "$ip6addr" 2>/dev/null || true
echo
echo "=== expected design ==="
echo "Base/default traffic to VLAN net should use main/base path via $iface and gateway ${cur4gw}/${cur6gw}"
echo "Traffic sourced from VLAN IP should use table $table_vlan via $vlanif"
echo "Table $table_main and iif hassio rules are old design and should normally be absent"
}


check() {
ret=0
echo "INFO: checking VLAN ${vlanif} configuration"

# Interface exists
if ! ip link show "$vlanif" >/dev/null 2>&1 ; then
    echo "ERROR: interface $vlanif NOT FOUND !"
    ret=10
fi

# Addresses
mytest=$(ip -4 addr show dev "$vlanif" 2>/dev/null | grep -F "${ip4addr}/32")
if [ -z "$mytest" ] ; then
    echo "ERROR: IPv4 address ${ip4addr}/32 on $vlanif NOT FOUND !"
    ret=11
fi
mytest=$(ip -6 addr show dev "$vlanif" 2>/dev/null | grep -F "${ip6addr}/128")
if [ -z "$mytest" ] ; then
    echo "ERROR: IPv6 address ${ip6addr}/128 on $vlanif NOT FOUND !"
    ret=12
fi

# Main table must not contain VLAN route
mytest=$(ip route show table main 2>/dev/null | grep -F "$ip4net")
if [ -n "$mytest" ] ; then
    echo "ERROR: IPv4 VLAN route $ip4net found in main table !"
    echo "$mytest"
    ret=20
fi
mytest=$(ip -6 route show table main 2>/dev/null | grep -F "$ip6net")
if [ -n "$mytest" ] ; then
    echo "ERROR: IPv6 VLAN route $ip6net found in main table !"
    echo "$mytest"
    ret=21
fi

# Old table_main should normally be empty now
mytest=$(ip route show table "$table_main" 2>/dev/null)
if [ -n "$mytest" ] ; then
    echo "ERROR: old IPv4 table $table_main should be empty but contains:"
    echo "$mytest"
    ret=30
fi
mytest=$(ip -6 route show table "$table_main" 2>/dev/null)
if [ -n "$mytest" ] ; then
    echo "ERROR: old IPv6 table $table_main should be empty but contains:"
    echo "$mytest"
    ret=31
fi

# Old rules should be absent
mytest=$(ip rule show | grep -E "^${prio_main_src}:|^${prio_hassio}:")
if [ -n "$mytest" ] ; then
    echo "ERROR: old IPv4 rules $prio_main_src/$prio_hassio still present:"
    echo "$mytest"
    ret=32
fi
mytest=$(ip -6 rule show | grep -E "^${prio_main_src}:|^${prio_hassio}:")
if [ -n "$mytest" ] ; then
    echo "ERROR: old IPv6 rules $prio_main_src/$prio_hassio still present:"
    echo "$mytest"
    ret=33
fi

# VLAN table IPv4
mytest=$(ip route show table "$table_vlan" 2>/dev/null)
if [ -z "$mytest" ] ; then
    echo "ERROR: IPv4 route table $table_vlan NOT FOUND !"
    ret=40
fi
mytest=$(ip route show table "$table_vlan" 2>/dev/null | grep -F "${ip4gw} dev $vlanif")
if [ -z "$mytest" ] ; then
    echo "ERROR: IPv4 on-link gateway route ${ip4gw} dev $vlanif in table $table_vlan NOT FOUND !"
    ret=41
fi
mytest=$(ip route show table "$table_vlan" 2>/dev/null | grep -F "$ip4net dev $vlanif")
if [ -z "$mytest" ] ; then
    echo "ERROR: IPv4 route $ip4net dev $vlanif in table $table_vlan NOT FOUND !"
    ret=42
fi
mytest=$(ip route show table "$table_vlan" 2>/dev/null | grep -F "default via $ip4gw dev $vlanif")
if [ -z "$mytest" ] ; then
    echo "ERROR: IPv4 default via $ip4gw dev $vlanif in table $table_vlan NOT FOUND !"
    ret=43
fi
mytest=$(ip rule show | grep -F "from $ip4addr lookup $table_vlan")
if [ -z "$mytest" ] ; then
    echo "ERROR: IPv4 rule from $ip4addr lookup $table_vlan NOT FOUND !"
    ret=44
fi

# VLAN table IPv6
mytest=$(ip -6 route show table "$table_vlan" 2>/dev/null)
if [ -z "$mytest" ] ; then
    echo "ERROR: IPv6 route table $table_vlan NOT FOUND !"
    ret=60
fi
mytest=$(ip -6 route show table "$table_vlan" 2>/dev/null | grep -F "${ip6gw} dev $vlanif")
if [ -z "$mytest" ] ; then
    echo "ERROR: IPv6 on-link gateway route ${ip6gw} dev $vlanif in table $table_vlan NOT FOUND !"
    ret=61
fi
mytest=$(ip -6 route show table "$table_vlan" 2>/dev/null | grep -F "$ip6net dev $vlanif")
if [ -z "$mytest" ] ; then
    echo "ERROR: IPv6 route $ip6net dev $vlanif in table $table_vlan NOT FOUND !"
    ret=62
fi
mytest=$(ip -6 route show table "$table_vlan" 2>/dev/null | grep -F "default via $ip6gw dev $vlanif")
if [ -z "$mytest" ] ; then
    echo "ERROR: IPv6 default via $ip6gw dev $vlanif in table $table_vlan NOT FOUND !"
    ret=63
fi
mytest=$(ip -6 rule show | grep -F "from $ip6addr lookup $table_vlan")
if [ -z "$mytest" ] ; then
    echo "ERROR: IPv6 rule from $ip6addr lookup $table_vlan NOT FOUND !"
    ret=64
fi

# Route behaviour IPv4
mytest=$(ip route get "192.168.${vlan}.100" 2>/dev/null | grep -F "dev $iface")
if [ -z "$mytest" ] ; then
    echo "ERROR: IPv4 default route to VLAN target does not use base interface $iface !"
    ip route get "192.168.${vlan}.100" 2>/dev/null || true
    ret=70
fi
mytest=$(ip route get "192.168.${vlan}.100" from "$ip4addr" 2>/dev/null | grep -F "dev $vlanif")
if [ -z "$mytest" ] ; then
    echo "ERROR: IPv4 route from VLAN IP does not use VLAN interface $vlanif !"
    ip route get "192.168.${vlan}.100" from "$ip4addr" 2>/dev/null || true
    ret=71
fi

# Route behaviour IPv6
mytest=$(ip -6 route get "fd11:0:0:${vlan}::100" 2>/dev/null | grep -F "dev $iface")
if [ -z "$mytest" ] ; then
    echo "ERROR: IPv6 default route to VLAN target does not use base interface $iface !"
    ip -6 route get "fd11:0:0:${vlan}::100" 2>/dev/null || true
    ret=80
fi
mytest=$(ip -6 route get "fd11:0:0:${vlan}::100" from "$ip6addr" 2>/dev/null | grep -F "dev $vlanif")
if [ -z "$mytest" ] ; then
    echo "ERROR: IPv6 route from VLAN IP does not use VLAN interface $vlanif !"
    ip -6 route get "fd11:0:0:${vlan}::100" from "$ip6addr" 2>/dev/null || true
    ret=81
fi

# Return
if [ "$ret" -eq 0 ] ; then
    echo "INFO: vlan ${vlanif} correctly configured"
else
    echo "ERROR: vlan ${vlanif} is NOT PROPERLY CONFIGURED (return ${ret})"
fi

return "$ret"
}


init_nmcli() {
if ! which nmcli >/dev/null 2>&1 ; then
	echo "NOTICE: installing nmcli"
	apk update ; apk add networkmanager-cli
else
	echo "INFO: nmcli is already installed"
fi
}

usage="$0 enable|start(_nmcli|_ip)|init(_nmcli)|disable|fix|stop(_nmcli|_ip)|status|check|(net)info"

if [ -z "$1" ] ; then
	echo "usage : $usage"
	exit
fi

ret=0
case $1 in
	start_ip|start|fix) start_ip ; ret=$? ;;
	start_nmcli|enable) start_nmcli ; ret=$? ;;
	stop_ip|stop) stop_ip ; ret=$? ;;
	stop_nmcli|disable) stop_nmcli ; ret=$? ;;
	init_nmcli|init) init_nmcli ; ret=$? ;;
	info|netinfo) netinfo ; ret=$? ;;
	check|status) check ; ret=$? ;;
	*) echo "ERROR: unknown argument $1 (${usage})" ; exit 9 ;;  
esac

echo
echo "exit $ret"
exit $ret
