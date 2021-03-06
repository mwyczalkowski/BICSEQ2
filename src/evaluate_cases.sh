#!/bin/bash

# Matthew Wyczalkowski <m.wyczalkowski@wustl.edu>
# Yige Wu <yigewu@wustl.edu>
# https://dinglab.wustl.edu/

# Usage: 
# bash evaluate_status.sh -S CASE_LIST -p PROJECT_CONFIG -L LOGD_BASE_PROJECT [options]

# Evaluate status of analysis workflow for each case in CaseList by examining log files. Write output STDOUT
# Possible states for each case: "not_started", "running", "complete", "error", "warning"

# Required options:
# -S CASE_LIST: path to CASE LIST data file
# -p PROJECT_CONFIG: project configuration file.  Will be mapped to /project_config.sh in container
# -L LOGD_BASE_PROJECT: Log base dir relative to host.  Logs of parallel / bsub will be LOGD_PROJECT_BASE/CASE

# Options:
# -f status: output only lines matching status, e.g., -f import:complete
# -u: include only CASE in output
# -1 : stop after one case processed.
# -v : verbose output
# -W : suppress multiple log file warnings 

# based on /gscuser/mwyczalk/projects/CPTAC3/import/LUAD.hb2.3/importGDC/evaluate_status.sh
# Note that MGI and non-MGI logs look the same
SCRIPT=$(basename $0)

# http://wiki.bash-hackers.org/howto/getopts_tutorial
while getopts ":S:p:L:f:uM1vW" opt; do
  case $opt in
    S)  
      CASE_LIST="$OPTARG"
      ;;
    p)  
      PROJECT_CONFIG="$OPTARG"
      ;;
    L)  
      LOGD_BASE_PROJECT=$OPTARG
      ;;
    f) 
      FILTER=$OPTARG
      ;;
    u)  
      CASE_ONLY=1
      ;;
    1)  
      JUSTONE=1
      ;;
    v)  
      VERBOSE=1
      ;;
    W)  
      NO_WARN=1
      ;;
    \?)
      >&2 echo "$SCRIPT: ERROR: Invalid option: -$OPTARG"
      exit 1
      ;;
    :)
      >&2 echo "$SCRIPT: ERROR: Option -$OPTARG requires an argument."
      exit 1
      ;;
  esac
done
shift $((OPTIND-1))

if [ "$#" -ne 0 ]; then
    >&2 echo $SCRIPT: ERROR. Wrong number of arguments
    >&2 echo Usage: evaluate_status.sh \[options\] 
    exit 1
fi

if [ -z $CASE_LIST ]; then
    >&2 echo $SCRIPT: ERROR. CaseList \(-S\) not defined 
    exit 1
fi

if [ ! -e $CASE_LIST ]; then
    >&2 echo $SCRIPT: ERROR. CaseList does not exist: $CASE_LIST
    exit 1
fi

if [ -z $PROJECT_CONFIG ]; then
    >&2 echo $SCRIPT: ERROR. Project config \(-p\) not defined 
    exit 1
fi

if [ ! -e $PROJECT_CONFIG ]; then
    >&2 echo $SCRIPT: ERROR. Project config does not exist: $PROJECT_CONFIG
    exit 1
fi

if [ -z $LOGD_BASE_PROJECT ]; then
    >&2 echo ERROR: Log Base Directory \(-L\) not specified
    exit 1
fi

if [ ! -d $LOGD_BASE_PROJECT ]; then
    >&2 echo ERROR: Log Base Directory does not exist: $LOG_BASE_PROJECT
    exit 1
fi

# Return the name of bsub STDERR log file 
# Note that log file has format <TIMESTAMP>.err, so we return the most recent of these.  If more than one log file exists,
# write a warning.  If no file exists, return ""
function get_log {
    CASE=$1
    LOGD="$LOGD_BASE_PROJECT/$CASE/log"

    # Count number of matching log files.  
    LOGS=$(ls -1t $LOGD/*.err 2>/dev/null)
    NLOG=$(echo "$LOGS" | wc -l)
    if [ $NLOG == "1" ]; then
        echo $LOGS
    elif [ $NLOG == "0" ]; then
        echo ""
    else
        if [ -z $NO_WARN ]; then
            >&2 echo WARNING: More than one log file exists in $LOGD.  Processing the most recent one
        fi
        echo $(echo "$LOGS" | head -n 1)
    fi
}
        
# Evaluate processing status of BICSEQ2 pipeline by examining logs generated by execute_workflow.sh
# Returns one of "not_started", "running", "complete", "error", "warning"
# Usage: test_import_success CASE LOG_FN
# where LOG_FN is the full filename of STDERR log written by execute_workflow.sh
function test_import_success {
    LOG_FN=$1

    # Logic of testing
    # If log file does not exist: status = not_started
    # if log file contains "ERROR": status = error
    # if log file contains "warning": status = warning
    #   Note that in this case run still completed
    # if log file contains "SUCCESS": status = complete
    # otherwise status = running
    ERROR_STRING="BS2:ERROR"
    SUCCESS_STRING="BS2:SUCCESS"

    if [ "$LOG_FN" == "" ] || [ ! -e $LOG_FN ] ; then
        echo not_started
        return
    fi

    # Ad hoc warning conditions:
    # Normalization step sometimes has the following warning:
    #
    #   Warning: Possible divergence detected in fast.REML.fit
    # and
    #   Warning message:
    #   In bgam.fit(G, mf, chunk.size, gp, scale, gamma, method = method,  :
    #     algorithm did not converge
    # We find that the results are significantly different when this occurs; rerunning may fix this. To catch this situation, we issue a warning

    if fgrep -Fq "$ERROR_STRING" $LOG_FN; then
        echo error
        return
    fi

    # Ad hoc error conditions:
    # Also check for error conditions which do not trigger our error status, such as out of disk errors
    # Assume that if see the string "error" (case insensitive), we have an error condition
    if fgrep -Fiq "error" $LOG_FN; then
        echo error
        return
    fi

    if fgrep -Fiq "disk quota exceeded" $LOG_FN; then
        echo error
        return
    fi
    
    # Warnings may occur even if success or running
    # Be able to distinguish these
    if fgrep -Fiq "warning" $LOG_FN; then
        WARNING_SUFFIX="+warning"
    fi

    if fgrep -Fq "$SUCCESS_STRING" $LOG_FN; then
        echo "complete${WARNING_SUFFIX}"
        return
    fi

    echo "running${WARNING_SUFFIX}"
}

function get_job_status {
    CASE=$1

    LOG_FN=$(get_log $CASE) 

    if [ $VERBOSE ]; then
        >&2 echo Case: $CASE Log file: $LOG_FN
    fi

    TEST1=$(test_import_success $LOG_FN)  

    STEP="execute_workflow.sh"
    # for multi-step processing would report back a test for each step
    printf "$CASE\t$STEP:$TEST1\n"
}

while read L; do
    # Skip comments 
    [[ $L = \#* ]] && continue

    # CaseList
    #   CASE    - unique name of this tumor/normal sample
    #   SAMPLE_NAME_A - sample name of sample A
    #   PATH_A - path to data file. Remapped to container path if dockermap is defined
    #   UUID_A - UUID of sample A
    #   SAMPLE_NAME_B - sample name of sample B
    #   PATH_B - path to data file. Remapped to container path if dockermap is defined
    #   UUID_B - UUID of sample B

    CASE=$(echo "$L" | cut -f 1) # unique ID of file

    STATUS=$(get_job_status $CASE )

    # which columns to output?
    if [ ! -z $CASE_ONLY ]; then
        COLS="1"
    else 
        COLS="1,2" 
    fi

    if [ ! -z $FILTER ]; then
        echo "$STATUS" | grep $FILTER | cut -f $COLS
    else 
        echo "$STATUS" | cut -f $COLS
    fi

    if [ $JUSTONE ]; then
        break
    fi

done <$CASE_LIST

