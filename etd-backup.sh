#!/usr/bin/env bash
#
# Copyright (C) 2016 ETD Solutions. All rights reserved.
#

# Default config file
CONFIG="etd-backup.cfg"

usage(){
echo "USAGE:
    `basename $0` [options]

  Options:
    -c, --config CONFIG_FILE   specify the config file to use

    -b, --backup               runs a backup

    -v, --verify               verify a backup

    -r, --restore              extract files from a backup set
    --outdir OUTDIR            specify the output directory for restored data

    -d, --debug                echo commands to logfile

  CURRENT SCRIPT VARIABLES:
  ========================
    DIRS_TO_BACKUP (directories to backup)    = ${DIRS_TO_BACKUP}
    DB_DUMPS_DIR (root directory of db dumps) = ${DB_DUMPS_DIR}
    LOGFILE (log file path)                   = ${LOGFILE}
    DB_USER                                   = ${DB_USER}
    BUP_DEST (directory to store BUP backups) = ${BUP_DEST}
"
}

while getopts ":c:bvrd-:" opt; do
  case $opt in
    # parse long options (a bit tricky because builtin getopts does not
    # manage long options and I don't want to impose GNU getopt dependancy)
    -)
      case "$OPTARG" in
        config) # set the config file from the command line
          # We try to find the config file
          if [ ! -z "${!OPTIND:0:1}" -a ! "${!OPTIND:0:1}" = "-" ]; then
            CONFIG=${!OPTIND}
            OPTIND=$(( $OPTIND + 1 )) # we found it, move forward in arg parsing
          fi
        ;;
        outdir) 
          OUTDIR=${!OPTIND}
          OPTIND=$(( $OPTIND + 1 )) # we found it, move forward in arg parsing
	;;
        debug)
          ECHO=$(which echo)
        ;;
        *)
          COMMAND=$OPTARG
        ;;
        esac
    ;;
    # here are parsed the short options
    c) CONFIG=$OPTARG;; # set the config file from the command line
    v) COMMAND="verify";;
    r) COMMAND="restore";;
    b) COMMAND="backup";;
    d) ECHO=$(which echo);; # debug
    :)
      echo "Option -$OPTARG requires an argument." >&2
      COMMAND=""
    ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      COMMAND=""
    ;;
  esac
done

# Read config file if specified
if [ ! -z "$CONFIG" -a -f "$CONFIG" ];
then
  . $CONFIG
else
  echo "ERROR: can't find config file! (${CONFIG})" >&2
  usage
  exit 1
fi

if [ ! -x "$BUP" ]; then
  echo "ERROR: BUP not found!" >&2
  exit 1
fi

# Ensure a trailing slash always exists in the log directory name
LOGDIR="${LOGDIR%/}/"
LOGFILE="${LOGDIR}${LOG_FILE}"

config_sanity_fail()
{
  EXPLANATION=$1
  CONFIG_VAR_MSG="Oops!! ${0} was unable to run!\nWe are missing one or more important variables in the configuration file.\nCheck your configuration because it appears that something has not been set yet."
  echo -e "${CONFIG_VAR_MSG}\n  ${EXPLANATION}."
  exit 1
}

check_variables ()
{
  [[ ${DIRS_TO_BACKUP} = "" ]] && config_sanity_fail "DIRS_TO_BACKUP must be configured"
  [[ ${DB_DUMPS_DIR} = "" ]] && config_sanity_fail "DB_DUMPS_DIR must be configured"
  [[ ${DB_PASS} = "" ]] && config_sanity_fail "DB_PASS must be configured"
  [[ ${LOGDIR} = "" ]] && config_sanity_fail "LOGDIR must be configured"
  [[ ${BUP_DEST} = "" ]] && config_sanity_fail "BUP_DEST must be configured"
}


check_dirs()
{
  if [ ! -d ${LOGDIR} ]; then
    echo "Attempting to create log directory ${LOGDIR} ..."
    if ! mkdir -p ${LOGDIR}; then
      echo "Log directory ${LOGDIR} could not be created by this user: ${USER}"
      echo "Aborting..."
      exit 1
    else
      echo "Directory ${LOGDIR} successfully created."
    fi
    echo "Attempting to change owner:group of ${LOGDIR} to ${LOG_FILE_OWNER} ..."
    if ! chown ${LOG_FILE_OWNER} ${LOGDIR}; then
      echo "User ${USER} could not change the owner:group of ${LOGDIR} to $LOG_FILE_OWNER"
      echo "Aborting..."
      exit 1
    else
      echo "Directory ${LOGDIR} successfully changed to owner:group of ${LOG_FILE_OWNER}"
    fi
  elif [ ! -w ${LOGDIR} ]; then
    echo "Log directory ${LOGDIR} is not writeable by this user: ${USER}"
    echo "Aborting..."
    exit 1
  fi
  if [ ! -d ${DB_DUMPS_DIR} ]; then
    echo "Attempting to create db dumps directory ${DB_DUMPS_DIR} ..."
    if ! mkdir -p ${DB_DUMPS_DIR}; then
      echo "DB dumps directory ${DB_DUMPS_DIR} could not be created by this user: ${USER}"
      echo "Aborting..."
      exit 1
    else
      echo "Directory ${DB_DUMPS_DIR} successfully created."
    fi
    echo "Attempting to change owner:group of ${DB_DUMPS_DIR} to ${LOG_FILE_OWNER} ..."
    if ! chown ${LOG_FILE_OWNER} ${DB_DUMPS_DIR}; then
      echo "User ${USER} could not change the owner:group of ${DB_DUMPS_DIR} to $LOG_FILE_OWNER"
      echo "Aborting..."
      exit 1
    else
      echo "Directory ${DB_DUMPS_DIR} successfully changed to owner:group of ${LOG_FILE_OWNER}"
    fi
  elif [ ! -w ${DB_DUMPS_DIR} ]; then
    echo "DB dumps directory ${DB_DUMPS_DIR} is not writeable by this user: ${USER}"
    echo "Aborting..."
    exit 1
  fi
}

check_variables
check_dirs

echo -e "--------    START ETD-BACKUP SCRIPT    --------\n" >> ${LOGFILE}

db_backup()
{

  databases="$(mysql -u $DB_USER -p$DB_PASS -Bse 'show databases' | grep -v -E $DB_EXCLUSIONS)"
  for database in ${databases[@]}; do
    mysqldump -u $DB_USER -p$DB_PASS ${MYSQLDUMP_OPTIONS} $database > ${DB_DUMPS_DIR}/${database}.sql
  done

}

bup_backup()
{

  INIT_OPTIONS=""
  eval ${ECHO} BUP_DIR=${BUP_DEST} ${BUP} init ${INIT_OPTIONS}

  INDEX_OPTIONS=""
  if [ -n ${BUP_EXCLUDE} ] ; then
    INDEX_OPTIONS="${INDEX_OPTIONS} --exclude-rx=${BUP_EXCLUDE}"
  fi
  eval ${ECHO} BUP_DIR=${BUP_DEST} ${BUP} index ${INDEX_OPTIONS} ${DB_DUMPS_DIR} ${DIRS_TO_BACKUP}

  SAVE_OPTIONS="-n backup"
  eval ${ECHO} BUP_DIR=${BUP_DEST} ${BUP} save ${SAVE_OPTIONS} ${DB_DUMPS_DIR} ${DIRS_TO_BACKUP}

}

bup_fsck()
{

  INDEX_OPTIONS="--check"
  if [ -n ${BUP_EXCLUDE} ] ; then
    INDEX_OPTIONS="${INDEX_OPTIONS} --exclude-rx=${BUP_EXCLUDE}"
  fi
  eval ${ECHO} BUP_DIR=${BUP_DEST} ${BUP} index ${INDEX_OPTIONS}

  FSCK_OPTIONS="-v"
  eval ${ECHO} BUP_DIR=${BUP_DEST} ${BUP} fsck ${FSCK_OPTIONS}

}

bup_restore()
{

  RESTORE_OPTIONS="-v"
  if [ -n "${OUTDIR}" ] ; then 
    RESTORE_OPTIONS="${RESTORE_OPTIONS} --outdir=${OUTDIR}"
  fi

  eval ${ECHO} BUP_DIR=${BUP_DEST} ${BUP} restore ${RESTORE_OPTIONS} /backup/latest 
  
}

clean_files()
{

  eval ${ECHO} rm -f ${DB_DUMPS_DIR}/*.sql

}

case "$COMMAND" in

  "backup")
    	db_backup
    	bup_backup
    	clean_files
    exit
  ;;

  "verify")
	bup_fsck
    exit
  ;;

  "restore")
	bup_restore
    exit
  ;;

  *)
    echo -e "[Only show `basename $0` usage options]\n" >> ${LOGFILE}
    usage
  ;;
esac

echo -e "---------    END ETD-BACKUP SCRIPT    ---------\n" >> ${LOGFILE}

# remove old logfiles
# stops them from piling up infinitely
[[ -n "${REMOVE_LOGS_OLDER_THAN}" ]] && find ${LOGDIR} -type f -mtime +"${REMOVE_LOGS_OLDER_THAN}" -delete

if [ ${ECHO} ]; then
  echo "TEST RUN ONLY: Check the logfile for command output."
fi
