#!/bin/bash

# Run in the root of a sosreport to diagnose an OOM event
# Ping siddle with any questions

#TODO: Protect against files in an sosreport potentially not existing

SRCFILES="sos_commands/kernel/dmesg var/log/messages sos_commands/logs/journalctl_--no-pager_--catalog_--boot_-1"

if [[ $1 == "--help" || $1 == "-h" ]]; then
	echo "Run in the root of a sosreport to diagnose an OOM event. The script will automatically check"
	echo "$SRCFILES"
	echo "for the latest OOM. You can optionally provide a file containing an OOM message with 'oomparser.sh <file>'"
	exit 0
fi

# LATEST OOM
# User can provide a file to look for the OOM with 'oomparser.sh <file>'
#TODO: only cp oom as a debugging feature, use a variable for normal operation
if [[ -f $1 ]]; then
	OOMHEADER=$(grep -s 'invoked oom' $1 | tail -1)
	if [[ -z $OOMHEADER ]]; then
		echo "Couldn't find \"invoked oom\" in $1"
		exit 1
	fi
	cp $1 oom
elif [[ -n $1 ]]; then
	echo "Couldn't find $1"
	exit 1
fi

if [[ -z $OOMHEADER ]]; then
	for file in $SRCFILES; do
		OOMHEADER=$(grep -s 'invoked oom' $file | tail -1)
		if [[ -n $OOMHEADER ]]; then
			cp $file oom
			break
		fi
	done
	if [[ -z $OOMHEADER ]]; then
		echo "Couldn't find \"invoked oom\" in the following files:"
		for file in $SRCFILES; do echo -e "\t$file" ; done
		echo "You can provide a file in which to look for an OOM with 'oomparser.sh <file>'"
		exit 1
	fi
fi

sed -e 's/\[//g' -e 's/\]//g' oom -i
OOMHEADER=$(sed -e 's/\[//g' -e 's/\]//g'  <<< "$OOMHEADER")

LNNUM=$(grep -n "$OOMHEADER" oom | tail -1 | awk -F: '{print $1}')
DATASET=$(tail -n +$LNNUM oom)
DATASET=$(awk '/invoked oom/,/Killed process/' <<< "$DATASET")
echo "$DATASET" > oom

# ENVIRONMENT INFO
KERNELVERSION=$(grep -Eo '[234]\.[0-9]+\.[0-9]+-[0-9]+.*\.el[678].*\.[A-Za-z0-9_]+' -m1 <<< "$DATASET")
X86_64=0

if [[ $(awk -F. '{print $(NF)}' <<< $KERNELVERSION) = "x86_64" ]]; then
	X86_64=1
fi

#X86_64=0

MAJORRELEASE=$(awk -F. '{print $(NF-1)}' <<< $KERNELVERSION)

if [[ $MAJORRELEASE == *"el6"* ]]; then
	RHEL6=1
elif [[ $MAJORRELEASE == *"el7"* ]]; then
	RHEL7=1
elif [[ $MAJORRELEASE == *"el8"* ]]; then
	RHEL8=1
fi

if [[ -f dmidecode ]]; then
	HWINFO=$(grep -s -A2 'System Information' dmidecode)
else
	HWINFO="Unable to determine hardware information; dmidecode file missing"
fi

# MEMINFO
#x86 / meminfo        = use meminfo
#x86 / no meminfo     = use oom + calculation
#not x86 / meminfo    = use meminfo
#not x86 / no meminfo = use oom + no calculation
MEMTOTAL_PAGES=$(grep -Eo '[0-9]+ pages RAM' <<< "$DATASET" | awk '{print $1}')
MEMTOTAL_SOS=$(grep MemTotal proc/meminfo | awk '{print $2}') # KiB

if [[ $X86_64 -eq 1 ]]; then
	MEMTOTAL=$(echo "$MEMTOTAL_PAGES * 4"|bc) # KiB
else
	MEMTOTAL=$MEMTOTAL_SOS
fi

# Display MemTotal in MiB if < 4 GiB
if [[ $MEMTOTAL -lt 4194304 ]]; then
	MEMTOTAL_FMT=$(printf "%.2f\n" $(echo "$MEMTOTAL / 1024"|bc -l) )
	MEMTOTAL_FMT=$(echo $MEMTOTAL_FMT MiB)
else
	MEMTOTAL_FMT=$(printf "%.2f\n" $(echo "$MEMTOTAL / 1024 / 1024"|bc -l) )
	MEMTOTAL_FMT=$(echo $MEMTOTAL_FMT GiB)
fi

# UNRECLAIMABLE SLAB AND SHMEM INFO
MEMINFO=$(awk '/active_anon:.*inactive_anon:.*isolated_anon/,/Node 0/' <<< "$DATASET" | grep -v 'Node 0')
SUNRECLAIM_PAGES=$(grep -Eo 'unreclaimable:[0-9]+' <<< "$MEMINFO" | awk -F: '{print $2}')
SUNRECLAIM_PERCENTAGE=$(printf "%.2f\n" $(echo "$SUNRECLAIM_PAGES/$MEMTOTAL_PAGES*100"|bc -l) )

#SUNRECLAIM_PERCENTAGE=11
if (( $(echo "$SUNRECLAIM_PERCENTAGE > 10.0" | bc -l) )); then
	# Unreclaimable slab objects accounted for more than 10% of the server's total RAM in the OOM
	# message. Find out if that's true in the sosreport "now" as well and if so print a list of
	# the largest slab caches.
	SUNRECLAIM_SOS=$(grep SUnreclaim proc/meminfo | awk '{print $2}') # KiB
	SUNRECLAIM_PERCENTAGE_SOS=$(echo "$SUNRECLAIM_SOS/$MEMTOTAL_SOS*100"|bc -l)

#SUNRECLAIM_PERCENTAGE_SOS=11
	if (( $(echo "$SUNRECLAIM_PERCENTAGE_SOS > 10.0" | bc -l) )); then
		SLABOUT1=1
		if [[ $X86_64 -eq 1 ]]; then
			SLABHEADER="slabname pagesperslab num_slabs pages_used MiB"
			SLAB_SOS=$(tail -n+3 proc/slabinfo \
				| awk '{printf "%s %d %d %d %.2f\n", $1, $6, $15, $6 * $15, $6 * $15 / 256}' \
				| sort -nrk5 | head)
		else
			SLABHEADER="slabname pagesperslab num_slabs pages_used"
			SLAB_SOS=$(tail -n+3 proc/slabinfo \
				| awk '{printf "%s %d %d %d\n", $1, $6, $15, $6 * $15}' \
				| sort -nrk4 | head)
		fi
		SLAB_SOS_FMT=$(echo -e "$SLABHEADER\n$SLAB_SOS" | column -t)
	else # Unreclaimable slab was high in OOM but not sos, let the user know
		SLABOUT2=1
	fi
fi

if [[ $X86_64 -eq 1 ]]; then
	SUNRECLAIM_MIB=$(printf "%.2f\n" $(echo "$SUNRECLAIM_PAGES / 256"|bc -l) )
	SUNRECLAIM_FMT=$(echo $SUNRECLAIM_MIB MiB)
fi

if [[ -n $(grep 'Unreclaimable slab info' <<< "$DATASET") ]]; then
	SLABOUT3=1
	USI=$(awk '/Unreclaimable slab info/,/pid.*uid.*tgid.*total_vm/' <<< "$DATASET")
	USI=$(grep -Ev 'Unreclaimable slab info|pid.*uid.*tgid.*total_vm' <<< $USI)
	USI=$(cat <(head -1 <<< $USI) <(sort -nrk $(awk '{print NF;exit}' <<< $USI) <<< $USI) | column -t | head)
fi

SHMEM_PAGES=$(grep -Eo 'shmem:[0-9]+' <<< "$MEMINFO" | awk -F: '{print $2}')
SHMEM_PERCENTAGE=$(printf "%.2f\n" $(echo "$SHMEM_PAGES/$MEMTOTAL_PAGES*100"|bc -l) )

if [[ $X86_64 -eq 1 ]]; then
	SHMEM_MIB=$(printf "%.2f\n" $(echo "$SHMEM_PAGES / 256"|bc -l) )
	SHMEM_FMT=$(echo $SHMEM_MIB MiB)
fi

# HUGE PAGES INFO

HPF_PCT_SOS=0.00
HP_PCT=0.00

# The RHEL 6 OOM message unfortunately does not include huge page info
if [[ $RHEL6 -ne 1 ]]; then
	HUGE_TOTAL=0
	HUGE_FREE=0
	HPINFO=$(grep hugepages_total <<< "$DATASET")

	# Get huge page total and free sizes in KiB
	for i in $(seq 1 $(wc -l <<< $HPINFO) ); do
		HPLN=$(head -n $i <<< $HPINFO | tail -1)
		HPT=$(grep -Eo 'total=[0-9]+' <<< $HPLN | awk -F= '{print $2}')
		HPF=$(grep -Eo 'free=[0-9]+' <<< $HPLN | awk -F= '{print $2}')
		HPSZ=$(grep -Eo 'size=[0-9]+' <<< $HPLN | awk -F= '{print $2}')
		HUGE_TOTAL=$(echo "$HUGE_TOTAL + $(echo "$HPT * $HPSZ"|bc)" | bc)
		HUGE_FREE=$(echo "$HUGE_FREE + $(echo "$HPF * $HPSZ"|bc)" | bc)
	done

	# Huge page total (from OOM message) as percentage of Memtotal (from sos)
	HP_PCT=$(printf "%.2f\n" $(echo "$HUGE_TOTAL / $MEMTOTAL_SOS * 100"|bc -l) )

	# Display huge page statistics in MiB if < 4 GiB
	if [[ $HUGE_TOTAL -lt 4194304 ]]; then
		HUGE_TOTAL_FMT=$(printf "%.2f\n" $(echo "$HUGE_TOTAL / 1024"|bc -l) )
		HUGE_TOTAL_FMT=$(echo $HUGE_TOTAL_FMT MiB)
		HUGE_FREE_FMT=$(printf "%.2f\n" $(echo "$HUGE_FREE / 1024"|bc -l) )
		HUGE_FREE_FMT=$(echo $HUGE_FREE_FMT MiB)
	else
		HUGE_TOTAL_FMT=$(printf "%.2f\n" $(echo "$HUGE_TOTAL / 1024 / 1024"|bc -l) )
		HUGE_TOTAL_FMT=$(echo $HUGE_TOTAL_FMT GiB)
		HUGE_FREE_FMT=$(printf "%.2f\n" $(echo "$HUGE_FREE / 1024 / 1024"|bc -l) )
		HUGE_FREE_FMT=$(echo $HUGE_FREE_FMT GiB)
	fi

	if [[ $HUGE_TOTAL -gt 0 ]]; then
		HUGE_PCT_FREE=$(printf "%.2f\n" $(echo "$HUGE_FREE / $HUGE_TOTAL * 100"|bc -l) )
	else
		HUGE_PCT_FREE=0.00
	fi

	if (( $(echo "$HUGE_PCT_FREE > 10.0" | bc -l) )); then
		HPOUT1=1
	fi
fi # [[ $RHEL6 -ne 1 ]]

HUGE_STATS_SOS=$(grep ^Huge proc/meminfo)
HPT_SOS=$(grep Total <<< $HUGE_STATS_SOS | awk '{print $2}')
HPF_SOS=$(grep Free <<< $HUGE_STATS_SOS | awk '{print $2}')

if [[ $HPT_SOS -gt 0 ]]; then
	HPF_PCT_SOS=$(printf "%.2f\n" $(echo "$HPF_SOS / $HPT_SOS * 100"|bc -l) )
	if [[ $RHEL6 -eq 1 ]]; then
		HPSZ_SOS=$(grep Hugepagesize <<< $HUGE_STATS_SOS | awk '{print $2}')
		HUGE_TOTAL=$(echo "$HPT_SOS * $HPSZ_SOS"|bc) # KiB
		HP_PCT=$(printf "%.2f\n" $(echo "$HUGE_TOTAL / $MEMTOTAL_SOS * 100"|bc -l) )
	fi
fi

# PROCESS LIST
PROCS=$(awk '/pid.*uid.*tgid.*total_vm/,/Out of mem/' <<< "$DATASET" | grep -v 'Out of mem')
RSSCOLUMN=$(grep -E 'pid.*uid.*tgid.*total_vm' <<< "$DATASET" | tail -1 | awk '{for(i=1;i<=NF;i++){if($i == "rss")printf("%d",i)}}')
TOP10=$(cat <(head -1 <<< "$PROCS") <(sort -nrk $RSSCOLUMN <<< "$PROCS") | head | column -t)
RSSSUM=$(awk -v rssc=$RSSCOLUMN '{sum+=$rssc}END{printf("%d",sum)}' <<< "$PROCS") # pages

if [[ $X86_64 -eq 1 ]]; then
	TOP10=$(awk -v rssc=$RSSCOLUMN '{printf "%s %.2f MiB\n", $0, $rssc/256}' <<< "$TOP10" | column -t)
	RSSSUM_KIB=$(echo "$RSSSUM * 4"|bc)

	if [[ $RSSSUM_KIB -lt 4194304 ]]; then
		RSSSUM_FMT=$(printf "%.2f\n" $(echo "$RSSSUM_KIB / 1024"|bc -l) )
		RSSSUM_FMT=$(echo $RSSSUM_FMT MiB)
	else
		RSSSUM_FMT=$(printf "%.2f\n" $(echo "$RSSSUM_KIB / 1024 / 1024"|bc -l) )
		RSSSUM_FMT=$(echo $RSSSUM_FMT GiB)
	fi

	TOPNAMES=$(awk -v rssc=$RSSCOLUMN '{m[$(NF)]+=$rssc}END{for(item in m){printf "%20s %10.2f MiB\n",item,m[item]/256}}' <<< "$PROCS" \
		| sort -nrk2 | head)
else
	RSSSUM_FMT=$(echo $RSSSUM pages)
	TOPNAMES=$(awk -v rssc=$RSSCOLUMN '{m[$(NF)]+=$rssc}END{for(item in m){printf "%20s %10d pages\n",item,m[item]}}' <<< "$PROCS" \
		| sort -nrk2 | head)
fi 
RSSPCT=$(printf "%.2f\n" $(echo "$RSSSUM / $MEMTOTAL_PAGES * 100"|bc -l) )

if [[ $RSSSUM -gt $MEMTOTAL_PAGES ]]; then
	SHMOUT1=1
fi

PROCSLABHUGE_PCT=$(printf "%.2f\n" $(echo "$RSSPCT+$SUNRECLAIM_PERCENTAGE+$HP_PCT"|bc -l) )

if (( $(echo "$PROCSLABHUGE_PCT < 85.0" | bc -l) )); then
	if (( $(echo "$SHMEM_PERCENTAGE > 85.0" | bc -l) )); then
		SHMOUT2=1
	elif [[ -n $(grep -s balloon lsmod) ]]; then
		BALLOONOUT1=1
	else
		MEMLEAKOUT1=1
	fi
fi

# OUTPUT
NUM=1
# Header
echo "[INVESTIGATION:]"
echo "~~~~~~~~~~~~~~~~"
echo

# Environment info
echo "[I:$NUM] Environment info:" ; NUM=$(echo "$NUM+1"|bc)
echo
echo "$KERNELVERSION" | sed 's/^/    /'
echo
echo "$HWINFO" | sed 's/^/    /'
echo
echo -n "MemTotal: $MEMTOTAL_FMT" | sed 's/^/    /'
if [[ $X86_64 -eq 1 ]]; then
	echo " (derived from pages present; will be slightly higher than actual MemTotal)"
else
	echo " (from meminfo, *NOT* the OOM message)"
fi
echo

# Most recent OOM
echo "[I:$NUM] Most recent OOM:" ; NUM=$(echo "$NUM+1"|bc)
echo
echo $OOMHEADER | sed 's/^/    /'
echo

# Slab and shmem info
echo "[I:$NUM] Unreclaimable slab and shmem info:" ; NUM=$(echo "$NUM+1"|bc)
echo
echo "Mem-Info:" | sed 's/^/    /'
echo "$MEMINFO" | sed 's/^/    /'
echo
if [[ $X86_64 -eq 1 ]]; then
	echo "Unreclaimable slab: $SUNRECLAIM_FMT ($SUNRECLAIM_PERCENTAGE% of MemTotal)"
else
	echo "Unreclaimable slab: $SUNRECLAIM_PAGES pages ($SUNRECLAIM_PERCENTAGE% of MemTotal)"
fi
if [[ $X86_64 -eq 1 ]]; then
	echo "Shmem: $SHMEM_FMT ($SHMEM_PERCENTAGE% of Memtotal)"
	echo
else
	echo "Shmem: $SHMEM_PAGES pages ($SHMEM_PERCENTAGE% of MemTotal)"
	echo
fi
if [[ $SLABOUT1 -eq 1 ]]; then
	echo Unreclaimable slab was more than 10% of total RAM in both the OOM message and when the sosreport was captured.
	echo Here are the top slab caches when the sosreport was captured:
	echo
	echo "$SLAB_SOS_FMT" | sed 's/^/    /'
	echo
fi
if [[ $SLABOUT2 -eq 1 ]]; then
	echo Slab was high in the OOM but not in the sos. Consider tracking slab allocations.
	echo
fi
if [[ $SLABOUT3 -eq 1 ]]; then
	echo Unreclaimable slab info at time of OOM: | sed 's/^/    /'
	echo "$USI" | sed 's/^/    /'
	echo
fi

# Huge page info
echo "[I:$NUM] Huge page info:" ; NUM=$(echo "$NUM+1"|bc)
echo
if [[ $RHEL6 -ne 1 ]]; then
	echo "$HPINFO" | sed 's/^/    /'
	echo
	echo "Huge pages total: $HUGE_TOTAL_FMT ($HP_PCT% of MemTotal)"
	echo "Huge pages free: $HUGE_FREE_FMT ($HUGE_PCT_FREE% of huge pages total)"
	echo
	if [[ $HPOUT1 -eq 1 ]]; then
		echo "Huge pages free was > 10% at the time of the OOM, displaying huge page statistics from meminfo:"
		echo
		echo "$HUGE_STATS_SOS" | sed 's/^/    /'
		echo
		echo "HugePages_Free $HPF_PCT_SOS% of HugePages_Total in meminfo"
		echo
	fi
else
	echo "Since RHEL 6 doesn't include huge page information in the OOM message, displaying huge page data"
	echo "from meminfo (not guaranteed to have been the same at time of OOM):"
	echo
	echo "$HUGE_STATS_SOS" | sed 's/^/    /'
	echo
	echo "HugePages_Free $HPF_PCT_SOS% of HugePages_Total in meminfo"
	echo
fi

# Process info
echo "[I:$NUM] Process info:" ; NUM=$(echo "$NUM+1"|bc)
echo
echo "Top memory-using processes at time of OOM:"
echo
echo "$TOP10" | sed 's/^/    /'
echo
echo "Top memory-using unique command names at time of OOM:"
echo
echo "$TOPNAMES" | sed 's/^/    /'
echo
echo -n Total memory used by processes: $RSSSUM_FMT
echo " ($RSSPCT% of MemTotal)"

# Special cases
if [[ $SHMOUT1 -eq 1 ]]; then
	echo
	echo Total memory used by processes exceeds MemTotal. Applications are likely making use of shared memory.
fi
if [[ $SHMOUT2 -eq 1 ]]; then
	echo
	echo "Shmem using $SHMEM_PERCENTAGE of MemTotal."
fi
if [[ $BALLOONOUT1 -eq 1 ]]; then
	echo
	echo "User space RSS + unreclaimable slab + huge pages is $PROCSLABHUGE_PCT% of MemTotal and a balloon driver is"
	echo "loaded. Ballooning is a likely root cause of the OOM."
fi
if [[ $MEMLEAKOUT1 -eq 1 ]]; then
	echo
	echo "User space RSS + unreclaimable slab + huge pages is $PROCSLABHUGE_PCT% of MemTotal and \"balloon\" was not"
	echo "found in the lsmod file (or lsmod file not found). Consider tracking memory allocations over time."
fi
