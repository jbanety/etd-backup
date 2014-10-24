#!/bin/bash
#
# @package     etd-backup
#
# @version     0.0.1
# @copyright   Copyright (C) 2014 SARL ETUDOO, ETD Solutions. All rights reserved.
# @license     https://raw.githubusercontent.com/jbanety/etd-backup/master/LICENSE.md
# @author      Jean-Baptiste Alleaume (@jbanety) http://alleau.me
#

set -eu

## Paramètres
# @var string Nom de la sauvegarde
SAUVNAME=`hostname`
# @var string Répertoire de stockage des sauvegardes
DATADIR="/var/etd-backup"
# @var string Répertoire de travail (création/compression)
DATATMP="/var/tmp/etd-backup"
# @var string Nom du dossier du dump
DATANAME="dump_$(date +%d.%m.%y@%Hh%M)"
# @var string Commande pour la compression
COMPRESSION_CMD="tar -cf"
# @var string Options à passer pour la commande de compression
COMPRESSION_OPT="--use-compress-prog=pbzip2"
# @var string Extension des archives
COMPRESSION_EXT=".tar.bz2"
# @var string Fréquence des sauvegardes complètes
FULLIFOLDERTHAN="1W"
# @var integer Le nombre de jours de rétention des sauvegardes
RETENTION="60"
# @var string Utilisateur MySQL utilisé pour le dump
DB_USER="etdbackup"
# @var string Mot de passe
DB_PASS="@cvyizqB9qNL8zi@"
# @var string Noms des bases de données à exclure (regex)
DB_EXCLUSIONS="(information_schema|performance_schema)"
# Utilisateur Hubic
HUBIC_USER="contact@etudoo.fr"
# Mot de passe HubiC
HUBIC_PASSWORD="@AxF9hsCoQTktyY@"
# Application client id Hubic
HUBIC_APPID="api_hubic_BcWEnGVgNIOqj7zkNBS4QEqTy7Z3tHNl"
# Application client secret Hubic
HUBIC_APPSECRET="FBGPZutXbIN2kkFG240kseO6XeWrmemBm29Iep2eQM1NXlspe4ChH0YielJdZ85d"
# Application domaine de redirection Hubic
HUBIC_APPURLREDIRECT="http://localhost/"
# Dossier Hubic dans lequel seront envoyées les sauvegardes
HUBIC_FOLDER="cazin_backups"
# Passphrase pour le chiffrement des sauvegardes
PASSPHRASE="@BjH4zzY4bV6L5U@"
# @var string Email pour les erreurs (0 pour désactiver)
EMAIL="support@etd-solutions.com"
# @var string Chemin vers l'exécutable duplicity
DUPLICITY_BIN="/usr/bin/duplicity"
# @var string Ficher de log d'erreur
LOGERROR="/var/log/etd-backup.log"
# @var bool Envoi un rapport par email sur l'état des backups
RAPPORT=1

# Log d'erreur
exec 2> ${LOGERROR}

## Début du script

function cleanup {
	echo "exit"
	unset CLOUDFILES_USERNAME
    unset CLOUDFILES_APIKEY
    unset PASSPHRASE
    if [ "`stat --format %s ${LOGERROR}`" != "0" ] && [ "$EMAIL" != "0" ] ; then
        cat ${LOGERROR} | mail -s "ETD Backup - $SAUVNAME - Erreurs" ${EMAIL}
    fi
}
trap cleanup EXIT

# On est gentil avec le système
ionice -c3 -p$$ &>/dev/null
renice -n 19 -p $$ &>/dev/null

echo "Début de la sauvegarde à $(date)."

# On crée sur le disque les répertoires temporaires
mkdir -p ${DATATMP}/${DATANAME}/mysql
mkdir -p ${DATATMP}/${DATANAME}/www

echo "Sauvegarde des bases de données"

# On place dans un tableau le nom de toutes les bases de données du serveur
databases="$(mysql -u $DB_USER -p$DB_PASS -Bse 'show databases' | grep -v -E $DB_EXCLUSIONS)"

# Pour chacune des bases de données trouvées ...
for database in ${databases[@]}
do
    echo "Dump $database"
    mysqldump -u $DB_USER -p$DB_PASS --quick --add-locks --lock-tables --extended-insert $database  > ${DATATMP}/${DATANAME}/mysql/${database}.sql
done

# On crée une archive TAR bzippée.
cd ${DATATMP}
${COMPRESSION_CMD} ${DATANAME}${COMPRESSION_EXT} ${COMPRESSION_OPT} ${DATANAME}/
chmod 600 ${DATANAME}${COMPRESSION_EXT}

# On la déplace dans le répertoire final de stockage
if [ "$DATATMP" != "$DATADIR" ] ; then
    mv ${DATANAME}${COMPRESSION_EXT} ${DATADIR}
fi

# On supprime le répertoire temporaire
rm -rf ${DATATMP}/${DATANAME}

echo "Suppression des vieux backups locaux"
find ${DATADIR} -name "*${COMPRESSION_EXT}" -mtime +${RETENTION} -print -exec rm {} \;

echo "Envoi des backups sur hubic"
export CLOUDFILES_USERNAME=${HUBIC_USER}
export CLOUDFILES_APIKEY=${HUBIC_PASSWORD}
export CLOUDFILES_AUTHURL="hubic|${HUBIC_APPID}|${HUBIC_APPSECRET}|${HUBIC_APPURLREDIRECT}"
export PASSPHRASE

# Backup
${DUPLICITY_BIN} --full-if-older-than ${FULLIFOLDERTHAN} / cf+http://${HUBIC_FOLDER} --include ${DATADIR}/ --exclude '**'

# Suppression des vieux backups
${DUPLICITY_BIN} remove-older-than ${RETENTION}D cf+http://${HUBIC_FOLDER} --force

# Rapport sur le backup
if [ "$RAPPORT" != "0" ] && [ "$EMAIL" != "0" ] ; then
        ${DUPLICITY_BIN} collection-status cf+http://${HUBIC_FOLDER} | mail -s "ETD Backup - $SAUVNAME - Rapport hubiC" ${EMAIL}
fi

unset CLOUDFILES_USERNAME
unset CLOUDFILES_APIKEY
unset PASSPHRASE

echo "Sauvegarde terminée à $(date)."
exit 0