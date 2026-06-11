#!/bin/sh
# Version 20260429-mp
# check multiwan routes and operate as required
#
# TODO
#

Usage="usage : $0 -a start|stop|show|reload|status|unlock|check|auto -i interface [ -C config ] [ -d destination ] [ -p 4|6|64|46 ] [ -v via-address ] [ -s src-address ] [ -m metric ] [ -M persistent-metric ] [ -t table ] [ -c check-script ] [ -D daemon-sleep ] [ -V verbose:1|quiet:0 ] [ -46fh ]"

# default log params
Logprefix="check-route"
Logdir="/var/log/nbux"
Rundir="/run/check-route"
Confdir="/etc/nbux"
Lockdir="/tmp/check-route"
Promdir="/tmp/node_exporter"
Logfile="${Logdir}/check-route.log"
Statusfile="${Rundir}/check-route.status"
NOmailfile="${Rundir}/check-route.nomail"
DateFMT="+%b %d %Y %H:%M:%S"
#Syslog=

# ping params
CheckPing_dest="1.1.1.1 8.8.8.8 9.9.9.9"
CheckPing_dest4="1.1.1.1 8.8.8.8 9.9.9.9"
CheckPing_dest6="2606:4700:4700::1111 2a07:a8c0:: 2a07:a8c1::"
# use CheckPing_src to bind a specific IP address (instead of iface)
#CheckPing_src="x.x.x.x"
#CheckPing_src4="x.x.x.x"
#CheckPing_src6="xxxx:xxxx:xxxx::x"
CheckPing_count=3
CheckPing_wait=4

# timeout on exec (if defined, all exec will be timeout prefixed)
TimeoutExec="-s INT -k 2s 10"

# exec on startup
BootExec=

# Email alert
Alert="root"

# exec status
StatusExec=
StatusExec4=
StatusExec6=
# exec stop
StopExec=
StopExec4=
StopExec6=
# exec start
StartExec=
StartExec4=
StartExec6=
# exec reload
ReloadExec=
ReloadExec4=
ReloadExec6=

# periodical script and modulo exec (no exec on link status)
CronExec=
CronExec4=
CronExec6=
CronAlert=
CronAlert4=
CronAlert6=

# periodical script and modulo exec on down/link status
CronDownExec=
CronDownExec4=
CronDownExec6=
CronDownAlert=
CronDownAlert4=
CronDownAlert6=

# periodical script and modulo exec on up status
CronUpExec=
CronUpExec4=
CronUpExec6=
CronUpAlert=
CronUpAlert4=
CronUpAlert6=

# step
StepExec=
StepExec4=
StepExec6=

# check (replace default check_ping)
Check=
Check4=
Check6=

# repeated abnormal status in the same hour (just notify, reset next hour)
MaxRepeat=3


#########################################################################################################################################
#########################################################################################################################################
#########################################################################################################################################


# init Status & return codes
StatusUP=0 ; StatusDOWN=1 ; StatusLINK=2 ; StatusRELOAD=3 ; StatusERROR=4 ; StatusUNKW=5 ; StatusSTOP=6 ; StatusSTART=7
Status="$StatusUNKW" ; StatusName="UNKNOWN" ; StatusPrevious="$StatusUNKW" ; StatusPreviousName="UNKNOWN"



#
# functions
#

# usage : log message [ email ]
log() {
	[ -z "$1" ] && echo "ERROR : log() bad usage !" && return 9
	local logdate=`date "$DateFMT"`
	local i
	local e
	local t

	[ ! -z "$2" ] && e="<${2}>"

	echo "$Logprefix $1   $e"
	[ ! -z "$Logfile" ] && echo "$logdate $Logprefix $1   $e" >> "$Logfile"
	[ ! -z "$Syslog" ] && [ "$Syslog" = "1" ] && logger -t "$Logprefix" "$1   $e"

	if [ -f "${NOmailfile}" ] ; then
		log "NOTICE: $NOmailfile exist, skipping mail notification"
	else
		if [ ! -z "$2" ] ; then
			if echo "$2" | grep -E "@|root" >/dev/null 2>&1 ; then
				t=`echo "$1" | cut -c1-80`
				for i in $2 ; do
					#( echo "$1" | mail -s "${LOGPREFIX}: $t" "$i" ) &
					# moved to msmtp to avoid stalled issue with mail command
					( echo -e "Subject:${Logprefix}: $t \n\n${1}" | msmtp --timeout=3 "$i" ) &
				done
			fi
		fi
	fi
}

# usage : status
status() {
	local r=0
	local match
	local i
	local status_link=0
	local status_proute=0
	local status_sroute=0
	local status_route=0
	local status_frule=0
	local status_table=0
	local status_exec=0
	local status_check=0
	local status_this=0
	local me="STATUS${Proto}"
	local status_prev_var="$varStatusPrevious"
	local status_prev=$(eval echo \$${status_prev_var})
	local logdate=`date "${DateFMT}"`


	# init 
	Status=$StatusUNKW ; StatusName="UNKNOWN"
	[ -z "$status_prev" ] && status_prev="$Status"

	# check interface carrier link
	match=`ip link show dev $Iface 2>/dev/null | grep -i "NO-CARRIER" 2>/dev/null`
	if [ ! -z "$match" ] ; then
		status_link=1
		status_this=1
	else
		match=`echo "$match" | tr '\012' ';'`
	fi

	# check persistent metric route if defined
	if [ ! -z "$MetricPersist" ]  ; then
		match=`ip -${Proto} route show $Dest $Via dev $Iface $Src metric $MetricPersist 2>/dev/null`
		if [ -z "$match" ] ; then
			status_proute=1
			status_this=1
			[ "$Verbose" != "quiet" ] && log "WARNING $me: persistent route [ip -${Proto} route show $Dest $Via dev $Iface $Src metric $MetricPersist] DOWN"
		else
			if echo "$match" | grep -Ei "linkdown|dead" >/dev/null 2>&1 ; then
				#status_proute=1
				status_link=1
				status_this=1
				[ "$Verbose" != "quiet" ] && log "WARNING $me: persistent route [ip -${Proto} route show $Dest $Via dev $Iface $Src metric $MetricPersist] LINK"
			else
				match=`echo "$match" | tr '\012' ';'`
			fi
		fi
	fi

	# check table route if defined
	if [ ! -z "$Table" ]  ; then
		match=`ip -${Proto} route show $Dest $Via dev $Iface $Src table $Table 2>/dev/null`
		if [ -z "$match" ] ; then
			status_table=1
			status_this=1
			[ "$Verbose" != "quiet" ] && log "WARNING $me: table route [ip -${Proto} route show $Dest $Via dev $Iface $Src table $Table] DOWN"
		else
			if echo "$match" | grep -Ei "linkdown|dead" >/dev/null 2>&1 ; then
				#status_table=1
				status_link=1
				status_this=1
				[ "$Verbose" != "quiet" ] && log "WARNING $me: table route [ip -${Proto} route show $Dest $Via dev $Iface $Src table $Table] LINK"
			else
				match=`echo "$match" | tr '\012' ';'`
			fi
		fi

		# subroute
		for i in ${SubRoute} ; do
			match=`ip -${Proto} route show $i table $Table 2>/dev/null`
			if [ -z "$match" ] ; then
				status_sroute=1
				status_this=1
				[ "$Verbose" != "quiet" ] && log "WARNING $me: table subroute [ip -${Proto} route show $i table $Table] DOWN"
			else
				match=`echo "$match" | tr '\012' ';'`
			fi
		done

		# rule from
		for i in ${RuleFrom} ; do
			match=`ip -${Proto} rule show from $i lookup $Table prio $Table 2>/dev/null`
			if [ -z "$match" ] ; then
				status_frule=1
				status_this=1
				[ "$Verbose" != "quiet" ] && log "WARNING $me: rule from lookup [ip -${Proto} rule show from $i lookup $Table prio $Table] DOWN"
			else
				match=`echo "$match" | tr '\012' ';'`
			fi
		done

	fi

	# check main route
	match=`ip -${Proto} route show $Dest $Via dev $Iface $Src metric $Metric 2>/dev/null`
	if [ -z "$match" ] ; then
		status_route=1
		status_this=1
		[ "$Verbose" != "quiet" ] && log "WARNING $me: main route [ip -${Proto} route show $Dest $Via dev $Iface $Src metric $Metric] DOWN"
	else
		if echo "$match" | grep -Ei "linkdown|dead" >/dev/null 2>&1 ; then
			#status_route=1
			status_link=1
			status_this=1
			[ "$Verbose" != "quiet" ] && log "WARNING $me: main route [ip -${Proto} route show $Dest $Via dev $Iface $Src metric $Metric] LINK"
		else
			match=`echo "$match" | tr '\012' ';'`
		fi
	fi

	# check test (ping ...) - ONLY IF LINK IS NOT DOWN
	if [ $status_link -ne 1 ] ; then
		check $1 ; r=$?
		if [ $r -ne 0 ] ; then
			status_check=1
			status_this=1
			[ "$Verbose" != "quiet" ] && log "WARNING $me: check [$Check] ($r) FAILED"
		else
			[ $status_this -ne 0 ] && log "WARNING $me: check [$Check] ($r) passed but previous errors found"
		fi
	else
		status_check=1
		status_this=1
		log "WARNING $me: check [$Check] skipped due to link failure, considering FAILED"
	fi

	# exec supplement
	if [ ! -z "$StatusExec" ] ; then
		[ "$Verbose" != "quiet" ] && log "NOTICE $me: timeout $TimeoutExec StatusExec [$StatusExec]"
		timeout $TimeoutExec sh -c "$StatusExec" ; r=$?
		if [ $r -ne 0 ] ; then
			status_exec=1
			status_this=1
			[ "$Verbose" != "quiet" ] && log "WARNING $me: timeout $TimeoutExec StatusExec [$StatusExec] ($r) FAILED"
		fi
	fi

	if [ $status_link -eq 0 ] ; then
		# link up
		# everything up
		[ $status_proute -eq 0 ] && [ $status_route -eq 0 ] && [ $status_sroute -eq 0 ] && [ $status_frule -eq 0 ] && [ $status_table -eq 0 ] && [ $status_exec -eq 0 ] && [ $status_check -eq 0 ] && Status=$StatusUP && StatusName="UP"

		# partial up (start required)
		( [ $status_route -eq 1 ] || [ $status_proute -eq 1 ] || [ $status_table -eq 1 ] || [ $status_sroute -eq 1 ] || [ $status_frule -eq 1 ] ) && ( [ $status_check -eq 0 ] && [ $status_exec -eq 0 ] ) && Status=$StatusSTART && StatusName="START"
		# restored by tier (start required)
		[ $status_prev -eq $StatusDOWN ] && [ $Status -eq $StatusUP ] && Status=$StatusSTART && StatusName="START"

		# full down consistent (failover mode success - stop not required)
		[ $status_route -eq 1 ] && [ $status_check -eq 1 ] && Status=$StatusDOWN && StatusName="DOWN"

		# partial down (stop required)
		[ $status_route -eq 0 ] && ( [ $status_check -eq 1 ] || [ $status_exec -eq 1 ] || [ $status_table -eq 1 ] || [ $status_proute -eq 1 ] || [ $status_frule -eq 1 ] ) && Status=$StatusSTOP && StatusName="STOP"

		# others issues reload required (linkup, check ok but others down, inconsistent, recovering, ...)
		( [ $status_proute -eq 0 ] && [ $status_sroute -eq 0 ] && [ $status_check -eq 0 ] && [ $status_frule -eq 0 ] ) && ( [ $status_route -eq 1 ] || [ $status_table -eq 1 ] || [ $status_exec -eq 1 ] ) && Status=$StatusRELOAD && StatusName="RELOAD"
		( [ $status_route -eq 0 ] && [ $status_sroute -eq 0 ] && [ $status_check -eq 0 ] && [ $status_frule -eq 0 ] ) && ( [ $status_proute -eq 1 ] || [ $status_table -eq 1 ] || [ $status_exec -eq 1 ] || [ $status_route -eq 1 ] ) && Status=$StatusRELOAD && StatusName="RELOAD"
	else
		# link down (major issue)
		# but check success (strange !), then reload.
		if [ $status_check -eq 0 ] ; then
			Status=$StatusRELOAD && StatusName="RELOAD" 
		else
			Status=$StatusLINK && StatusName="LINK"
		fi
	fi

	# define return code
	r=$Status

	if [ $r -eq $StatusUP ] ; then
		if [ "$1" = "verbose" ] ; then
			show
			log "DEBUG $me: link:${status_link} route:${status_route} proute:${status_proute} sroute:${status_sroute} frule:${status_frule} table:${status_table} exec:${status_exec} check:${status_check} status:${StatusName}[${Status}<${status_prev}] (${r})"
		fi
	else
		if [ "$Verbose" != "quiet" ] ; then
			show
			log "WARNING $me: link:${status_link} route:${status_route} proute:${status_proute} sroute:${status_sroute} frule:${status_frule} table:${status_table} exec:${status_exec} check:${status_check} status:${StatusName}[${Status}<${status_prev}] (${r})"
		fi
	fi

	# prometheus / no - in prometheus metrics/filename
	if [ ! -z "$Promfile" ] ; then
		echo -e "# checkroute_${Iface}_${Dest}_${Proto} gauge\ncheckroute_${Iface}_${Dest}_${Proto} {interface=\"${Iface}\",protocol=\"${Proto}\",route=\"${Dest}\",metric=\"${Metric}\"} $Status" > "$Promfile"
	fi

	# status
    sed -i "s/^.*; ${me} ;.*$/${logdate} ; $me ; dev:${Iface} proto:${Proto} route:${Dest} return:${r} status:${Status} ; link:${status_link} route:${status_route} proute:${status_proute} sroute:${status_sroute} frule:${status_frule} table:${status_table} exec:${status_exec} check:${status_check}/g" "$Statusfile" >/dev/null 2>&1

	return $r
}


# usage : reload
reload() {
	local r=0
	local me="RELOAD${Proto}"
	local logdate=`date "${DateFMT}"`

	if [ "$Verbose" != "quiet" ] ; then
		log "NOTICE $me: proto:$Proto dev:$Iface route:[$Dest $Via $Src] metric:$Metric Table:$Table"
		show
		log "NOTICE $me: dev up [ip link set up dev $Iface]"
	fi

	ip link set up dev $Iface
	[ "$Verbose" != "quiet" ] && show

	if [ ! -z "$ReloadExec" ] ; then
		[ "$Verbose" != "quiet" ] && log "NOTICE $me: timeout $TimeoutExec ReloadExec [$ReloadExec]"
		timeout $TimeoutExec sh -c "$ReloadExec" ; r=$?
		if [ $r -eq 0 ] ; then
			log "INFO $me: ReloadExec [${ReloadExec}] (${r}) success"
		else
			log "ERROR $me: timeout $TimeoutExec ReloadExec [$ReloadExec] (${r}) FAILED" "$Alert"
			r=$StatusERROR
		fi
		[ "$Verbose" != "quiet" ] && show
	else
		log "INFO $me: no ReloadExec defined"
	fi

	# status
    sed -i "s/^.*; ${me} ;.*$/${logdate} ; $me ; dev:${Iface} proto:${Proto} route:${Dest} return:${r} status:${Status}/g" "$Statusfile" >/dev/null 2>&1

	return $r
}


# usage : start
start() {
	local status_route=0
	local status_proute=0
	local status_sroute=0
	local status_table=0
	local status_frule=0
	local status_exec=0
	local r=0
	local match
	local i
	local j
	local me="START${Proto}"
    local logdate=`date "${DateFMT}"`


	# init 
	[ -z "$Status" ] && Status=$StatusUNKW && StatusName="UNKNOWN"

	if [ "$Verbose" != "quiet" ] ; then
		#log "NOTICE $me: proto:$Proto dev:$Iface route:[$Dest $Via $Src] metric:$Metric Table:$Table" "$Alert"
		log "NOTICE $me: proto:$Proto dev:$Iface route:[$Dest $Via $Src] metric:$Metric Table:$Table" 
		show
	fi

	# add route
	match=`ip -${Proto} route show $Dest $Via dev $Iface $Src metric $Metric 2>/dev/null`
	if [ -z "$match" ] ; then
		[ "$Verbose" != "quiet" ] && log "NOTICE $me: add main route [ip -${Proto} route replace $Dest $Via dev $Iface $Src metric $Metric]"
		ip -${Proto} route replace $Dest $Via dev $Iface $Src metric $Metric ; status_route=$?
		if [ $status_route -ne 0 ] ; then
			log "ERROR $me: main route [ip -${Proto} route replace $Dest $Via dev $Iface $Src metric $Metric] (${status_route}) FAILED" "$Alert"
			status_route=$StatusERROR
		fi
	else
		[ "$Verbose" != "quiet" ] && log "INFO $me: main route [ip -${Proto} route $Dest $Via dev $Iface $Src metric $Metric] already exist"
	fi

	# add persistent route
	if [ ! -z "$MetricPersist" ] ; then
		match=`ip -${Proto} route show $Dest $Via dev $Iface $Src metric $MetricPersist 2>/dev/null`
		if [ -z "$match" ] ; then
			[ "$Verbose" != "quiet" ] && log "NOTICE $me: add persistent route [ip -${Proto} route replace $Dest $Via dev $Iface $Src metric $MetricPersist]"
			ip -${Proto} route replace $Dest $Via dev $Iface $Src metric $MetricPersist ; status_proute=$?
			if [ $status_proute -ne 0 ] ; then
				log "ERROR $me: persistent route [ip -${Proto} route replace $Dest $Via dev $Iface $Src metric $MetricPersist] (${status_proute}) FAILED" "$Alert"
				status_proute=$StatusERROR
			fi
		else
			[ "$Verbose" != "quiet" ] && log "INFO $me: persistent route [ip -${Proto} route $Dest $Via dev $Iface $Src metric $MetricPersist] already exist"
		fi
	fi

	# add route table if defined
	if [ ! -z "$Table" ] ; then
		match=`ip -${Proto} route show $Dest $Via dev $Iface $Src table $Table 2>/dev/null`
		if [ -z "$match" ] ; then
			[ "$Verbose" != "quiet" ] && log "NOTICE $me: add table route [ip -${Proto} route replace $Dest $Via dev $Iface $Src table $Table]"
			ip -${Proto} route replace $Dest $Via dev $Iface table $Table ; status_table=$?
			if [ $status_table -ne 0 ] ; then
				log "ERROR $me: table route [ip -${Proto} route replace $Dest $Via dev $Iface $Src table $Table] (${status_table}) FAILED" "$Alert"
				status_table=$StatusERROR
			fi
		else
			[ "$Verbose" != "quiet" ] && log "INFO $me: table route [ip -${Proto} route $Dest $Via dev $Iface $Src table $Table] already exist"
		fi

		# subroute
		for i in ${SubRoute} ; do
			match=`echo "$i" | cut -d/ -f1 2>/dev/null | sed 's/\.0$//' 2>/dev/null`
			if [ ! -z "$match" ] ; then
				# try to found related interface for subnet
				j=`ip -${Proto} addr show 2>/dev/null | awk -v subnet="$match" '/^[0-9]+:/ {iface=$2; gsub(":", "", iface)} /inet/ {split($2, addr, "/"); if (addr[1] ~ subnet) {print iface; exit}}' 2>/dev/null | cut -d@ -f1 2>/dev/null | tail -1 2>/dev/null`
				if [ ! -z "$j" ] ; then
					match=`ip -${Proto} route show $i dev $j table $Table 2>/dev/null`
					if [ -z "$match" ] ; then
						[ "$Verbose" != "quiet" ] && log "NOTICE $me: add table subroute dev [ip -${Proto} route replace $i dev $j proto static table $Table]"
						ip -${Proto} route replace $i dev $j proto static table $Table ; status_sroute=$?
						if [ $status_sroute -ne 0 ] ; then
							log "ERROR $me: table subroute dev [ip -${Proto} route replace $i dev $j proto static table $Table] FAILED" "$Alert"
							status_sroute=$StatusERROR
						fi
					else
						[ "$Verbose" != "quiet" ] && log "INFO $me: table subroute dev [ip -${Proto} route $i dev $j table $Table] already exist"
					fi
				else
					log "WARNING $me: unable to define dev for subroute $i table $Table"
					status_sroute=$StatusWARNING
				fi
			else
				log "WARNING $me: unable to define subnet for subroute $i dev $j table $Table"
				status_sroute=$StatusWARNING
			fi
		done

		# rule from
		for i in ${RuleFrom} ; do
			match=`ip -${Proto} rule show from $i lookup $Table prio $Table 2>/dev/null`
			if [ -z "$match" ] ; then
				[ "$Verbose" != "quiet" ] && log "NOTICE $me: add rule from lookup [ip -${Proto} rule add from $i lookup $Table prio $Table proto static]"
				ip -${Proto} rule add from $i lookup $Table prio $Table proto static ; status_frule=$?
				if [ $status_frule -ne 0 ] ; then
					log "ERROR $me: rule from loookup [ip -${Proto} rule add from $i lookup $Table prio $Table proto static] (${status_frule}) FAILED" "$Alert"
					status_frule=$StatusERROR
				fi
			else
				[ "$Verbose" != "quiet" ] && log "INFO $me: rule from lookup [ip -${Proto} rule from $i lookup $Table prio $Table] already exist"
			fi
		done

	fi

	ip -${Proto} route flush cache
	[ "$Verbose" != "quiet" ] && show
	sleep 3

	if [ ! -z "$StartExec" ] ; then
		sleep 3
		[ "$Verbose" != "quiet" ] && log "NOTICE $me: timeout $TimeoutExec StartExec [$StartExec]"
		timeout $TimeoutExec sh -c "$StartExec" ; status_exec=$?
		if [ $status_exec -ne 0 ] ; then
			log "ERROR $me: timeout $TimeoutExec StartExec [$StartExec] (${status_exec}) FAILED"
			status_exec=$StatusERROR
		else
			[ "$Verbose" != "quiet" ] && log "INFO $me: StartExec [$StartExec] (${status_exec}) success"
		fi
		[ "$Verbose" != "quiet" ] && show
		sleep 3
	fi

	# status
	r=`expr $status_route + $status_proute + $status_sroute + $status_table + $status_frule + $status_exec`
	if [ $r -eq $StatusUP ] ; then
		[ "$Verbose" = "verbose" ] && log "DEBUG $me: route:${status_route} proute:${status_proute} sroute:${status_sroute} table:${status_table} frule:${status_frule} exec:${status_exec} (${r}) success"
	else
		[ "$Verbose" != "quiet" ] && log "WARNING $me: route:${status_route} proute:${status_proute} sroute:${status_sroute} table:${status_table} frule:${status_frule} exec:${status_exec} (${r}) FAILED"
	fi

	# status
    sed -i "s/^.*; ${me} ;.*$/${logdate} ; $me ; dev:${Iface} proto:${Proto} route:${Dest} return:${r} status:${Status} ; route:${status_route} proute:${status_proute} sroute:${status_sroute} table:${status_table} frule:${status_frule} exec:${status_exec}/g" "$Statusfile" >/dev/null 2>&1

	return $r
}


# usage : stop
stop() {
	local status_route=0
	local status_proute=0
	local status_table=0
	local status_exec=0
	local r
	local match
	local me="STOP${Proto}"
	local logdate=`date "${DateFMT}"`

	# init 
	[ -z "$Status" ] && Status=$StatusUNKW && StatusName="UNKNOWN"

	if [ "$Verbose" != "quiet" ] ; then
		#log "NOTICE $me: proto:$Proto dev:$Iface route:[$Dest $Via $Src] metric:$Metric Table:$Table" "$Alert"
		log "NOTICE $me: proto:$Proto dev:$Iface route:[$Dest $Via $Src] metric:$Metric Table:$Table" 
		show
	fi

	# if exist, remove main route with default metric
	match=`ip -${Proto} route show $Dest $Via dev $Iface $Src metric $Metric 2>/dev/null`
	if [ ! -z "$match" ] ; then
		[ "$Verbose" != "quiet" ] && log "NOTICE $me: stop main route [ip -${Proto} route del $Dest $Via dev $Iface $Src metric $Metric]"
		ip -${Proto} route del $Dest $Via dev $Iface $Src metric $Metric ; status_route=$?
		if [ $status_route -ne 0 ] ; then
			log "ERROR $me: main route [ip -${Proto} route del $Dest $Via dev $Iface $Src metric $Metric] (${r1}) FAILED" "$Alert"
			status_route=$StatusERROR
		fi
		sleep 3
		# just to be sure...
		ip -${Proto} route del $Dest $Via dev $Iface $Src metric $Metric >/dev/null 2>&1
		sleep 3
		ip -${Proto} route flush cache
		[ "$Verbose" != "quiet" ] && show
	else
		[ "$Verbose" != "quiet" ] && log "INFO $me: main route [ip -${Proto} route del $Dest $Via dev $Iface $Src metric $Metric] already removed"
	fi


	# if defined and not exist, restore persistent route with default metric_persist
	# do not sendmail if restoration failed (we are currently trying to stop)
	if [ ! -z "$MetricPersist" ]  ; then
		match=`ip -${Proto} route show $Dest $Via dev $Iface $Src metric $MetricPersist 2>/dev/null`
		if [ -z "$match" ] ; then
			[ "$Verbose" != "quiet" ] && log "NOTICE $me: stop persistent route [ip -${Proto} route replace $Dest $Via dev $Iface $Src metric $MetricPersist]"
			ip -${Proto} route replace $Dest $Via dev $Iface $Src metric $MetricPersist ; status_proute=$?
			if [ $status_proute -ne 0 ] ; then
				#log "ERROR $me: persistent route [ip -${Proto} route replace $Dest $Via dev $Iface $Src metric $MetricPersist] (${r1}) FAILED" "$Alert"
				log "WARNING $me: persistent route [ip -${Proto} route replace $Dest $Via dev $Iface $Src metric $MetricPersist] (${r1}) FAILED"
				status_proute=$StatusERROR
			fi
			sleep 3
			ip -${Proto} route flush cache
			[ "$Verbose" != "quiet" ] && show
		fi
	fi

	# if defined and not exist, restore default route table
	if [ ! -z "$Table" ] ; then
		match=`ip -${Proto} route show $Dest $Via dev $Iface $Src table $Table 2>/dev/null`
		if [ -z "$match" ] ; then
			[ "$Verbose" != "quiet" ] && log "NOTICE $me: stop table route [ip -${Proto} route replace $Dest $Via dev $Iface $Src table $Table]"
			ip -${Proto} route replace $Dest $Via dev $Iface $Src table $Table ; status_table=$?
			if [ $status_table -ne 0 ] ; then
				log "ERROR $me: table route [ip -${Proto} route replace $Dest $Via dev $Iface $Src table $Table] (${status_table}) FAILED" "$Alert"
				status_table=$StatusERROR
			fi
			sleep 3
			ip -${Proto} route flush cache
			[ "$Verbose" != "quiet" ] && show
		fi
	fi

	if [ ! -z "$StopExec" ] ; then
		sleep 3
		[ "$Verbose" != "quiet" ] && log "NOTICE $me: timeout $TimeoutExec StopExec [$StopExec]"
		timeout $TimeoutExec sh -c "$StopExec" ; status_exec=$?
		if [ $status_exec -ne 0 ] ; then
			log "ERROR $me: timeout $TimeoutExec StopExec [$StopExec] (${status_exec}) FAILED"
			status_exec=$StatusERROR
		else
			[ "$Verbose" != "quiet" ] && log "INFO $me: StopExec [$StopExec] (${status_exec}) success"
		fi
		[ "$Verbose" != "quiet" ] && show
		sleep 3
	fi

	# status (do not count status_proute status_table status, even if failed)
	#r=`expr $status_route + $status_proute + $status_exec`
	r=`expr $status_route + $status_exec`
	if [ $r -eq $StatusUP ] ; then
		[ "$Verbose" = "verbose" ] && log "DEBUG $me: route:${status_route} proute(add):${status_proute} table(add):${status_table} exec:${status_exec} (${r}) success"
	else
		[ "$Verbose" != "quiet" ] && log "WARNING $me: route:${status_route} proute(add):${status_proute} table(add):${status_table} exec:${status_exec} (${r}) FAILED"
	fi

	# status
	sed -i "s/^.*; ${me} ;.*$/${logdate} ; $me ; dev:${Iface} proto:${Proto} route:${Dest} return:${r} status:${Status} ; route:${status_route} proute(add):${status_proute} table(add):${status_table} exec:${status_exec}/g" "$Statusfile" >/dev/null 2>&1
	return $r
}


# usage : check
check() {
	local r=0
	local me="CHECK${Proto}"
    local logdate=`date "${DateFMT}"`

	if [ -x "$Check" ] && [ "$Check" != "check_ping" ] ; then
		$Check ; r=$?
	else
		Check="check_ping"
		$Check ; r=$?
	fi
	if [ $r -eq 0 ] ; then
		( [ "$Verbose" = "verbose" ] || [ "$Status" -eq "$StatusDOWN" ] ) && log "NOTICE $me: check [${Check}] (${r}) success"
	else
		[ "$Verbose" != "quiet" ] && log "WARNING $me: check [${Check}] (${r}) FAILED"
	fi

	# status
	sed -i "s/^.*; ${me} ;.*$/${logdate} ; $me ; dev:${Iface} proto:${Proto} route:${Dest} return:${r} ; check:${Check}/g" "$Statusfile" >/dev/null 2>&1

	return $r
}

# usage check_ping
check_ping() {
	local r
	local me="PING${Proto}"
	local i
    local logdate=`date "${DateFMT}"`

	# init 
	[ -z "$Status" ] && Status=$StatusUNKW && StatusName="UNKNOWN"

	# if interface is virtual (vpn), auto add gateway IP to ping series
	# this permit to trigger reload if gateway if accessible and everything else failed
	# in some case, without this, recover is not triggered
	#[ ! -z "$Type" ] && [ "$Type" = "virtual" ] && [ ! -z "$Gw" ] && CheckPing_dest="$CheckPing_dest $Gw"

	if [ -z "$CheckPing_src" ] ; then
		CheckPing_src="$Iface"
		[ "$Verbose" = "verbose" ] && log "DEBUG $me: using interface $Iface as ping source"
	fi

	for i in $CheckPing_dest ; do
		if ping -${Proto} -I $CheckPing_src -c $CheckPing_count -n -W $CheckPing_wait $i >/dev/null 2>&1 ; then
			r=$StatusUP ; break
		else
			r=$StatusDOWN
			[ "$Verbose" != "quiet" ] && log "WARNING $me:  [ping -${Proto} -I $CheckPing_src -c $CheckPing_count -n -W $CheckPing_wait ${i}] (${r}) FAILED"
		fi
	done

	if [ $r -eq $StatusUP ] ; then
		[ "$Verbose" = "verbose" ] && log "DEBUG $me: [ping -${Proto} -I $CheckPing_src -c $CheckPing_count -n -W $CheckPing_wait ${i}] (${r}) success"
	else
		[ "$Verbose" != "quiet" ] && log "WARNING $me: [ping -${Proto} -I $CheckPing_src -c $CheckPing_count -n -W $CheckPing_wait {${CheckPing_dest}}] (${r}) FAILED"
	fi

	# status
	sed -i "s/^.*; ${me} ;.*$/${logdate} ; $me ; dev:${Iface} proto:${Proto} route:${Dest} return:${r} ; ping:${i}/g" "$Statusfile" >/dev/null 2>&1


	return $r
}

# usage : show
show() {
	local s
	local c
	local r
	local me="SHOW${Proto}"
    local logdate=`date "${DateFMT}"`

	# init 
	[ -z "$Status" ] && Status=$StatusUNKW && StatusName="UNKNOWN"

	if [ ! -z "$Table" ] ; then
		#log "NOTICE $me: show route table [ip -${Proto} route show $Dest $Via dev $Iface $Src ; ip -${Proto} route show $Dest $Via dev $Iface $Src table $Table]"
		s=`echo "main:[" ; ip -${Proto} route show $Dest $Via dev $Iface $Src 2>/dev/null ; echo "] ${Table}:[" ; ip -${Proto} route show $Dest $Via dev $Iface $Src table $Table 2>/dev/null ; echo "]" 2>/dev/null`
	else
		#log "NOTICE $me: show route [ip -${Proto} route show $Dest $Via dev $Iface $Src]"
		s=`echo "main:[" ; ip -${Proto} route show $Dest $Via dev $Iface $Src 2>/dev/null ; echo "]" 2>/dev/null`
	fi
	if [ ! -z "$s" ] ; then
		c=`echo "$s" | wc -l 2>/dev/null`
		[ ! -z "$c" ] && c=`expr $c - 3`
		s=`echo "$s" | tr '\012' ' ' 2>/dev/null`
		r=$StatusUP
	else
		s="NOT FOUND [ip -${Proto} route show $Dest $Via dev $Iface $Src]"
		r=$StatusDOWN
	fi
	log "INFO $me: status:${Status} count:${c} tables:{ ${s} } (${r})"

	# status
    sed -i "s/^.*; ${me} ;.*$/${logdate} ; $me ; dev:${Iface} proto:${Proto} route:${Dest} return:${r} status:${Status} ; count:${c}/g" "$Statusfile" >/dev/null 2>&1

	return $r
}

# usage cron
cron() {
	local r
	local ret=0
	local me="CRON${Proto}"
    local logdate=`date "${DateFMT}"`

	# init 
	[ -z "$Status" ] && Status=$StatusUNKW && StatusName="UNKNOWN"

	# cron
	if [ ! -z "$CronExec" ] ; then
		me="CRON${Proto}"
		[ "$Verbose" = "verbose" ] && log "DEBUG $me: CronExec [$CronExec]"
		# no cron exec on on link issue
		if [ $Status -ne $StatusLINK ] ; then
			mod_sleep=`expr $RANDOM % 30 2>/dev/null` ; [ -z "$mod_sleep" ] && mod_sleep=5
			log "NOTICE $me: timeout $TimeoutExec CronExec [$CronExec] (step:${ID}%${StepExec} delay:${mod_sleep}s)"
			sleep $mod_sleep
			timeout $TimeoutExec sh -c "$CronExec" ; r=$?
			if [ $r -ne 0 ] ; then
				ret=$r
				log "ERROR $me: timeout $TimeoutExec CronExec [$CronExec] (${r}) FAILED" "$CronAlert"
			fi
			sed -i "s/^.*; $me ;.*$/${logdate} ; $me ; dev:${Iface} proto:${Proto} route:${Dest} return:${r} status:${Status} ; step:${ID}%${StepExec}/g" "$Statusfile" >/dev/null 2>&1
		else
			log "INFO $me: CronExec [$CronExec] skipped (${Iface} status ${Status})"
		fi
	fi

	# up
	if [ ! -z "$CronUpExec" ] ; then
		me="CRONUP${Proto}"
		[ "$Verbose" = "verbose" ] && log "DEBUG $me: CronUpExec [$CronUpExec]"
		# up exec only on up status
		if [ $Status -eq $StatusUP ] ; then
			mod_sleep=`expr $RANDOM % 15 2>/dev/null` ; [ -z "$mod_sleep" ] && mod_sleep=5
			log "NOTICE $me: timeout $TimeoutExec UpExec [$CronUpExec] (step:${ID}%${StepExec} delay:${mod_sleep}s)"
			sleep $mod_sleep
			timeout $TimeoutExec sh -c "$CronUpExec" ; r=$?
			if [ $r -ne 0 ] ; then
				ret=$r
				log "ERROR $me: timeout $TimeoutExec CronUpExec [$CronUpExec] (${r}) FAILED" "$CronUpAlert"
			fi
			sed -i "s/^.*; $me ;.*$/${logdate} ; $me ; dev:${Iface} proto:${Proto} route:${Dest} return:${r} status:${Status} ; step:${ID}%${StepExec}/g" "$Statusfile" >/dev/null 2>&1
		else
			log "INFO $me: CronUpExec [$CronUpExec] skipped (${Iface} status ${Status})"
		fi
	fi

	# down
	if [ ! -z "$CronDownExec" ] ; then
		me="CRONDOWN${Proto}"
		[ "$Verbose" = "verbose" ] && log "DEBUG $me: CronDownExec [$CronDownExec]"
		# down exec only down or link status
		if [ $Status -eq $StatusDOWN ] || [ $Status -eq $StatusLINK ] ; then
			mod_sleep=`expr $RANDOM % 15 2>/dev/null` ; [ -z "$mod_sleep" ] && mod_sleep=5
			log "NOTICE $me: timeout $TimeoutExec CronDownExec [$CronDownExec] (step:${ID}%${StepExec} delay:${mod_sleep}s)"
			sleep $mod_sleep
			timeout $TimeoutExec sh -c "$CronDownExec" ; r=$?
			if [ $r -ne 0 ] ; then
				ret=$r
				log "ERROR $me: timeout $TimeoutExec CronDownExec [$CronDownExec] (${r}) FAILED" "$CronDownAlert"
			fi
			sed -i "s/^.*; $me ;.*$/${logdate} ; $me ; dev:${Iface} proto:${Proto} route:${Dest} return:${r} status:${Status} ; step:${ID}%${StepExec}/g" "$Statusfile" >/dev/null 2>&1
		else
			[ "$Verbose" = "verbose" ] && log "INFO $me: CronDownExec [$CronDownExec] skipped (${Iface} status ${Status})"
		fi
	fi

	return $ret
}



# usage : auto
auto()
{
	local r
	local req
	local me="AUTO${Proto}"
    local logdate=`date "${DateFMT}"`

	# init 
	[ -z "$Status" ] && Status=$StatusUNKW && StatusName="UNKNOWN"

	#status verbose ; r=$?
	status ; r=$?

	case $r in
		${StatusUP}) req="UP" ;;
		${StatusDOWN}) req="DOWN" ;;
		${StatusLINK}) req="LINK" ;;
		${StatusRELOAD}) req="RELOAD" ; reload ; r=$? ;;
		${StatusSTOP}) req="STOP" ; stop ; r=$? ;;
		${StatusSTART}) req="START" ; start ; r=$? ;;
		${StatusERROR}) req="ERROR" ;;
		${StatusUNKW}) req="UNKNOWN" ;;
	esac

	if [ $r -eq $StatusUP ] ; then
		[ "$Verbose" = "verbose" ] && log "DEBUG $me: request:${req} proto:$Proto dev:$Iface route:[$Dest $Via $Src] metric:$Metric metric_persist:$MetricPersist table:$Table status:${StatusName}[${Status}] (${r})"
	else
		[ "$Verbose" != "quiet" ] && log "WARNING $me: request:${req} proto:$Proto dev:$Iface route:[$Dest $Via $Src] metric:$Metric metric_persist:$MetricPersist table:$Table status:${StatusName}[${Status}] (${r})"
	fi

	# status
    sed -i "s/^.*; ${me} ;.*$/${logdate} ; $me ; dev:${Iface} proto:${Proto} route:${Dest} return:${r} status:${Status} ; request:${req}/g" "$Statusfile" >/dev/null 2>&1

	return $r
}


#########################################################################################################################################
#########################################################################################################################################
#########################################################################################################################################
#main

# base mkdirs
[ ! -d "$Rundir" ] && mkdir -p "$Rundir"
[ ! -d "$Logdir" ] && mkdir -p "$Logdir"
[ ! -d "$Lockdir" ] && mkdir -p "$Lockdir"
[ ! -z "$Promdir" ] && [ ! -d "$Promdir" ] && mkdir -p "$Promdir"

# get parameters
options="a:p:d:s:i:m:M:t:v:c:C:D:V:46hf"
while getopts "$options" argvs ; do
	case "$argvs" in
		a) Action="$OPTARG" ;;
		p) Protocol="$OPTARG" ;;
		d) Dest="$OPTARG" ;;
		s) Src="$OPTARG" ;;
		i) Iface="$OPTARG" ;;
		m) Metric="$OPTARG" ;;
		c) Check="$OPTARG" ;;
		C) Config="$OPTARG" ;;
		M) MetricPersist="$OPTARG" ;;
		t) Table="$OPTARG" ;;
		v) Via="$OPTARG" ;;
		D) Daemon="$OPTARG" ;;
		f) Force=1 ;;
		V) Verbose="$OPTARG" ;;
		4) Protocol="4" ;;
		6) Protocol="6" ;;
		h) echo "$Usage" ; exit 0 ;;
		*) echo "FATAL: $Usage" ; exit 9 ;;
	esac
done

# verbose mode
if [ ! -z "$Verbose" ] ; then
	[ "$Verbose" = "0" ] && Verbose="quiet"
	[ "$Verbose" = "1" ] && Verbose="verbose"
fi

# protocol argv filter (check only this protocol)
[ ! -z "$Protocol" ] && Protocol_argv="$Protocol"

# load config if defined
if [ ! -z "$Config" ] && [ -f "$Config" ] ; then
	log "NOTICE CONFIG: loading config $Config"
	. $Config
	[ $? -ne 0 ] && log "FATAL: while loading config $Config !" && exit 7
else
    # define minimal defaults
    [ -z "$Iface" ] && Iface="wan1"
    [ -z "$Dest" ] && Dest="default"
fi

# define suffix
if [ -z "$Protocol" ] ; then
    if [ -z "$Dest" ] ; then
        Suffix="${Iface}"
    else
        Suffix="${Iface}_${Dest}"
    fi
else
    if [ -z "$Dest" ] ; then
        Suffix="${Iface}_${Protocol}"
    else
        Suffix="${Iface}_${Dest}_${Protocol}"
    fi
fi
[ "$Verbose" = "verbose" ] && log "DEBUG: init suffix is ${Suffix}"

# load config (if it was not defined)
if [ -z "$Config" ] ; then
    Config="${Confdir}/check-route@${Suffix}.conf"
    [ "$Verbose" = "verbose" ] && log "DEBUG: trying to find config ${Config}"
    if [ -f "$Config" ] ; then
    	log "NOTICE CONFIG: loading defined config $Config"
    	. $Config
    	[ $? -ne 0 ] && log "FATAL: while loading defined config $Config !" && exit 7
    fi
fi

# argv protocol or override protocol with proto from legacy config
if [ ! -z "$Protocol_argv" ] ; then
    Protocol="$Protocol_argv"
    [ "$Verbose" = "verbose" ] && log "DEBUG: filter only protocol ${Protocol}"
else
    [ ! -z "$Proto" ] && Protocol="$Proto"
fi
if [ "$Protocol" = "64" ] || [ "$Protocol" = "46" ] || [ "$Protocol" = "6 4" ] || [ "$Protocol" = "4 6" ]; then
    [ "$Verbose" = "verbose" ] && log "DEBUG: checking dual-stack ipv4 and ipv6"
    Protocols="4 6"
else
    Protocols="$Protocol"
fi
[ "$Verbose" = "verbose" ] && log "DEBUG: protocols:[${Protocols}]"

# count protocols
Protocol_count=`echo "$Protocol" | wc -c 2>/dev/null`
[ -z "$Protocol_count" ] && Protocol_count=2

# some defaults
[ -z "$Force" ] && Force=0
[ -e "/sys/class/net/${Iface}/device" ] && Type="physical" || Type="virtual"

# final check
if [ -z "$Action" ] || [ -z "$Iface" ] || [ -z "$Protocol" ] || [ -z "$Dest" ] ; then
	echo  "FATAL: missing params" ; echo "$Usage"
	exit 9
fi

# final suffix
Suffix="${Iface}_${Dest}_${Protocol}"
[ "$Verbose" = "verbose" ] && log "DEBUG: final suffix is ${Suffix}"

# init
ID=0 ; PID="$$"
SkipReload=0
Logprefix="check-route[${PID}:${ID}] [$Action:$Protocol:$Iface:$Dest]"
PIDfile="${Rundir}/check-route_${Suffix}.pid"
Statusfile="${Rundir}/check-route_${Suffix}.status"
NOmailfile="${Rundir}/check-route.nomail"
Lockfile="${Lockdir}/check-route_${Suffix}.lock"
Logfile="${Logdir}/check-route_${Suffix}.log"
[ -z "$TimeoutExec" ] && TimeoutExec=0
[ ! -z "$Promdir" ] && Promfile="${Promdir}/checkroute_${Suffix}.prom" # no - in prometheus filename/metrics
log "NOTICE: logfile:${Logfile} status:${Statusfile} promfile:${Promfile} lockfile:${Lockfile} pidfile:${PIDfile}"
Return=0

# LOCK
[ "$Action" = "unlock" ] && [ -f "$Lockfile" ] && rm "$Lockfile" && log "INFO: unlocked (${Lockfile})"
echo "$PID" > "$PIDfile"

# trap INT
trap "echo 'TRAP: stopping $0 $Logprefix' ; [ -f "$Lockfile" ] && rm "$Lockfile" ; [ -f "$PIDfile" ] && rm "$PIDfile" ; [ -f "$Statusfile" ] && rm "$Statusfile" ;  exit 0" INT
if [ -f "$Lockfile" ] ; then
	log "FATAL: lockfile $Lockfile already exist !"
	exit 99
else
	log "NOTICE: action:${Action} proto:${Protocol} dev:${Iface} route:[${Dest}] metric:${Metric} metric_persist:$MetricPersist table:${Table} max_repeat:${MaxRepeat} type:${Type} check:${Check} Verbose:${Verbose} pid:${PID} pidfile:${PIDfile} daemon:${Daemon} config:${Config}" | tee "$Lockfile"
fi

# NOmailfile exist
if [ -f "$Nomailfile" ] ; then
	rm "$NOmailfile"
	log "NOTICE: $NOmailfile exist, mail notifications are disabled"
	echo "`date "${DateFMT}"`" > "$NOmailfile"
fi

# Boot execution
if [ ! -z "$BootExec" ] ; then
	mod_sleep=`expr $RANDOM % 30 2>/dev/null` ; [ -z "$mod_sleep" ] && mod_sleep=5
	log "NOTICE BOOT: timeout $TimeoutExec BootExec [$BootExec] (delay ${mod_sleep}s)"
	sleep $mod_sleep
	[ "$Verbose" = "verbose" ] && log "DEBUG BOOT: timeout $TimeoutExec BootExec [$BootExec]"
	timeout $TimeoutExec sh -c "$BootExec" ; boot_status=$?
    if [ $boot_status -ne 0 ] ; then
    	log "ERROR BOOT: timeout $TimeoutExec BootExec [$BootExec] (${boot_status}) FAILED"
    fi
	sleep 3
else
    [ "$Verbose" = "verbose" ] && log "DEBUG BOOT: no BootExec defined"
fi

[ ! -z "$Daemon" ] && log "NOTICE DAEMON: daemon mode $Daemon enabled"

# init status
if [ ! -z "$Statusfile" ] ; then
	echo "# `date "${DateFMT}"` action:$Action proto:$Protocol dev:$Iface route:$Dest" > "$Statusfile"
 	for i in CHECK PING AUTO STATUS START STOP RELOAD CRON CRONUP CRONDOWN ; do
    	for p in $Protocols ; do
			echo " ; ${i}${p} ; " >> "$Statusfile"
		done
	done
fi

while true ; do

	# calc modulo for periodical execs
	mod=`expr $ID % $StepExec 2>/dev/null` ; [ -z "$mod" ] && mod=1

    for Proto in $Protocols ; do
		logdate=`date "$DateFMT"`
        Logprefix="check-route[${PID}:${ID}] [$Action:$Protocol:$Iface:$Dest]"
        #Logprefix="check-route[${PID}:${ID}] [$Action:$Proto:$Iface:$Dest]"
    	ret=0 ; Status=$StatusUNKW ; StatusName="UNKNOWN"

        # define proto depend status
        varStatus="statusCurrent${Proto}" ; varStatusName="statusName${Proto}"
        varStatusPrevious="statusPrevious${Proto}" ; varStatusPreviousName="statusPreviousName${Proto}"

        # define proto depend execution
        for var in CheckPing_dest CheckPing_src CheckPing_count CheckPing_wait Check Metric Src Via SubRoute RuleFrom StatusExec StopExec StartExec ReloadExec CronExec CronDownExec CronUpExec CronAlert CronUpAlert CronDownAlert StepExec ; do
            val="$(eval echo \$${var}${Proto})"
            if [ -n "$val" ]; then
                eval "${var}=\"\$val\""
                [ $? -ne 0  ] && log "FATAL: unable to define ${var}:[${val}" && ret=99 && break
				( [ "$Verbose" = "verbose" ] || [ $ID -eq 0 ] ) && log "DEF${Proto}: ${var}:[${val}]"
			else
				val="$(eval echo \$${var})" 
				if [ -n "$val" ] ; then
					eval "${var}=\"\$val\""
					[ $? -ne 0  ] && log "FATAL: unable to define ${var}:[${val}" && ret=99 && break
					( [ "$Verbose" = "verbose" ] || [ $ID -eq 0 ] ) && log "DEF: ${var}:[${val}]"
				fi
            fi
        done
        [ ! -z "$Src" ] && Src="src $Src" && [ "$Verbose" = "verbose" ] && log "DEBUG DEF${Proto}: src:[${Src}]"
        [ ! -z "$Via" ] && Gw="$Via" && Via="via $Via" && [ "$Verbose" = "verbose" ] && log "DEBUG DEF${Proto}: via:[${Via}]"
        [ -z "$StepExec" ] && StepExec="30" && [ "$Verbose" = "verbose" ] && log "DEBUG DEF${Proto}: default StepExec:[${StepExec}]"
       	[ -z "$Check" ] && Check="check_ping" && [ "$Verbose" = "verbose" ] && log "DEBUG DEF${Proto}: default Check:[${Check}]"
		[ -z "$CheckPing_src" ] && CheckPing_src="$Iface" && [ "$Verbose" = "verbose" ] && log "DEBUG DEF${Proto}: default CheckPing_src:[${CheckPing_src}]"

		# metric definitions (1024 is reserved to ipv6 and 0 to ipv4)
        case $Proto in
			6) [ -z "$Metric6" ] && ( [ "$Metric" = "0" ] || [ -z "$Metric" ] ) && Metric=1024 
			   [ "$Verbose" = "verbose" ] && log "DEBUG DEF${Proto}: Metric6 not defined, using default ipv${Proto} Metric:[${Metric}]" ;;
			4) [ -z "$Metric4" ] && ( [ "$Metric" = "1024" ] || [ -z "$Metric" ] ) && Metric=0 
			   [ "$Verbose" = "verbose" ] && log "DEBUG DEF${Proto}: Metric4 not defined, using default ipv${Proto} Metric:[${Metric}]" ;;
        esac

		# prometheus file must be protocol specific
		[ ! -z "$Promdir" ] && Promfile="${Promdir}/checkroute_${Iface}_${Dest}_${Proto}.prom" # no - in prometheus filename/metrics

		# show the first time
		[ $ID -eq 0 ] && show

		# run or skip action
		if [ -z "$SkipAction" ] || [ $SkipAction -eq 0 ] ; then
			case $Action in
				show) show ; ret=$?  ;;
				status) status ; ret=$? ;;
				start) start ; ret=$? ;;
				stop)  stop ; ret=$? ;;
				unlock) log "NOTICE: unlocking (${Lockfile})" ; break ;;
				check) check ; ret=$? ;;
				auto) auto ; ret=$? ;;
				reload) reload ; ret=$? ;; 
				*) echo "FATAL: $Usage" ; ret=99 ; break ;;
			esac
		else
			log "NOTICE: action $Action skipped (skip:${SkipAction})" ; ret=0
		fi

        if [ $ret -ne 0 ] ; then
            Return=$ret
            [ "$Action" != "auto" ] && log "ERROR: action:${Action} dev:${Iface} route:[$Dest $Via $Src] proto:${Proto} return:${ret}"
            # break on bad usage / fatal
            [ $ret -eq 99 ] && break
        fi

		# periodical execs
		if [ $mod -eq 0 ] ; then
			[ "$Verbose" = "verbose" ] && log "DEBUG CRON: executing periodicals step:${ID}%${StepExec}"
			cron ; ret=$?
			if [ $ret -ne 0 ] ; then
				Return=$ret
				log "ERROR: CRON return:${ret} step:${ID}%${StepExec}"
			fi
		fi

        # store current status in protocol-specific variables
        eval "${varStatus}=\"\$Status\"" ;  eval "${varStatusName}=\"\$StatusName\""
        valStatus=$(eval echo \$${varStatus}) ;  valStatusName=$(eval echo \$${varStatusName})

        # get previous status (if exists)
        valStatusPrevious=$(eval echo \$${varStatusPrevious}) ;  valStatusPreviousName=$(eval echo \$${varStatusPreviousName})

      	# init status previous (non-existent on first run)
  		if [ -z "$valStatusPrevious" ] ; then
            StatusPrevious=$Status ; StatusPreviousName=$StatusName
            eval "${varStatusPrevious}=\"\$Status\"" ; eval "${varStatusPreviousName}=\"\$StatusPreviousName\""
            valStatusPrevious=$(eval echo \$${varStatusPrevious}) ; valStatusPreviousName=$(eval echo \$${varStatusPreviousName})
        fi

		# define repeated status values
		CurrentHour=`date +%H` ; [ -z "$Repeat" ] && Repeat=0 ; [ -z "$RepeatHour" ] && RepeatHour="$CurrentHour" 
		[ -z "$RepeatAlert" ] && RepeatAlert=0	; [ -z "$RepeatAction" ] && RepeatAction=0 ; [ -z "$SkipAction" ] && SkipAction=0
		# reset each new hour
		if [ "$CurrentHour" != "$RepeatHour" ] ; then
			Repeat=0 
			RepeatAlert=0
			RepeatAction=0
			SkipAction=0
			RepeatHour="$CurrentHour" 
		fi

        # compare current vs previous
  		if [ $valStatus -eq $valStatusPrevious ] ; then
 			# no status change 
			[ $ID -ge 1 ] && Repeat=`expr $Repeat + 1`
 			if [ $valStatus -eq $StatusUP ] ; then
				log "INFO: status:${valStatusName}[${valStatus}] proto:$Proto dev:$Iface route:[$Dest $Via $Src] gw:$Gw metric:$Metric metric_persist:$MetricPersist table:$Table type:$Type repeat:${Repeat}"
 			else
				log "WARNING: status:${valStatusName}[${valStatus}] proto:$Proto dev:$Iface route:[$Dest $Via $Src] gw:$Gw metric:$Metric metric_persist:$MetricPersist table:$Table type:$Type repeat:${Repeat}/${MaxRepeat}[alert:${RepeatAlert},action:${RepeatAction}]"

				if [ ! -z "$MaxRepeat" ] && [ $Repeat -gt $MaxRepeat ] ; then
					# repeat.alert limit alerting repeat
					[ $RepeatAlert -eq 0 ] && RepeatAlert=1
					if [ $RepeatAlert -lt $Protocol_count ] ; then
						log "WARNING: limiter status:${valStatusName}[${valStatus}] proto:${Proto} dev:${Iface} route:[$Dest $Via $Src] repeated ${Repeat} times (${MaxRepeat}+${RepeatAlert}*) for timestamp ${RepeatHour}H, alerting" "$Alert"
						RepeatAlert=`expr $RepeatAlert + 1`
					else
						log "NOTICE: limiter status:${valStatusName}[${valStatus}] proto:${Proto} dev:${Iface} route:[$Dest $Via $Src] repeated ${Repeat} times for timestamp ${RepeatHour}H, skipping"
					fi
				else
					# repeat.action limit action repeat (currently limit only reload)
					if [ $valStatus -eq $StatusRELOAD ] ; then
						if [ $RepeatAction -le $Protocol_count ] ; then
							log "NOTICE: limiter status:${valStatusName}[${valStatus}] proto:$Proto dev:$Iface route:[$Dest $Via $Src] repeated ${RepeatAction} times (${Protocol_count}*) for timestamp ${RepeatHour}H, action:${valStatusName}"
							RepeatAction=`expr $RepeatAction + 1`
						else
							SkipAction=1
							#log "NOTICE: limiter status:${valStatusName}[${valStatus}] proto:$Proto dev:$Iface route:[$Dest $Via $Src] repeated ${RepeatAction} times for timestamp ${RepeatHour}H, skipping"
						fi
					fi
				fi
 			fi
  		else
			Repeat=1 ; RepeatHour="$CurrentHour" ; RepeatAlert=0 ; RepeatAction=0
 			if [ $valStatus -eq $StatusUP ] ; then
				log "NOTICE: status:${valStatusPreviousName}(${valStatusPrevious})>${valStatusName}(${valStatus}) proto:$Proto dev:$Iface route:[$Dest $Via $Src] gw:$Gw metric:$Metric metric_persist:$MetricPersist table:$Table type:$Type" "$Alert"
 			else
				log "WARNING: status:${valStatusPreviousName}(${valStatusPrevious})>${valStatusName}(${valStatus}) proto:$Proto dev:$Iface route:[$Dest $Via $Src] gw:$Gw metric:$Metric metric_persist:$MetricPersist table:$Table type:$Type" "$Alert"
 			fi
  		fi

        # update previous for next iteration: current becomes previous
        StatusPrevious=$Status ; StatusPreviousName=$StatusName
        eval "${varStatusPrevious}=\"\$Status\"" ;  eval "${varStatusPreviousName}=\"\$StatusName\""

        # verify update
        valStatusPrevious=$(eval echo \$${varStatusPrevious}) ; valStatusPreviousName=$(eval echo \$${varStatusPreviousName})
        [ "$Verbose" = "verbose" ] && log "DEBUG LOOP${Proto}[${ID}]: id:${ID} dev:${Iface} proto:${Proto} route:${Dest} ${varStatus}:${valStatus} ${varStatusName}:${valStatusName} ${varStatusPrevious}:${valStatusPrevious} ${varStatusPreviousName}:${valStatusPreviousName}"
    done

	# no dameon / bad usage
	( [ -z "$Daemon" ] || [ $Daemon -eq 0 ] || [ $ret -eq 99 ] ) && break
	[ "$Verbose" = "verbose" ] && log "DEBUG DAEMON[${ID}]: daemon sleeping $Daemon"
	ID=`expr $ID + 1`
	sleep $Daemon
done

# UNLOCK
[ -f "$Lockfile" ] && rm "$Lockfile"
[ -f "$PIDfile" ] && rm "$PIDfile"
[ -f "$Statusfile" ] && rm "$Statusfile"

# Exit
[ $Return -ne 0 ] && log "WARNING: return:$Return"
exit $Return
