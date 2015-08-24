#!/usr/bin/env bash
#
# Copyright (C) 2015 ETD Solutions. All rights reserved.
#

# Default config file
CONFIG="etd-backup.cfg"

usage(){
echo "USAGE:
    `basename $0` [options]

  Options:
    -c, --config CONFIG_FILE   specify the config file to use

    -b, --backup               runs a backup

  CURRENT SCRIPT VARIABLES:
  ========================
    DEST (backup destination)       = ${DEST}
    INCLIST (directories included)  = ${INCLIST[@]:0}
    EXCLIST (directories excluded)  = ${EXCLIST[@]:0}
    ROOT (root directory of backup) = ${ROOT}
    LOGFILE (log file path)         = ${LOGFILE}
"
}

while getopts ":c:t:bfvlsnd-:" opt; do
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

if [ ! -x "$DUPLICITY_BACKUP" ]; then
  echo "ERROR: duplicity-backup not found!" >&2
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
  [[ ${ROOT} = "" ]] && config_sanity_fail "ROOT must be configured"
  [[ ${DB_PASS} = "" ]] && config_sanity_fail "DB_PASS must be configured"
  [[ ${LOGDIR} = "" ]] && config_sanity_fail "LOGDIR must be configured"
}


check_logdir()
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
}

check_variables
check_logdir

echo -e "--------    START ETD-BACKUP SCRIPT    --------\n" >> ${LOGFILE}

INCLUDE=
EXCLUDE=
EXCLUDEROOT=

db_backup()
{

  databases="$(mysql -u $DB_USER -p$DB_PASS -Bse 'show databases' | grep -v -E $DB_EXCLUSIONS)"
  for database in ${databases[@]}; do
    mysqldump -u $DB_USER -p$DB_PASS ${MYSQLDUMP_OPTIONS} $database > ${ROOT}/${database}.sql
  done

}

duplicity_backup()
{
  OPTION="--backup"

  eval ${ECHO} ${DUPLICITY_BACKUP} ${OPTION}

}

case "$COMMAND" in

  "backup")
    	db_backup
    	duplicity_backup
    exit
  ;;

  *)
    echo -e "[Only show `basename $0` usage options]\n" >> ${LOGFILE}
    usage
  ;;
esac

echo -e "---------    END ETD-BACKUP SCRIPT    ---------\n" >> ${LOGFILE}