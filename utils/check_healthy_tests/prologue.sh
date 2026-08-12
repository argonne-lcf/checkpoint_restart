#!/bin/bash

###
# set up tracing
exec 5> /var/tmp/prologue.trace.out
BASH_XTRACEFD="5"
set -x

###
# parse raw arg string into an array
args=$( echo $@ | sed 's/\(PBS_MOM_Hook:\|:Job:\|:User:\|:Resources:\)/\n/g' )
args_array=( $(echo "$args") )

# set top-level variables from array
hook="${args_array[0]}"
jobid="${args_array[1]}"
user="${args_array[2]}"
resources="${args_array[3]}"
# convenience vars
jobid_int=$( echo $jobid | cut -d. -f1 )
# loop/sleep on uid query a few times, logging errors
user_id=$( python3 - << END
import sys, pwd, time, syslog
user = '${user}'
rounds = 3
sleeptime = 3
for i in range(rounds):
    try:
        uid = pwd.getpwnam(f'{user}').pw_uid
        print( uid )
        break
    except Exception as e:
        syslog.syslog(syslog.LOG_ERR, f"getpwnam({user}) failed with <{e.__str__()}>")
    if i < (rounds - 1): time.sleep(sleeptime)
sys.exit(0)
END
)

# parse resource string into an associative array
declare -A resource_arr
while read key val
do
    if [ -z $key ]
    then
        break
    fi
    resource_arr[$key]=$val
done < <(<<<"$resources" awk -F= '{print $1,$2}' RS=';')

###
# check for alcf_daos_cn queue immediately after parsing
# and hand things over to the alternate scripts
if [[ -v resource_arr[queue] ]] && [ "${resource_arr[queue]}" = "alcf_daos_cn" ]
then
    # check script path to prevent recursion
    # check script last-modified time to prevent running an old script
    script_path="$( dirname -- "${BASH_SOURCE[0]}" )"
    newer="$(( $( stat -c '%Y' /pe/testing/alcf_daos_cn/prologue.sh )>$( stat -c '%Y' /pe/pbs/scripts/prologue.sh ) ))"
    if [[ "${script_path}" =~ "/pe/pbs/scripts" ]] && [ "${newer}" = "1" ]
    then
        # disable tracing on parent script
        # tracefile will be overwritten by child script
        set +x
        # run alternate script and immediately exit
        /pe/testing/alcf_daos_cn/prologue.sh $@
        exit $?
    fi
fi

###
# Allowlist of UIDs under 1000, for existing users.
lowUIDs=(258 271 344 363 424 512 547 565 611 619 794 812 822)

###
# remove cleanup lockfile
# will exist if an admin re-onlined a node in cleanup
# node will just be immediately re-offlined if test(s) fail :/
CLEANUP_LOCKFILE="/var/tmp/.cleanup_lock"
if [ -e ${CLEANUP_LOCKFILE} ]
then
    rm -f ${CLEANUP_LOCKFILE}
fi

###
# function for logging test failures
# dispose of previous logue_firstfail file
FIRSTFAIL_PATH=/var/tmp/logue_firstfail
if [ -e ${FIRSTFAIL_PATH} ]
then
    rm -f ${FIRSTFAIL_PATH}
fi
# log test failures by writing to /var/tmp/logue_firstfail and syslog
LOG_FAIL() {
    if [ ! -e ${FIRSTFAIL_PATH} ]
    then
        echo "$@" > ${FIRSTFAIL_PATH}
    fi
    logger -t "execjob_begin" "$@"
}

###
# check script for truncating
MY_PATH="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
MY_FNAME="$( echo "/${BASH_SOURCE[0]}" | grep -Poe "(?<=/)[^/]+$" )"
MY_FULLPATH="${MY_PATH}/${MY_FNAME}"
if [ ! -f "$MY_FULLPATH" ]
then
    LOG_FAIL "error accessing ${MY_FULLPATH} (job $jobid_int)"
    exit 1
else
    if [ $( tail -n 1 ${MY_FULLPATH} | grep -Pce 'exit \${RC}' ) -lt 1 ]
    then
        LOG_FAIL "${MY_FULLPATH} truncated or corrupted on this node (job $jobid_int)"
        exit 1
    fi
fi

###
# return status
RC=0

###
# system name
SYSTEM="${resource_arr[ni_resource]}"
resource_arr[scripts_path]="/pe/pbs/scripts"
resource_arr[utils_path]="/pe/pbs/util"
if [[ "${SYSTEM}" == "sunspot" ]]
then
    resource_arr[scripts_path]="/pe/pbs/scripts"
    resource_arr[utils_path]="/pe/pbs/util"
fi

###
# parse active filesystems and daos list out of args
ACTIVE_FILESYSTEMS=()
DAOS_ACTIVE_FILESYSTEMS=()
for fs in $( echo "${!resource_arr[@]}" | grep -Poe "(?<=server_)\S+(?=_fs)" )
do
    # skip filesystems disabled on the server-side
    if [ "${resource_arr[server_${fs}_fs]}" != '1' ]
    then
        continue
    fi
    # skip adding home_fs(it will be caught below)
    if [[ "${fs}" =~ "home" ]]
    then
        continue
    fi
    # populate lists
    if [[ "${fs}" =~ "daos" ]]
    then
        DAOS_ACTIVE_FILESYSTEMS+=("${fs}")
    else
        ACTIVE_FILESYSTEMS+=("${fs}")
    fi
done
###
# <requested> filesystems(via qsub ... -l filesystems=...)
REQUESTED_FILESYSTEMS=()
DAOS_REQUESTED_FILESYSTEMS=()
for entry in $( echo "${!resource_arr[@]}" )
do
    fs="$( echo ${entry} | grep -Poe "^(|daos_)[a-z]+(?=_fs)" )"
    if [[ "${fs}" =~ "daos" ]] && [[ " ${DAOS_ACTIVE_FILESYSTEMS[@]} " =~ " ${fs} " ]]
    then
        DAOS_REQUESTED_FILESYSTEMS+=("${fs}")
    elif [[ " ${ACTIVE_FILESYSTEMS[@]} " =~ " ${fs} " ]]
    then
        REQUESTED_FILESYSTEMS+=("${fs}")
    fi
done

###
# members of aurora_storage aurora_aig aurora_admins aurora_compute aurora_vendor aurora_intel_daos aurora_vendor_access 
# unfortunately have to hard-code this to prevent ldap hammering
SKIP_ALLOWED_USERS="shenbag1 hsyd ascovel rpadma2 habaraja bustamante bmar11 brianhol kabelj dtm allcock makito bgerofi bsallen anlddunaway toonen janunez jsolson hibeid tanabarr servesh zpettit rpowell byazlovitsky ceballst ak27_dbg grog arsetion chrislew dbohning nawood bpitman jlarson iziemba richp rojas raghul-vasu harms psteinb smc sinchana_karnik nishiya rtwilco charleskim aduenasd woodacre aabraham gazzola tmusta cblackworth lrrountr bbarlage deytr nehagup1 sollivie jbouvet eadames krcanadaintc vanshintel yhuan47 jdigilio blenard eholohan pershey msimmeri wwang2 ayork jiafuzha shilongw leggett trace szeltner pupton rtom_intel alexku rsalazar95 jcarrier droweth mluczkow avilches mrigen sbaum msuliba kaschmitt carns schliep mahadevann skoyama liwei dwvandre rlacerda drpatel acherry tdinnen khambadk doglesbee rmilner scook kccain kishorekadiyala emison frostedcmos joconne cchannui savithag gmcpheet saurabh rtbarell yonilevitt jreddy sucheta_r znault ychang4 xuezhao soumagne mschaara anpatel1 ravalsam samartharora bgeltz ngetty"
# unset ^skip.* flags for any users not in the above list
# this won't affect queue skip_.* flags(which are prepended by "queue_")
if ! [[ " ${SKIP_ALLOWED_USERS} " =~ " ${user} " ]]
then
    for entry in "${!resource_arr[@]}"
    do
        if [[ "${entry}" =~ ^skip ]] && [ ${resource_arr[${entry}]} == 1 ]
        then
            resource_arr[${entry}]=0
        fi
    done
fi

#############
# BEGIN TESTS
if [ ${resource_arr[skip_checks]+SET} -a ${resource_arr[skip_checks]} != '1' ]
then

    ###
    # check for pre-existing running jobs
    # 20250815 - now rejects until the offending JB file is >=10min old via mtime
    #            should prevent woodchippering on nodes where the mom is completely
    #            out to lunch
    if grep force_exclhost /var/spool/pbs/mom_priv/config.d/set_sharing >/dev/null 2>&1
    then
        for JB in $( ls /var/spool/pbs/mom_priv/jobs/*.JB )
        do
            JB_int=$( echo "${JB}" | grep -Poe "(?<=/jobs/)[^\.]+(?=\.)" )
            if [ "${JB_int}" != "${jobid_int}" ]
            then
                JB_state="$( /opt/pbs/bin/printjob ${JB} | grep -Poe "(?<=state = )\S+" | sort -r | paste -sd ':' )"
                if [[ $( date +%s ) -gt $(($( stat -c %Y ${JB} )+600)) ]]
                then
                    LOG_FAIL "job ${JB_int}(state=${JB_state}) currently running on this host or not cleaned up (job ${jobid_int})"
                    RC=$(($RC|1))
                else
                    logger -t "execjob_begin" "job ${JB_int}(state=${JB_state}) currently running on this host; rejecting job (job ${jobid_int})"
                    RC=$(($RC|2))
                fi
            fi
        done
    fi

    ###
    # check /proc/cmdline unless skip flag is set
    # 20250620 - skipping on sunspot for initial post-rebuild rollout
    if [[ "${SYSTEM}" == "aurora" ]]
    then
        if ( [[ -v resource_arr[queue_skip_cmdline_check] ]] && [ ${resource_arr[queue_skip_cmdline_check]} == '1' ] ) || ( [[ -v resource_arr[skip_cmdline_check] ]] && [ ${resource_arr[skip_cmdline_check]} == '1' ] )
        then
            logger -t "execjob_begin" "skipping cmdline check per queue config/user request (job $jobid_int)"
        else
            # 20250227 - omitting the -s(strict) flag for now
            ${resource_arr[scripts_path]}/cmdline_test.sh -j ${jobid}
            if [ $? -ne 0 ]
            then
                LOG_FAIL "kernel cmdline does not match spec (job ${jobid_int})"
                RC=$(($RC|1))
            fi
        fi
    fi

    ###
    # BKC tests
    if [[ -v resource_arr[queue_bkc_definition] ]] && [ ! -z "${resource_arr[queue_bkc_definition]}" ] && [[ "${SYSTEM}" == "aurora" ]]
    then
        bkc_server="tcp://10.114.34.16:54321"
        #[ ${SYSTEM} == "sunspot" ] && bkc_server="tcp://10.11.12.13:54321"
        ${resource_arr[scripts_path]}/bkc_tests.sh -l -h execjob_begin -j ${jobid}  -b ${resource_arr[queue_bkc_definition]} -s ${bkc_server}
        if [ $? -ne 0 ]
        then
            # 20240304 - initial rollout, failures are simply logged to syslog
            #logger -t "execjob_begin" "bkc check failed (job $jobid_int)"
            # 20241030 - activating for all users
            LOG_FAIL "bkc check failed (job $jobid_int)"
            RC=$(($RC|1))
        fi
    fi

    ###
    # quick and dirty DNS test
    /usr/bin/python3 - << DNSCHECK_END
import sys
import socket as s
try:
    ai = s.getaddrinfo('${SYSTEM}-pbs-0001', 80, type=s.SOCK_STREAM, family=s.AF_INET, flags=s.AI_ADDRCONFIG)
    ni = s.getnameinfo(ai[0][-1], 0)
    if not ni[0].endswith('.cm.${SYSTEM}.alcf.anl.gov'):
        sys.exit(1)
except:
    sys.exit(1)
sys.exit(0)
DNSCHECK_END
    DNSCHECK_RC=$?
    if [ ${DNSCHECK_RC} -ne 0 ]
    then
        LOG_FAIL "unable to resolve FQDN of server (job ${jobid_int})"
        RC=$(($RC|1))
    fi

    ###
    # quick test for existence of hsn devices
    for iface in hsn{0..7}
    do
        if [ ! -e /sys/class/net/${iface} ]
        then
            LOG_FAIL "${iface} not found (job $jobid_int)"
            RC=$(($RC|1))
        fi
    done

    ###
    # cxi_stat tests
    for dev in cxi{0..7}
    do
        if [ ! -e /sys/class/cxi/${dev} ]
        then
            LOG_FAIL "failed ${dev} not found (job $jobid_int)"
            RC=$(($RC|1))
            continue
        fi
        if [ "$(cat /sys/class/cxi/${dev}/device/port/link)" != "up" ]
        then
            LOG_FAIL "failed CXI port state, ${dev} link down (job $jobid_int)"
            RC=$(($RC|1))
        fi
        LINK_SPEED="$(cat /sys/class/cxi/${dev}/device/port/speed)"
        if [ "${LINK_SPEED}" != "BS_200G" ]
        then
            LOG_FAIL "failed CXI port speed, ${dev} at ${LINK_SPEED} (job $jobid_int)"
            RC=$(($RC|1))
        fi
        CURRENT_LINK_WIDTH="$(cat /sys/class/cxi/${dev}/device/current_link_width)"
        if [ "${CURRENT_LINK_WIDTH}" != "16" ]
        then
            LOG_FAIL "failed CXI PCIe link width, ${dev} at ${CURRENT_LINK_WIDTH} (job $jobid_int)"
            RC=$(($RC|1))
        fi
        CURRENT_LINK_SPEED="$(cat /sys/class/cxi/${dev}/device/current_link_speed)"
        if [ "${CURRENT_LINK_SPEED}" != "16.0 GT/s PCIe" ]
        then
            LOG_FAIL "failed CXI PCIe link speed, ${dev} at ${CURRENT_LINK_SPEED} (job $jobid_int)"
            RC=$(($RC|1))
        fi
        # (un)correctable errors
        CXI_ERR_COR="$(cat "/sys/class/cxi/${dev}/device/properties/pcie_corr_err")"
        CXI_ERR_UNCORR="$(cat "/sys/class/cxi/${dev}/device/properties/pcie_uncorr_err")"
        if [ "${CXI_ERR_UNCORR}" -gt 0 ] || [ "${CXI_ERR_COR}" -gt 10 ]
        then
            cxi_pci_bdf="$(basename "$(realpath "/sys/class/cxi/${dev}/device")")"
            LOG_FAIL "${dev} ${cxi_pci_bdf} PCIe error (uncorr:${CXI_ERR_UNCORR},corr:${CXI_ERR_COR}) (job $jobid_int)"
            RC=$(($RC|1))
        fi
    done

    ###
    # check for device address mismatches <-> LLDP
    # 20250620 - disabled on sunspot for initial post-rebuild rollout
    if [[ "${SYSTEM}" == "aurora" ]]
    then
        for iface in hsn{0..7}
        do
            if [ "$( cat /sys/class/net/${iface}/address | cut -d: -f 4-6 )" != "$( /usr/sbin/lldptool -t -V portID -i ${iface} -n | tail -n 1 | cut -d: -f 5-7 )" ]
            then
                LOG_FAIL "address mismatch with LLDP on device ${iface} (job $jobid_int)"
                RC=$(($RC|1))
            fi
        done
    fi

    ###
    # cxi link flap test
    NOW=$( echo "$(date +%s)" )
    ONEHOURAGO=$( echo "$NOW-3600" | bc )
    TENHOURSAGO=$( echo "$NOW-36000" | bc )
    for cxi_dev in cxi{0..7}
    do
        # count the event within 1/10 hours
        ONEHOURCOUNTER=0
        TENHOURCOUNTER=0
        for ts in /sys/class/cxi/${cxi_dev}/device/link_restarts/time_{0..9}
        do
            if [ $( cat $ts ) -gt $TENHOURSAGO ]
            then
                TENHOURCOUNTER=$((TENHOURCOUNTER+1))
                if [ $( cat $ts ) -gt $ONEHOURAGO ]
                then
                    ONEHOURCOUNTER=$((ONEHOURCOUNTER+1))
                fi
            fi
        done
        # match against thresholds(4 in past hr, 9 in past 10 hrs per cxi_healthcheck script)
        if [ $ONEHOURCOUNTER -gt 4 -o $TENHOURCOUNTER -gt 9 ]
        then
            LOG_FAIL "${cxi_dev} link restarts exceeded thresholds(1hr:${ONEHOURCOUNTER}, 10hr:${TENHOURCOUNTER})(job $jobid_int)"
            RC=$(($RC|1))
        fi
    done

    ###
    # check pcie switches
    for port in /sys/bus/pci/drivers/pcieport/000{0,1}*
    do
        # Search for PCI bridge: Broadcom / LSI PEX890xx PCIe Gen 5 Switch - 1000:c030
        if [ $(cat "${port}/vendor") == "0x1000" ] && [ $(cat "${port}/device") == "0xc030" ]; then
                CURRENT_LINK_SPEED=$(cat ${port}/current_link_speed)
                CURRENT_LINK_WIDTH=$(cat ${port}/current_link_width)
        fi
        # all should be <16GT/s x 16> or <32 GT/s x 8>
        MISMATCH=0
        if [[ ${CURRENT_LINK_SPEED} =~ "16.0 GT/s" ]] && [ ! ${CURRENT_LINK_WIDTH} == "16" ]
        then
            MISMATCH=1
        elif [[ ${CURRENT_LINK_SPEED} =~ "32.0 GT/s" ]] && [ ! ${CURRENT_LINK_WIDTH} == "8" ]
        then
            MISMATCH=1
        fi
        if [ ${MISMATCH} -eq 1 ]
        then
            LOG_FAIL "PCIe switch ${port} width/speed mismatch (job $jobid_int)"
            RC=$(($RC|1))
        fi
    done

    ###
    # Check PVC PCIe bridge
    for port in /sys/bus/pci/drivers/pcieport/000{0,1}:{15,3f,69}:01.0
    do
        # Search for PVC PCIe bridge: Intel Corporation Device 352a (rev 04)- 8086:352a
        if [ $(cat "${port}/vendor") == "0x8086" ] && [ $(cat "${port}/device") == "0x352a" ]; then
            CURRENT_LINK_SPEED=$(cat ${port}/current_link_speed)
            CURRENT_LINK_WIDTH=$(cat ${port}/current_link_width)
        fi
        # all should be <32 GT/s x 16>
        MISMATCH=0
        if [[ ${CURRENT_LINK_SPEED} =~ "32.0 GT/s" ]] && [ ! ${CURRENT_LINK_WIDTH} == "16" ]
        then
            MISMATCH=1
        fi
        if [ ${MISMATCH} -eq 1 ]
        then
            LOG_FAIL "PVC PCIe switch ${port} width/speed mismatch (job $jobid_int)"
            RC=$(($RC|1))
        fi
    done

    ###
    # cxi retry handler service check
    for dev in cxi{0..7}
    do
        systemctl status cxi_rh@${dev}.service >/dev/null 2>&1
        rc=$?
        if [ ${rc} -ne 0 ]
        then
            LOG_FAIL "${dev} retry handler service not running (job $jobid_int)"
            RC=$(($RC|1))
        fi
    done

    ###
    # Lustre checks
    # skip if user/admin sets resource
    if ( [[ -v resource_arr[queue_skip_lustre_checks] ]] && [ ${resource_arr[queue_skip_lustre_checks]} == '1' ] ) || ( [[ -v resource_arr[skip_lustre_checks] ]] && [ ${resource_arr[skip_lustre_checks]} == '1' ] )
    then
        # skip on flag==true
        logger -t "execjob_begin" "skipping lustre checks (job $jobid_int)"
    else
        ###
        # check LNET NIs
        if [ $( tail -n +2 /sys/kernel/debug/lnet/nis | grep -vc up ) -gt 0 ]
        then
            LOG_FAIL "one or more lnet NIs are not in up state(job $jobid_int)"
            RC=$(($RC|1))
        fi

        ###
        # check lustre mounts
        # always check /home and /soft
        for fs in home soft
        do
            if [ $( grep -c "/${fs}" /proc/mounts ) -lt 1 ]
            then
                LOG_FAIL "failed mount check: ${fs} not mounted(job $jobid_int)"
                RC=$(($RC|1))
            fi
        done
        # 20250522 - ensure flare is always checked for non-admin users(regardless of filesystems=...)
        if [ "${SYSTEM}" == "aurora" ] && [[ " ${ACTIVE_FILESYSTEMS[@]} " =~ " flare " ]] && [[ ! " ${REQUESTED_FILESYSTEMS[@]} " =~ " flare " ]]
        then
            if [[ ! " ${SKIP_ALLOWED_USERS} " =~ " ${user} " ]]
            then
                REQUESTED_FILESYSTEMS+=("flare")
            fi
        fi
        ###
        # ALWAYS add lustre filesystems mounting /home/ or /soft/ to list
        while read -ra entry
        do
            if [[ " /home /soft " =~ "${entry[1]}" ]]
            then
                entry_fs=$( echo "${entry[0]}" | grep -Poe "(?<=^/)[^/]+(?=/)" )
                if [ -n "${entry_fs}" ]
                then
                    [[ ! " ${ACTIVE_FILESYSTEMS[@]} " =~ " ${entry_fs} " ]] && ACTIVE_FILESYSTEMS+=("${entry_fs}")
                    [[ ! " ${REQUESTED_FILESYSTEMS[@]} " =~ " ${entry_fs} " ]] && REQUESTED_FILESYSTEMS+=("${entry_fs}")
                fi
            fi
        done <<< "$( grep lustre /etc/fstab | grep -Poe "(?<=:)([a-zA-Z0-9/]+ ){2}" )"
        ###
        # only check filesystems that aren't currently downed(via server resource)
        for fs in ${REQUESTED_FILESYSTEMS[@]}
        do
            if [ $( grep -Pce "(:| /lus)/${fs}" /proc/mounts ) -lt 1 ]
            then
                LOG_FAIL "failed mount check: ${fs} not mounted(job $jobid_int)"
                RC=$(($RC|1))
            fi
        done
        ###
        # check for *missing* MDT/OST connections
        for fs in ${REQUESTED_FILESYSTEMS[@]}
        do
            # skip any non-lustre fs resources
            if [ $( grep -Pce "(:| /lus)/${fs}" /proc/mounts ) -lt 1 ] && [ "${fs}" != "flare" ]
            then
                continue
            fi
            # adjust for flare
            [ "${fs}" == "flare" ] && fs="grand"
            # check /proc/fs/lustre/... state files
            for path_t in mdc osc
            do
                n=$( ls -al /proc/fs/lustre/${path_t}/${fs}-*/state | wc -l )
                down=$( grep -Po -e "(?<=current_state\: ).+" /proc/fs/lustre/${path_t}/${fs}-*/state | grep -vc FULL )
                # down node ONLY if all mdt's/ost's are down
                if [ $((down/n)) -gt 0 ]
                then
                    LOG_FAIL "failed lustre MDT/OST check, no connections to $fs in FULL state (job $jobid_int)"
                    RC=$(($RC|1))
                fi
            done
        done
        ###
        # check for MDT/OST disconnects
        # offline thresholds: >=1% of total MDT/OST's on a filesystem have 3 or more disconnects in the past 10 minutes
        TEN_MIN_AGO=$(( $( /usr/bin/date +%s )-600 ))
        for fs in ${REQUESTED_FILESYSTEMS[@]}
        do
            # skip any non-lustre fs resources
            if [ $( grep -Pce "(:| /lus)/${fs}" /proc/mounts ) -lt 1 ] && [ "${fs}" != "flare" ]
            then
                continue
            fi
            # adjust for flare
            [ "${fs}" == "flare" ] && fs="grand"
            for path_t in mdc osc
            do
                # 20240628 - previous thresholds .125 and .0625
                THRESH=".01"
                [ path_t == "osc" ] && THRESH=".01"
                MDTOST_COUNT=0
                MDTOST_TOTAL=0
                for statefile in /proc/fs/lustre/${path_t}/${fs}-*/state
                do
                    COUNT=0
                    MDTOST_TOTAL=$(($MDTOST_TOTAL+1))
                    for ts in $( grep -Po -e "[0-9]+(?=\,\ DISCONN)" ${statefile} )
                    do
                        if [ ${ts} -ge ${TEN_MIN_AGO} ]
                        then
                            COUNT=$(($COUNT+1))
                        fi
                    done
                    if [ ${COUNT} -ge 3 ]
                    then
                        MDTOST_COUNT=$(($MDTOST_COUNT+1))
                    fi
                done
                if [ $( echo "(${MDTOST_COUNT}/${MDTOST_TOTAL})>=${THRESH}" | bc -l ) -eq 1 ]
                then
                    touch ${CLEANUP_LOCKFILE}
                    LOG_FAIL "RECHECK ${MDTOST_COUNT}/${MDTOST_TOTAL} ${fs} ${path_t} disconnect threshold exceeded(3/10min) (job $jobid_int)"
                    RC=$(($RC|1))
                fi
            done
        done
        ###
        # MOM ONLY
        # read check on /soft/
        if [ ${resource_arr[is_mom]} == '1' ]
        then
            stat /soft/ >/dev/null 2>&1 &
            cat_pid=$!
            for i in {1..300}
            do
                if [ ! -f /proc/${cat_pid}/stat ]
                then
                    break
                fi
                if [ $i -eq 300 ]
                then
                    # reached 5 minute timeout; reject job
                    logger -t "execjob_begin" "5m timeout on stat of /soft (job $jobid_int)"
                    exit 2
                fi
                sleep 1
            done
        fi
    fi
    # end lustre checks

    ###
    # check for missing/"offlined" cores
    if [ $( lscpu -b --parse | grep -vc "#" ) -lt 208 ] || [ $( lscpu -c --parse | grep -vc "#" ) -gt 0 ]
    then
        LOG_FAIL "some cores are offline/missing ($( lscpu -b --parse | grep -vc '#' ) available/208 total) (job $jobid_int)"
        RC=$(($RC|1))
    fi

    ###
    # dimm/hbm dmidecode parseathon
    dimm=()
    dimm_count=0
    hbm_count=0
    idx=0
    for string in $( /usr/sbin/dmidecode -q -t 17 | grep -Pe "(?<=^\s{1})(Size:|Locator:|Speed:)" | grep -Poe "(?<=: ).*$" | sed 's/ //g' )
    do
        # quick indexing check to ensure dmidecode output isn't scrambled
        # probably best to log and abort here
        if [ ${idx} -eq 0 ] && [[ ! "${string}" =~ ^[0-9]+GB ]]
        then
            break
        fi
        # appending dmidecode line to array
        dimm+=("${string}")
        # array complete, check it
        if [ $(( $( echo "${dimm[@]}" | wc -w ) )) -eq 3 ]
        then
            if [[ "${dimm[1]}" =~ "DIMM" ]]
            then
                dimm_count=$(( $dimm_count+1 ))
                if [ "${dimm[0]}" != "64GB" ] || [ "${dimm[2]}" != "4800MT/s" ]
                then
                    LOG_FAIL "bad dimm at ${dimm[1]} (job $jobid_int)"
                    RC=$(($RC|1))
                fi
            elif [[ "${dimm[1]}" =~ "HBMI" ]]
            then
                hbm_count=$(( $hbm_count+1 ))
                if [ "${dimm[0]}" != "16GB" ] || [ "${dimm[2]}" != "3200MT/s" ]
                then
                    LOG_FAIL "bad sbr hbm at ${dimm[1]} (job $jobid_int)"
                    RC=$(($RC|1))
                fi
            fi
            dimm=()
        fi
        idx=$(( (idx+1)%3 ))
    done
    # offline on total counts < expected
    if [ ${dimm_count} -lt 16 ]
    then
        LOG_FAIL "only ${dimm_count}/16 dimms online (job $jobid_int)"
        RC=$(($RC|1))
    elif [ ${hbm_count} -lt 8 ]
    then
        LOG_FAIL "only ${hbm_count}/8 spr hbms online (job $jobid_int)"
        RC=$(($RC|1))
    fi

    ###
    # check memory correctables/uncorrectables
    for counter in ue ce
    do
        thresh=0
        [ "${counter}" = "ce" ] && thresh=$( echo "1./86400" | bc -l )
        for path in /sys/devices/system/edac/mc/mc*/dimm*
        do
            val=$( echo "$( cat ${path}/dimm_${counter}_count | paste -sd '+' )" | bc )
            rate=$( echo "${val}/$( cat ${path}/../seconds_since_reset )" | bc -l )
            if [[ $( echo "${rate}>${thresh}" | bc -l ) -eq 1 ]]
            then
                printf -v report_rate "%0.2f" $( echo "${rate}*86400" | bc -l )
                LOG_FAIL "memory ${counter} threshold exceeded(${val}, ${report_rate}/24hr) on $( cat ${path}/dimm_label ) (job $jobid_int)"
                RC=$(($RC|1))
            fi
        done
    done
    # reset counters
    if [ ${RC} -eq 0 ]
    then
        for path in /sys/devices/system/edac/mc/mc*
        do
            echo >${path}/reset_counters
        done
    fi
    ###
    # check total memory
    MEMTOTAL=$( grep -Po -e "(?<=^MemTotal:)[\s0-9]+" /proc/meminfo )
    if [ $( echo "${MEMTOTAL} > (2^30)*0.95" | bc ) -eq 0 ]
    then
        LOG_FAIL "failed total memory check, only ${MEMTOTAL}kB found (job $jobid_int)"
    fi

    ###
    # check memory labels(a proxy for a number of dimm-related errors)
    DIMM_LABELS=()
    for label in CPU{0,1}_DIMM_{A..H}1
    do
        DIMM_LABELS+=( "${label}" )
    done
    DIMM_INDEX=0
    for mc in mc{0..3} mc{20..23}
    do
        for ch in ch{0,1}
        do
            if ! [ -w /sys/devices/system/edac/mc/${mc}/csrow0/${ch}_dimm_label ]
            then
                LOG_FAIL "${DIMM_LABELS[$DIMM_INDEX]} not found (job $jobid_int)"
                RC=$(($RC|1))
            fi
            ((DIMM_INDEX+=1))
        done
    done

    ###
    # check error counters
    # 20231030 - disabling these for reasons; just log and move on
    # 20240104 - re-enablng
    # 20240816 - correctable counters added, moved into dedicated subscript
    i915check_out=$( ${resource_arr[scripts_path]}/i915_counter_test.sh -j ${jobid} )
    i915check_rc=$?
    if [ ${i915check_rc} -ne 0 ]
    then
        i915check_firstfail=$( echo "${i915check_out}" | head -n 1 )
        if [ -z "${i915check_firstfail}" ]
        then
            i915check_firstfail="i915_counter_test returned nonzero status (job $jobid_int)"
        fi
        LOG_FAIL "${i915check_firstfail}"
        RC=$(($RC|1))
    fi

    ###
    # simple port health check
    for f in /sys/kernel/debug/iaf/*/sd.*/port.*/port_show
    do
        port="$( echo "${f}" | awk -F'/' '{ printf "%s,%s,%s", $6, $7, $8 }' )"
        health="$( cat ${f} 2>/dev/null | grep "Port Health" | grep -Poe "(?<=:\s).+$" )"
        [ $? -ne 0 ] && health="UNAVAIL"
        if [[ " UNAVAIL DEGRADED FAILED " =~ "${health}" ]]
        then
            LOG_FAIL "port ${port} failed health check with state ${health} (job $jobid_int)"
            RC=$(($RC|1))
        fi
    done

    ###
    # check device memory
    if [ ${resource_arr[skip_gpu_mem_check]+SET} -a ${resource_arr[skip_gpu_mem_check]} != '1' ]
    then
        for dev in card{0..5}
        do
            val=$( cat /sys/class/drm/${dev}/device_memory_health )
            if [[ ! " OK EC_PENDING " =~ " ${val} " ]]
            then
                # 20231030 - disabling these for reasons; just log and move on
                # 20240131 - re-enabling
                #logger -t "execjob_begin" "${dev}/device_memory_health returned ${val} (job $jobid_int)"
                LOG_FAIL "${dev}/device_memory_health returned ${val} (job $jobid_int)"
                RC=$(($RC|1))
            fi
        done
    fi

    ###
    # check pcie counters
    for port in /sys/bus/pci/drivers/pcieport/{0,1}*
    do
        [ ! -e "${port}/vendor" ] || [ ! -e "${port}/device" ] && continue
        PORT=$( basename ${port} )
        VENDOR=$(cat "${port}/vendor")
        DEVICE=$(cat "${port}/device")
        NAME="${DEVICE}"
        case "${VENDOR}"
        in
            "0x8086")
                case "${DEVICE}"
                in
                    "0x352a") NAME="PVC Root Port" ;;
                    "0x0bdf") NAME="PVC Downstream Port" ;;
                    "0x0bdd") NAME="PVC Upstream Port" ;;
                esac
                ;;
            "0x17db")
                case "${DEVICE}"
                in
                    "0x0501") NAME="CXI NIC" ;;
                esac
                ;;
            "0x1000")
                case "${DEVICE}"
                in
                    "0xc030") NAME="PCIe switch" ;;
                esac
                ;;
        esac
        TOTAL_ERR_COR=$(grep TOTAL_ERR_COR ${port}/aer_dev_correctable| cut -f 2 -d " ")
        TOTAL_ERR_FATAL=$(grep TOTAL_ERR_FATAL ${port}/aer_dev_fatal| cut -f 2 -d " ")
        TOTAL_ERR_NONFATAL=$(grep TOTAL_ERR_NONFATAL ${port}/aer_dev_nonfatal| cut -f 2 -d " ")
        if [ ${TOTAL_ERR_FATAL} -gt 0 -o ${TOTAL_ERR_NONFATAL} -gt 0 -o ${TOTAL_ERR_COR} -gt 10 ]
        then
            LOG_FAIL "${PORT} ${NAME} (fatal:${TOTAL_ERR_FATAL},nonfatal:${TOTAL_ERR_NONFATAL},correctable:${TOTAL_ERR_COR}) (job $jobid_int)"
            RC=$(($RC|1))
        fi
    done

    ###
    # check HPCM image loaded against one defined at the queue level
    if [ ${resource_arr[queue_hpcm_image]+SET} -a -n ${resource_arr[queue_hpcm_image]} ]
    then
        LOADED_IMAGE=$( grep -Po -e "(?<=IMAGE\=)\S+" /proc/cmdline )
        if [ ! ${LOADED_IMAGE} = ${resource_arr[queue_hpcm_image]} ]
        then
            LOG_FAIL "image ${LOADED_IMAGE} loaded; does not match queue-defined image(job $jobid_int)"
            RC=$(($RC|1))
        fi
    fi

    ###
    # check hbm/snc mode against queue defaults
    HBM_MODE="cache"
    SNC_MODE="quad"
    case $( od -A n -i -j 36 -N 2 --endian=little /sys/firmware/acpi/tables/SLIT | grep -Poe "[0-9]+" )
    in
        2)
            HBM_MODE="cache"
            SNC_MODE="quad"
            ;;
        4)
            HBM_MODE="flat"
            SNC_MODE="quad"
            ;;
        8)
            HBM_MODE="cache"
            SNC_MODE="snc4"
            ;;
        16)
            HBM_MODE="flat"
            SNC_MODE="snc4"
            ;;
        *)
            HBM_MODE="unknown"
            SNC_MODE="unknown"
            ;;
    esac
    if [ ${resource_arr[queue_hbm_mode]+SET} -a -n ${resource_arr[queue_hbm_mode]} ]
    then
        if [ ${HBM_MODE} != ${resource_arr[queue_hbm_mode]} ]
        then
            LOG_FAIL "hbm mode ${HBM_MODE} does not match queue default ${resource_arr[queue_hbm_mode]} (job $jobid_int)"
            RC=$(($RC|1))
        fi
    fi
    if [ ${resource_arr[queue_snc_mode]+SET} -a -n ${resource_arr[queue_snc_mode]} ]
    then
        if [ ${SNC_MODE} != ${resource_arr[queue_snc_mode]} ]
        then
            LOG_FAIL "snc mode ${SNC_MODE} does not match queue default ${resource_arr[queue_snc_mode]} (job $jobid_int)"
            RC=$(($RC|1))
        fi
    fi
    ###
    # check available numa nodes matches expectations
    NUMA_NODES="$( /usr/bin/numactl -H | grep -Poe "(?<=available: )[0-9]+(?= nodes)" )"
    if [ -z "${NUMA_NODES}" ]
    then
        LOG_FAIL "unable to query available numa nodes (job $jobid_int)"
        RC=$(($RC|1))
    fi
    # calculate expected numa nodes based on hbm/snc modes and cmdline numa=fake=...
    EXPECTED_NUMA_NODES=2
    [ "${HBM_MODE}" = "flat" ] && EXPECTED_NUMA_NODES=$((EXPECTED_NUMA_NODES*2))
    [ "${SNC_MODE}" = "snc4" ] && EXPECTED_NUMA_NODES=$((EXPECTED_NUMA_NODES*4))
    FAKE_NODES="$( grep -Poe "(?<=numa\=fake\=)[0-9]+(?=U)" /proc/cmdline )"
    if [ -n "${FAKE_NODES}" ]
    then
        if [ "${HBM_MODE}" = "flat" ]
        then
            LOG_FAIL "numa=fake=... set on flat hbm boot (job $jobid_int)"
            RC=$(($RC|1))
        else
            EXPECTED_NUMA_NODES=$((EXPECTED_NUMA_NODES*FAKE_NODES))
        fi
    fi
    # check available against expected and fail if !=
    if [ ${NUMA_NODES} -ne ${EXPECTED_NUMA_NODES} ]
    then
        LOG_FAIL "${EXPECTED_NUMA_NODES} numa nodes expected, but ${NUMA_NODES} available (job $jobid_int)"
        RC=$(($RC|1))
    fi

    ###
    # check for processes from a previous job
    if [ -f /var/tmp/pbsjob_remaining_procs ]
    then
        PREV_USER=$( cat /var/tmp/pbsjob_remaining_procs )
        if [ $( pgrep -l -u ${PREV_USER} | wc -l ) -gt 0 ]
        then
            MODULES=$(
            for pid in $( pgrep -l -u ${PREV_USER} | awk '{print $1}' )
            do
                cat /proc/${pid}/stack 2>&1
            done | grep -Po -e "(?<=\[)\S+(?=\]$)" | /usr/bin/sort | /usr/bin/uniq | grep -Pe "(lustre|fuse|nfs|i915|drm|cxi_)" | paste -sd ','
            )
            if [ -n ${MODULES} ]
            then
                LOG_FAIL "previous job processes remain(modules: ${MODULES}) (current job $jobid_int)"
            else
                LOG_FAIL "cleanup of previous job failed (current job $jobid_int)"
            fi
            RC=$(($RC|1))
        else
            /usr/bin/rm -f /var/tmp/pbsjob_remaining_procs
        fi
    fi
    # and daos mounts
    if [ $( mount -l -t fuse.daos | wc -l ) -gt 0 ]
    then
        # attempt to unmount
        timeout 15 umount -t fuse.daos -a
        umount_rc=$?
        if [ ${umount_rc} -ne 0 ]
        then
            LOG_FAIL "unmount dfuse mount from previous job failed with ${umount_rc} (job ${jobid_int})"
            RC=$(($RC|1))
        else
            logger -t "execjob_begin" "dfuse mount from previous job successfully unmounted (job ${jobid_int})"
        fi
    fi

    ###
    # TEST TESTING AREA FOR TESTING TESTS
    TESTFLAG=0
    if [ ${TESTFLAG} -eq 1 ]
    then
        LOG_FAIL "THIS IS A FAKE TEST and it FAILED(job $jobid_int)"
        RC=$(($RC|1))
    fi

    ###
    # REBOOT-SCRIPT TESTS
    # here, for a limited time only!

    ###
    # set prelim_lmem_alloc_limit and prelim_sharedmem_alloc_limit for each device
    for dev_path in card{0..5}
    do
        for endpoint in prelim_lmem_alloc_limit prelim_sharedmem_alloc_limit
        do
            # set value and check rc
            echo 0 > /sys/class/drm/${dev_path}/${endpoint}
            if [ $? -ne 0 ]
            then
                LOG_FAIL "setting ${endpoint} failed on ${dev_path} (job $jobid_int)"
                RC=$(($RC|1))
                break
            fi
        done
    done

    ###
    # set accelerator max frequency
    FREQ=1600
    for CARD in card{0..5}
    do
        DEVPATH=/sys/class/drm/${CARD}
        # check driver_guc_communication counters before proceding
        # guc comms errors can cause a script hang on frequency reset
        if [ $( cat ${DEVPATH}/gt/gt{0,1}/error_counter/driver_guc_communication | paste -sd '+' | bc ) -gt 0 ]
        then
            # skip freq reset and offline node
            LOG_FAIL "guc comms failures found on ${CARD} (job $jobid_int)"
            RC=$(($RC|1))
            # no point in attempting resets on other cards here
            break
        else
            # do this a few times, since min/max/boost needs to all align to same freq
            for j in {1..5}
            do
                echo $FREQ > ${DEVPATH}/gt_min_freq_mhz
                echo $FREQ > ${DEVPATH}/gt_boost_freq_mhz
                echo $FREQ > ${DEVPATH}/gt_max_freq_mhz
                for GT in ${DEVPATH}/gt/gt*
                do
                    echo $FREQ > "${GT}/rps_min_freq_mhz"
                    echo $FREQ > "${GT}/rps_max_freq_mhz"
                    echo $FREQ > "${GT}/rps_boost_freq_mhz"
                done
                sleep 0.1
            done
            echo 0 > ${DEVPATH}/prelim_enable_eu_debug
        fi
    done
    sleep 0.5

    ###
    # Reset PVC power limits to 500w
    for hwmon in /sys/class/drm/card*/device/hwmon/hwmon*/power1_max
    do
        timeout 15 sh -c "echo 500000000 > ${hwmon}"
        hwmon_rc=$?
        power1_max="$(cat "${hwmon}")"
        if [ ${hwmon_rc} -ne 0 ] || [ "${power1_max}" -ne 500000000 ]
        then
            pci_bdf="$(basename "$(realpath "$(dirname "${hwmon}")/../..")")"
            LOG_FAIL "PVC $pci_bdf failed to reset power limit (job ${jobid_int})"
            RC=$((RC|1))
        fi
    done

    ###
    # cxi codeword test
    ${resource_arr[scripts_path]}/cxi_cw_telemetry.sh -j ${jobid_int} -v
    if [ $? -ne 0 ]
    then
        LOG_FAIL "cxi codeword test failed (job $jobid_int)"
        RC=$(($RC|1))
    fi
    ###
    # cxi loopback test
    # 20240125 - disabling for now
    # 20240205 - reenabling in prologue only
    ${resource_arr[scripts_path]}/cxi_loopback_test.sh -h ${HBM_MODE} -s ${SNC_MODE} -j ${jobid_int} -v
    if [ $? -ne 0 ]
    then
        LOG_FAIL "cxi loopback test failed (job $jobid_int)"
        RC=$(($RC|1))
    fi

    ###
    # gemm test
    # 20250613 - not in default image still; check file path
    GEMM_BIN=/opt/aurora/default/support/tools/node-test/gemm.exe
    if [ -f ${GEMM_BIN} ]
    then
        gemm_out="$( timeout -k 30 25 ${GEMM_BIN} random 10 2>&1 )"
        gemm_rc=$?
        if [ "$( tail -n1 <<<${gemm_out} )" != "pass" ]
        then
            logger --size=4KiB -t "execjob_begin gemm.exe" "$( gzip -9 <<<${gemm_out} | base64 -w0 )"
            LOG_FAIL "gemm.exe test failed (job $jobid_int)"
            RC=$(($RC|1))
        fi
    fi

    ###
    # ze_peak and ze_peer tests
    # NOTE: 20230816 probably-temporary checking of 'skip_benchmarks' resource to allow skipping ze_peer/peak
    #       20230922 added offline condition to catch admin shenanigans re: anr/iaf modifications
    #                added skip condition on full-EU mode
    anr_state=$( cat /sys/class/drm/card{0..5}/iaf_power_enable | paste -sd '+' | bc )
    eu_state=$( echo "($( cat /sys/kernel/debug/dri/*/gt*/sseu_status | grep -Po -e "(?<=Available EU Total: )[0-9]+" | paste -sd "+" ))/12" | bc )
    iaf_state=$( cat /sys/kernel/debug/iaf/*iaf.*/sd.*/port.*/port_show | grep 'Port Health' | grep -c HEALTHY )
    # validation paths in order of preference
    VALIDATION_PATH_ARR=( "/opt/aurora/default/support/tools/gpu_validation" "/opt/aurora/23.275.2/support/tools/gpu_validation" "/opt/aurora/23.266.0/support/tools/gpu_validation" "/opt/aurora/23.073.0/support/tools/gpu_validation" "/opt/aurora/23.073.0/support/tools/gpu_validation" )
    # default validation path
    VALIDATION_TOOL_PATH=""
    # device precheck flag
    DEVICE_PRECHECK_OK=1
    for vpath in ${VALIDATION_PATH_ARR[@]}
    do
        if [ -d ${vpath} ]
        then
            VALIDATION_TOOL_PATH=${vpath}
            break
        fi
    done
    if [ -z ${VALIDATION_TOOL_PATH} ]
    then
        LOG_FAIL "no validation tool path is mounted (job $jobid_int)"
        RC=$(($RC|1))
    elif [ ${anr_state} -eq 6 -a ${iaf_state} -ne 60 ]
    then
        LOG_FAIL "iaf port health check failed (job $jobid_int)"
        RC=$(($RC|1))
    elif [ ${eu_state} -ne 448 ]
    then
        LOG_FAIL "sseu_status check shows mixed-EU state (job $jobid_int)"
        RC=$(($RC|1))
    #elif [ ${resource_arr[skip_benchmarks]+SET} -a ${resource_arr[skip_benchmarks]} == '1' ] || [ ${eu_state} -eq 512 ]
    elif [ ${resource_arr[skip_benchmarks]+SET} -a ${resource_arr[skip_benchmarks]} == '1' ] || [ ${resource_arr[queue_full_eu]+SET} -a ${resource_arr[queue_full_eu]} == '1' ]
    then
        logger -t "execjob_begin" "skipping ze_peer/peak (job $jobid_int)"
    elif [ ${RC} -eq 0 ]
    then
        ###
        # ze_info device check
        zeinfo_out=$( ZE_FLAT_DEVICE_HIERARCHY=COMPOSITE LD_LIBRARY_PATH=/usr/local/intel-gpu-umd/lib64 ${VALIDATION_TOOL_PATH}/ze_info )
        zeinfo_rc=$?
        if [ ${zeinfo_rc} -eq 0 ]
        then
            device_count=$( echo "${zeinfo_out}" | grep -Poe "(?<=^Number of devices)[\s]+[0-9]$" | xargs )
            if [ ${device_count} -lt 6 ]
            then
                DEVICE_PRECHECK_OK=0
                LOG_FAIL "ze_info device count found only ${device_count} of 6; skipping benchmarks... (job $jobid_int)"
                RC=$(($RC|1))
            fi
        else
            DEVICE_PRECHECK_OK=0
            LOG_FAIL "ze_info device check failed with nonzero status (job $jobid_int)"
            RC=$(($RC|1))
        fi
        ###
        # run benchmarks
        if [ ${DEVICE_PRECHECK_OK} -eq 1 ]
        then
            ###
            # ze_peak
            zepeak_outfile=/var/tmp/zepeak.out
            echo >${zepeak_outfile}
            zepeak_pass=1
            zepeak_pagefault=0
            zepeak_hang=0
            zepeak_rc=0
            for round in {1..2}
            do
                timeout -s SIGKILL 15s stdbuf -oL numactl -C 1-51,53-103 --membind=2,3 ${VALIDATION_TOOL_PATH}/ze_peak -m --exp_dev_count 6 --check_fast >>${zepeak_outfile} 2>&1
                zepeak_rc=$?
                if [ ${zepeak_rc} -ne 0 -a $( cat ${zepeak_outfile} | grep -c "FATAL: Unexpected page fault from GPU" ) -gt 0 ]
                then
                    # retry on first-round pagefault
                    if [ ${round} -eq 1 ]
                    then
                        logger -t "execjob_begin" "ze_peak pagefault; making a second attempt... (job $jobid_int)"
                        sleep 3
                        continue
                    fi
                    # fail 'n bail on a second-round pagefault
                    logger -t "execjob_begin" "ze_peak pagefault; failing test... (job $jobid_int)"
                    zepeak_pass=0
                    zepeak_pagefault=1
                    break
                else
                    if [ ${zepeak_rc} -ne 0 -o ${anr_state} -eq 6 -a ${eu_state} -eq 448 -a $( cat ${zepeak_outfile} | grep -c "\!--Pass--\!" ) -ne 1 ]
                    then
                        zepeak_pid=$( ps h -e -ocomm=,pid= | grep ze_peak | grep -Po -e "[0-9]+(?=$)" )
                        if [ -n "${zepeak_pid}" ] && ps h ${zepeak_pid} >/dev/null 2>&1
                        then
                            sleep 30
                            if ps h ${zepeak_pid} >/dev/null 2>&1
                            then
                                echo "### ^^^ ROUND #${round} HUNG ^^^ ###" >>${zepeak_outfile}
                                zepeak_hang=1
                                zepeak_pass=0
                                break
                            fi
                        else
                            echo "### ^^^ ROUND #${round} FAILED ^^^ ###" >>${zepeak_outfile}
                            zepeak_pass=0
                            continue
                        fi
                    fi
                fi
                zepeak_pass=1
                break
            done
            if [ ${zepeak_pass} -ne 1 ]
            then
                if [ ${zepeak_pagefault} -eq 1 ]
                then
                    LOG_FAIL "zepeak test failed due to pagefault rc:${zepeak_rc} (job $jobid_int)"
                else
                    LOG_FAIL "zepeak test failed rc:${zepeak_rc} (job $jobid_int)"
                fi
                RC=$(($RC|1))
                # log output
                logger --size=4KiB -t "execjob_begin ze_peak" "$( cat ${zepeak_outfile} | gzip -9 | base64 -w0 )"
            fi
            ###
            # ze_peer
            # NOTE: SKIP ON ANR != 1(1+1+1+1+1+1=6)
            if [ ${anr_state} -eq 6 ]
            then
                for round in {1..2}
                do
                    zepeer_pass=1
                    # 20230825 - arguments changed
                    #zepeer_out=$( ${VALIDATION_TOOL_PATH}/ze_peer --ipc -b -s 0,1,2,3,4,5 -d 0,1,2,3,4,5 --parallel_multiple_targets -u 0,1,2,3,4,5,6,7,8,9,10,11 -z 33554432 -t transfer_bw -i 10 2>&1 )
                    zepeer_out=$( /usr/bin/numactl -C 1-51,53-103 --membind=2,3 ${VALIDATION_TOOL_PATH}/ze_peer -b --parallel_multiple_targets -s 0,1,2,3,4,5 -d 0,1,2,3,4,5 -u 2,3,4,5,6,8 -z 33554432 -t transfer_bw -i 10 2>&1 )
                    zepeer_rc=$?
                    if [ ${zepeer_rc} -ne 0 ]
                    then
                        if [ $( echo ${zepeer_out} | grep -c "FATAL: Unexpected page fault from GPU" ) -gt 0 ]
                        then
                            # continue on a pagefault
                            if [ ${round} -eq 1 ]
                            then
                                logger -t "execjob_begin" "ze_peer pagefault; making a second attempt... (job $jobid_int)"
                                sleep 3
                                continue
                            fi
                            LOG_FAIL "zepeer test failed due to pagefault rc:${zepeer_rc} (job $jobid_int)"
                        else
                            LOG_FAIL "zepeer test returned non-zero status rc:${zepeer_rc} (job $jobid_int)"
                            # log output
                            logger --size=4KiB -t "execjob_begin ze_peer" "$( echo "${zepeer_out}" | gzip -9 | base64 -w0 )"
                        fi
                        RC=$(($RC|1))
                        break
                    else
                        for rw in $( echo "${zepeer_out}" | /usr/bin/grep -Po -e '(?<=BW \[GBPS\]\:  960 MB\:).+' )
                        do
                            # 20230825 - bw threshold changed from 32 -> 30
                            #if [ $( echo "${rw}<32" | bc ) -eq 1 ]
                            if [ $( echo "${rw}<30" | bc ) -eq 1 ]
                            then
                                LOG_FAIL "zepeer test failed bandwidth perf check (job $jobid_int)"
                                RC=$(($RC|1))
                                # log output
                                logger --size=4KiB -t "execjob_begin ze_peer" "$( echo "${zepeer_out}" | gzip -9 | base64 -w0 )"
                            fi
                        done
                        break
                    fi
                    if [ ${round} -eq 1]
                    then
                        logger -t "execjob_begin" "ze_peer failed on first attempt; trying again... (job $jobid_int)"
                    else
                        logger -t "execjob_begin" "ze_peer failed on second attempt... (job $jobid_int)"
                    fi
                done
            fi
        fi
    fi
    # END REBOOT-SCRIPT TESTS
    ###

else
    ###
    # skip_checks passed...
    logger -t "execjob_begin" "skipping ALL checks (job $jobid_int)"
fi

###
# check sssd/ldap(note: can't skip this)
if [[ ! $user_id =~ ^[0-9]+$ ]]
then
    LOG_FAIL "unable to query user uid(user $user, job $jobid_int)"
    RC=$(($RC|1))
fi

###
# clear the gpu microcontroller error log
ALL_ERRORS=""
for dev_path in /sys/class/drm/card*
do
    error_state="$( cat ${dev_path}/error )"
    # continue on no error
    if [ "${error_state}" == "No error state collected" ]
    then
        continue
    fi
    # bundle error state
    ALL_ERRORS=$( printf "%s\n%s\n" "${ALL_ERRORS}" "${error_state}" )
    # and zero it out
    echo > ${dev_path}/error
done
# log collated errors to syslog
if [ -n "${ALL_ERRORS}" ]
then
    logger --size=384KiB -t "execjob_begin gpu_microcontroller_errorlog" "$( echo ${ALL_ERRORS} | gzip -9 | base64 -w0 )"
fi

# END TESTS
###########

############
# NODE SETUP
# pre-setup; fetch the job's vni from vnid
if [ ${RC} -eq 0 ]
then
    ###
    # fetch vni, reject job on failure
    # 20250620 - disabled for sunspot during initial post-rebuild rollout
    if [ ${resource_arr[is_mom]} == '1' ]
    then
        if [ "${SYSTEM}" == "aurora" ]
        then
            ${resource_arr[scripts_path]}/vni_ctrl.sh -u ${user_id} -j ${jobid}
        else
            ${resource_arr[scripts_path]}/vni_ctrl.sh -u ${user_id} -j ${jobid} -s
        fi
        if [ $? -ne 0 ]
        then
            LOG_FAIL "unable to aquire VNI; rejecting job... (job ${jobid_int})"
            RC=$(($RC|2))
        fi
    fi
fi
# set up job session
if [ ${RC} -eq 0 ]
then

    ###
    # cgroup setup
    ${resource_arr[scripts_path]}/cgroup_ctrl.sh -j ${jobid}
    if [[ " hzheng " =~ "${user}" ]]
    then
        echo 34359738368 >/sys/fs/cgroup/memory/jobs/${jobid_int}/memory.soft_limit_in_bytes
        echo 34359738368 >/sys/fs/cgroup/memory/jobs/${jobid_int}/memory.limit_in_bytes
    fi

    ###
    # Add a subuid and subgid for the user,
    # Check if UID is > 1000 and < 65534, with exceptions in lowUIDs.
    if ( [ $user_id -gt 1000 ] || printf '%s\0' "${lowUIDs[@]}" | grep -q -F -x -z -- $user_id ) && [ $user_id -lt 65534 ]
    then
        # Give a user 65536 UIDs and GIDs based on their UID
        SUBUID_COUNT=65536
        START_RANGE=$((user_id * SUBUID_COUNT))
        END_RANGE=$((START_RANGE + SUBUID_COUNT - 1))
        /usr/sbin/usermod --add-subuids "${START_RANGE}-${END_RANGE}" "${user}"
        /usr/sbin/usermod --add-subgids "${START_RANGE}-${END_RANGE}" "${user}"
    fi

    ###
    # check for enable_2nd_fp64 flag, disable otherwise
    bitmask="0x20002000"
    if [[ -v resource_arr[enable_2nd_fp64] ]] && [ "${resource_arr[enable_2nd_fp64]}" = "1" ]
    then
        bitmask="0xFFFF0000"
    fi
    # enable/disable second pipeline
    for dev in 000{0,1}:{18,42,6c}:00.0
    do
        for offset in 0x{E4F0,100E4F0}
        do
            ${resource_arr[utils_path]}/pcimem "/sys/bus/pci/devices/${dev}/resource0" "${offset}" w ${bitmask} >/dev/null 2>&1
            pcimem_rc=$?
            if [ ${pcimem_rc} -ne 0 ]
            then
                LOG_FAIL "pcimem write failed at ${dev}:${offset} (job $jobid_int)"
                RC=$(($RC|1))
            fi
        done
    done

    ###
    # parse daos arg and start the service
    DAOS_AGENT="offline"
    if [[ -v DAOS_REQUESTED_FILESYSTEMS[@] ]] && [[ " ${DAOS_ACTIVE_FILESYSTEMS[@]} " =~ " ${DAOS_REQUESTED_FILESYSTEMS[0]} " ]]
    then
        case "${DAOS_REQUESTED_FILESYSTEMS[0]}"
        in
            daos_user)
                DAOS_AGENT="daos_agent@oneScratch"
                ;;
            daos_perf)
                DAOS_AGENT="daos_agent@perf"
                ;;
            daos_ops)
                DAOS_AGENT="daos_agent@ops"
                ;;
            *)
                DAOS_AGENT="daos_agent@oneScratch"
                ;;
        esac
    elif [[ -v resource_arr[daos] ]]
    then
        case ${resource_arr[daos]}
        in
            default)
                [[ " ${DAOS_ACTIVE_FILESYSTEMS[@]} " =~ " daos_user " ]] && DAOS_AGENT="daos_agent@oneScratch"
                ;;
            perf)
                [[ " ${DAOS_ACTIVE_FILESYSTEMS[@]} " =~ " daos_perf " ]] && DAOS_AGENT="daos_agent@perf"
                ;;
            ops)
                [[ " ${DAOS_ACTIVE_FILESYSTEMS[@]} " =~ " daos_ops " ]] && DAOS_AGENT="daos_agent@ops"
                ;;
            intel)
                if [[ " mschaara janunez maureen dbohning makito rpadma2 saurabh soumagne samartharora ascovel bsallen gmcpheet harms " =~ " ${user} " ]]
                then
                    DAOS_AGENT="user@${user_id}"
                fi
                ;;
            *)
                [[ " ${DAOS_ACTIVE_FILESYSTEMS[@]} " =~ " daos_user " ]] && DAOS_AGENT="daos_agent@oneScratch"
                ;;
        esac
    fi
    if [ ${DAOS_AGENT} != "offline" ]
    then
        systemctl start ${DAOS_AGENT}.service
        agent_start_rc=$?
        systemctl status ${DAOS_AGENT}.service
        agent_status_rc=$?
        if [ ${agent_start_rc} -ne 0 ] || [ ${agent_status_rc} -ne 0 ]
        then
            LOG_FAIL "daos agent ${DAOS_AGENT} failed to start (job $jobid_int)"
            RC=$(($RC|1))
        fi
    fi

    ###
    # clear out any extraneous entries in access.conf and add our user
    for entry in $( /usr/bin/grep -Po -e "(?<=\+ : )\S+(?= : ALL)" /etc/security/access.conf | /usr/bin/sort | /usr/bin/uniq )
    do
        if /usr/bin/getent passwd ${entry} >/dev/null 2>&1
        then
            /usr/bin/sed -i "/+ : ${entry} : ALL/d" /etc/security/access.conf
        fi
    done
    ###
    # ensure the template line is present
    if ! grep -Pe "^###\+ : JOBUSER : ALL" /etc/security/access.conf >/dev/null 2>&1
    then
        /usr/bin/sed -i "/^\- : ALL : ALL/i###\+ : JOBUSER : ALL" /etc/security/access.conf
    fi
    ###
    # add the user
    /usr/bin/sed -i "/^###+ : JOBUSER : ALL/a + : ${user} : ALL" /etc/security/access.conf

    ###
    # done
    logger -t "execjob_begin" "node setup complete"
fi

###
# cleanup and done
exit ${RC}
