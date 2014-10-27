#!/bin/bash
#
# @package     etd-backup
#
# @version     0.0.1
# @copyright   Copyright (C) 2014 SARL ETUDOO, ETD Solutions. All rights reserved.
# @license     https://raw.githubusercontent.com/jbanety/etd-backup/master/LICENSE.md
# @author      Jean-Baptiste Alleaume (@jbanety) http://alleau.me
#

set -e

start=$(date +"%s")

#### Paramètres

# Initialisation des variables
verbose=0
ignore_db=0
ignore_files=0
func=

## Logging des messages
exec 3>&1 1>>${LOGFILE} 2>&1

#### Fonctions

# Fonction pour envoyer un message dans le fichier de log mais aussi à la console
# si le paramètre verbose est à 1.
#
# @param integer $1 Le message à envoyer
#
function echo_msg {
	if [ $verbose -eq 1 ] ; then
		echo $1 | tee /dev/fd/3
	else
		echo $1
	fi
}

#
# Fonction pour créer les répertoires temporaires.
#
function mk_tmp_dirs {
	echo_msg "Création des dossiers temporaires"
	mkdir -p ${DATATMP}/${DATANAME}/mysql
	mkdir -p ${DATATMP}/${DATANAME}/www
	echo_msg "Dossiers temporaires créés"
}

#
# Fonction pour sauvegarder les bases de données.
#
function db_backup {

	echo_msg "Sauvegarde des bases de données"

	# On place dans un tableau le nom de toutes les bases de données du serveur
	databases="$(mysql -u $DB_USER -p$DB_PASS -Bse 'show databases' | grep -v -E $DB_EXCLUSIONS)"

	# Pour chacune des bases de données trouvées ...
	for database in ${databases[@]}; do
	    echo_msg "Dump $database"
	    mysqldump -u $DB_USER -p$DB_PASS --quick --add-locks --lock-tables --events --extended-insert $database  > ${DATATMP}/${DATANAME}/mysql/${database}.sql
	done

	echo_msg "Bases de données sauvegardées"

}

#
# Fonction pour sauvegarder les fichiers
#
function files_backup {

	echo_msg "Sauvegarde des fichiers"

	# On parcourt les dossiers du serveur web
	cd ${WWW_ROOTDIR}
	for DIR in `ls -d */`
	do
		if echo "$DIR" | grep -v -E $WWW_EXCLUSIONS > /dev/null ; then
			echo_msg "Dump $DIR"

			# On copie le contenu du dossier
			cp -a ${WWW_ROOTDIR}/${DIR} ${DATATMP}/${DATANAME}/www/${DIR}
		fi
	done

	echo_msg "Fichiers sauvegardés"

}

#
# Fonction pour créer une archive compressée des données
#
function make_archive {

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

} 

#
# Fonction pour supprimer les vieilles sauvegardes sur le système local.
#
function clean_old_local_backups {
	echo_msg "Suppression des vieux backups locaux"
	find ${DATADIR} -name "*${COMPRESSION_EXT}" -mtime +${RETENTION} -print -exec rm {} \;
	echo_msg "Suppression effectuée"
}

#
# Fonction pour supprimer les vieilles sauvegardes sur hubiC.
#
function clean_old_hubic_backups {
	# Suppression des vieux backups
	${DUPLICITY_BIN} remove-older-than ${RETENTION}D cf+http://${HUBIC_FOLDER} -v0 --force
}

#
# Fonction pour stocker les sauvegardes cryptées sur hubiC
#
function send_backups_to_hubic {

	echo_msg "Envoi des backups sur hubiC"

	# On exporte les variables pour duplicity
	export CLOUDFILES_USERNAME=${HUBIC_USER}
	export CLOUDFILES_APIKEY=${HUBIC_PASSWORD}
	export CLOUDFILES_AUTHURL="hubic|${HUBIC_APPID}|${HUBIC_APPSECRET}|${HUBIC_APPURLREDIRECT}"
	export PASSPHRASE

	# On appel duplicity pour effectuer la sauvegarde cryptée sur hubiC
	${DUPLICITY_BIN} -v0 --full-if-older-than ${FULLIFOLDERTHAN} / cf+http://${HUBIC_FOLDER} --include ${DATADIR}/ --exclude '**'

	echo_msg "Envoi terminé"
}

function send_hubic_report {
	# Rapport sur le backup
	if [ "$RAPPORT" != "0" ] && [ "$EMAIL" != "0" ] ; then
		${DUPLICITY_BIN} collection-status cf+http://${HUBIC_FOLDER} | mail -s "ETD Backup - $SAUVNAME - Rapport hubiC" ${EMAIL}
	fi
}

#
# Fonction pour imprimer l'usage.
#
function usage {
	echo "Usage:" 1>&3
	echo "  etd-backup.sh backup [options]" 1>&3
	echo "  etd-backup.sh restore [options]" 1>&3
	echo "  etd-backup.sh clean [options]" 1>&3
	echo "  etd-backup.sh purge [options]" 1>&3
	echo "  etd-backup.sh test [options]" 1>&3
	echo "" 1>&3
	echo "Commandes:" 1>&3
	echo "  backup	Sauvegarde les données localement et sur hubiC" 1>&3
	echo "  restore	Restaure la dernière sauvegarde" 1>&3
	echo "  clean		Nettoie les anciennes sauvegardes" 1>&3
	echo "  purge		Supprime toutes les sauvegardes locales et distantes" 1>&3
	echo "  test		Teste la dernière sauvegarde" 1>&3
	echo "" 1>&3
	echo "Options:" 1>&3
	echo "  -h, --help		Affiche ce message" 1>&3
	echo "      --ignore-db	Ignore les bases de données" 1>&3
	echo "      --ignore-files	Ignore les fichiers" 1>&3
	echo "  -v, --verbose		Rend le script bavard" 1>&3
}

#
# Fonction appelée pour préparer le script.
#
function init {

	# On est gentil avec le système
	ionice -c3 -p$$ &>/dev/null
	renice -n 19 -p $$ &>/dev/null

	# On met en place le catch sur l'exit pour nettoyer le business.
	trap cleanup EXIT
}

#
# Fonction pour nettoyer le système avant de quitter le script.
#
function cleanup {
	echo "Nettoyage"

	# On nettoie les variables sensibles.
	unset CLOUDFILES_USERNAME
	unset CLOUDFILES_APIKEY
	unset PASSPHRASE

	# On calcul le temps du script.
	end=$(date +"%s")
	diff=$(($end-$start))

	# Message de sortie
	echo_msg "Sauvegarde terminée à $(date) en $(($diff / 60)) minutes et $(($diff % 60)) secondes."
	echo_msg "-------- end --------"

	# On envoi le mail si besoin
	if [ "`stat --format %s ${LOGFILE}`" != "0" ] && [ "$EMAIL" != "0" ] ; then
		cat ${LOGFILE} | mail -s "ETD Backup - $SAUVNAME - Erreurs" ${EMAIL}
	fi
}

#### Main

# Si aucun paramètre n'a été passé
if [ $# -eq 0 ] ; then
	usage
	exit
fi

# On détecte la commande.
if [ "$1" != "" ] ; then

	# On vérifie que la commande exite.
	if [[ "$1" != "backup" && "$1" != "restore" && "$1" != "clean" && "$1" != "test" && "$1" != "purge" ]]; then
		echo_msg "Attention: La commande $1 est inconnue et a été ignorée"
		usage
		exit
	fi

	func=$1
	shift
fi

echo "${func}" 1>&3

# On traite les paramètres
while [ "$1" != "" ] ; do
	case "$1" in
		--ignore-db )		ignore_db=1
							;;
		--ignore-files )	ignore_files=1
							;;	
		-v | --verbose )	verbose=1
							;;
		-h | --help )		usage
							exit
							;;
		--) 				shift
							break;
							;;
		-?*)				echo_msg "Attention: L'option $1 est inconnue et a été ignorée"
							;;
		* )					break
	esac
	shift
done

echo_msg "-------- etd-backup - $(date) --------"

init

echo_msg "Commande exécutée : ${func}"

case "${func}" in

	# Sauvegarde
	backup )
	
		# Dossiers temporaires
		mk_tmp_dirs

		# Si la sauvegarde des bdd est activée
		if [ ${ignore_db} -eq 0 ]; then
			db_backup
		fi

		# Si la sauvegarde des fichiers est activée
		if [ ${ignore_files} -eq 0 ]; then
			files_backup
		fi

		# On crée l'archive
		make_archive

		# On nettoie les anciennes sauvegardes
		clean_old_local_backups

		# On envoi les sauvegardes sur hubiC
		send_backups_to_hubic

		# On supprime les vieilles sauvegardes sur hubiC
		clean_old_hubic_backups

		# On envoi le rapport par email
		send_hubic_report

		;;

	clean )
		
		;;
esac

exit 1