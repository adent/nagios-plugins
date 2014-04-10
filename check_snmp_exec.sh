#!/bin/sh

# Nagios "check" for querying output of scripts
# from remote servers via SNMP "exec" mechanism.
# 
# Author Michal Ludvig <michal@logix.cz> (c) 2006
#        http://www.logix.cz/michal/devel/nagios
# 

# Example configuration 
# =====================
# for monitoring SW RAID arrays. Any other service
# that can be checked with a script can be monitored
# with this approach.
# 
# Put the following lines into nagios' configuration:
# 
# ---- cut here ----
# $USER10$=/usr/local/nagios/libexec.local
# 
# define command{
# 	command_name	check_snmp_exec
# 	command_line	$USER10$/check_snmp_exec.sh $HOSTADDRESS$ $ARG1$
# 	}
# 
# define service{
# 	use			generic-service
# 	host_name		server.domain
# 	service_description	RAID status
# 	check_command		check_snmp_exec!raid-md0
# }
# ---- cut here ----
# 
# On the host server.domain configure SNMP extension
# with name "raid-md0". 
# Configuration goes to /etc/snmp/snmpd.conf or similar.
# 
# ---- cut here ----
# exec raid-md0 /usr/local/bin/nagios-linux-swraid.pl --device=md0
# ---- cut here ----
# 
# That's all. Just note that newer versions of 
# Net-SNMP package support "extend" keyword which 
# may be used instead of "exec".
# You will have to use check_snmp_extend.sh script
# with "extend" keyword though.
# 
# Both check_snmp_extend.sh and nagios-linux-swraid.pl
# scripts are available from:
#    http://www.logix.cz/michal/devel/nagios
# 
# Enjoy!
# Michal Ludvig
. /usr/local/nagios/libexec/utils.sh || exit 3

SNMPGET=$(which snmpget)
SNMPWALK=$(which snmpwalk)

SNMPOPTS="-v2c -c public"

test -x ${SNMPGET} || exit $STATE_UNKNOWN
test -x ${SNMPWALK} || exit $STATE_UNKNOWN

HOST=$1
shift
NAME=$1

test "${HOST}" -a "${NAME}" || exit $STATE_UNKNOWN

SELFDIRNAME=$(dirname $0)
test -n "${SELFDIRNAME}" && SELFDIRNAME="${SELFDIRNAME}/"

## Execute snmpwalk to fetch the list of all "exec" commands
## and try to find the one we're interested in.
## Walking through extNames is fast because the commands
## are not actually run - it's just a list of names.
EXT_ID=$(${SNMPWALK} ${SNMPOPTS} ${HOST} UCD-SNMP-MIB::extNames 2>&1 | grep "STRING: ${NAME}$")
if [ -z "${EXT_ID}" ]; then
	echo "UNKNOWN - '${NAME}' was not found in UCD-SNMP-MIB::extNames"
	exit $STATE_UNKNOWN
fi
EXT_ID=${EXT_ID/ = STRING: ${NAME}}
EXT_ID=${EXT_ID/UCD-SNMP-MIB::extNames.}

## Fetch the actual command output (just the first line
## and we expect a Nagios-compatible format)
eval $(${SNMPGET} ${SNMPOPTS} -OvQ ${HOST} UCD-SNMP-MIB::extOutput.${EXT_ID} UCD-SNMP-MIB::extResult.${EXT_ID} 2>&1 | awk 'NR==1{print "EXTOUTPUT=" "\"" $0 "\""} NR==2{print "EXTRESULT=" $0}')

echo $EXTOUTPUT
exit $EXTRESULT
