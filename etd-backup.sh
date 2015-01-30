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
CONFIGFILE="/etc/etd-backup.cfg"
DATANAME="dump_$(date +%d.%m.%y@%Hh%M)"
DUPLICITY_URL=""

# On charge la configuration
shopt -s extglob
while IFS='= ' read lhs rhs
do
    if [[ ! $lhs =~ ^\ *# && -n $lhs ]]; then
        rhs="${rhs%%\#*}"    # Del in line right comments
        rhs="${rhs%%*( )}"   # Del trailing spaces
        rhs="${rhs%\"*}"     # Del opening string quotes
        rhs="${rhs#\"*}"     # Del closing string quotes
        declare $lhs="$rhs"
    fi
done < ${CONFIGFILE}

# Initialisation des variables
verbose=0
ignore_db=0
ignore_files=0
archive=0
purge_files_cmd=
func=

## Logging des messages
exec 3>&1 1>>${LOGFILE} 2>&1

#### Fonctions

# Fonction pour exécuter une commande et envoyer les messages dans le fichier de log mais aussi à la console
# si le paramètre verbose est à 1.
#
# @param integer $1 Le message à envoyer
#
function verbose_exec {
        if [ $verbose -eq 1 ] ; then
                "$@" | tee /dev/fd/3
        else
            	"$@"
        fi
}

#
# Fonction pour créer les répertoires.
#
function mk_dirs {
        verbose_exec echo "Création des dossiers"
        mkdir -p ${DATATMP}/${DATANAME}/mysql
        mkdir -p ${DATATMP}/${DATANAME}/www
        mkdir -p ${DATADIR}
        verbose_exec echo "Dossiers créés"
}

#
# Fonction pour sauvegarder les bases de données.
#
function db_backup {

        verbose_exec echo "Sauvegarde des bases de données"

        # On place dans un tableau le nom de toutes les bases de données du serveur
        databases="$(mysql -u $DB_USER -p$DB_PASS -Bse 'show databases' | grep -v -E $DB_EXCLUSIONS)"

        # Pour chacune des bases de données trouvées ...
        for database in ${databases[@]}; do
                verbose_exec echo "Dump $database"
                mysqldump -u $DB_USER -p$DB_PASS ${MYSQLDUMP_OPTIONS} $database > ${DATATMP}/${DATANAME}/mysql/${database}.sql
        done

	verbose_exec echo "Bases de données sauvegardées"

}

#
# Fonction pour sauvegarder les fichiers
function files_backup {

        verbose_exec echo "Sauvegarde des fichiers"

        # On parcourt les dossiers du serveur web
        cd ${WWW_ROOTDIR}
        for DIR in `ls -d */`
        do
          	if echo "$DIR" | grep -v -E $WWW_EXCLUSIONS > /dev/null ; then
                        verbose_exec echo "Dump $DIR"

                        # On copie le contenu du dossier
                        cp -a ${WWW_ROOTDIR}/${DIR} ${DATATMP}/${DATANAME}/www/${DIR}
                fi
        done

        verbose_exec echo "Fichiers sauvegardés"

}

#
# Fonction pour créer une archive compressée des données
#
function make_archive {

        verbose_exec echo "Création d'une archive"

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

        verbose_exec echo "Archive crée"

}

#
# Fonction pour supprimer les vieilles sauvegardes sur le système local.
#
function clean_old_local_backups {

        verbose_exec echo "Suppression des vieux backups locaux"
        if [ -d ${DATADIR} ]; then
            	if [ $archive -eq 1 ]; then
                        find ${DATADIR} -name "*${COMPRESSION_EXT}" -mtime +${RETENTION} -print -exec rm {} \;
                fi
        fi
        verbose_exec echo "Suppression effectuée"

}

#
# Fonction pour supprimer les vieilles sauvegardes sur le serveur distant.
#
function remove_old_duplicity_backups {

        verbose_exec echo "Suppression des vieux backups distants"

        # Suppression des vieux backups
        verbose_exec ${DUPLICITY_BIN} remove-older-than ${RETENTION}D --force ${DUPLICITY_URL}

        verbose_exec echo "Suppression effectuée"

}

#
# Fonction pour vider le fichier de log
#
function clean_log_file {

        verbose_exec echo "Vidage du fichier de log"
        echo -n "" > ${LOGFILE}
        verbose_exec echo "Vidage terminé"

}

#
# Fonction pour supprimer les fichiers inutiles et récupérer de l'espace libre.
#
function clean_duplicity_backups {
	
        verbose_exec echo "Suppression des fichiers inutiles sur le serveur distant"
        verbose_exec ${DUPLICITY_BIN} cleanup --force --extra-clean ${DUPLICITY_URL}
        verbose_exec echo "Suppression effectuée"

}

#
# Fonction pour supprimer tous les dossiers et fichiers locaux
#
function purge_local {

        verbose_exec echo "Suppression de tous les fichiers locaux"

        # On supprime le dossier des données
        rm -rf ${DATADIR}

        # On supprime le dossier temporaire
        rm -rf ${DATATMP}

        verbose_exec echo "Suppression effectuée"

}

#
# Fonction pour supprimer les fichiers distants.
#
function purge_duplicity {

        verbose_exec echo "Suppression de tous les fichiers distants"

        # On supprime le dossier des données
        ${SFTP_BIN} -u ${SFTP_USER},placeholder -p ${SFTP_PORT} -e "cd /${SFTP_FOLDER}; glob rm -r -f *; bye" sftp://${SFTP_HOST}

        verbose_exec echo "Suppression effectuée"

}

#
# Fonction pour supprimer les fichiers temporaires
#
function purge_tmp_files {

        rm -rf ${DATATMP}

}

#
# Fonction pour stocker les sauvegardes cryptées sur le serveur distant
#
function send_backups_to_duplicity {

        verbose_exec echo "Envoi des backups sur le serveur distant"

        dirtosend=${DATATMP}
        if [ $archive -eq 1 ]; then
                dirtosend=${DATADIR}
        fi

        # On appel duplicity pour effectuer la sauvegarde cryptée sur le serveur distant
        verbose_exec ${DUPLICITY_BIN} --full-if-older-than ${FULLIFOLDERTHAN} / ${DUPLICITY_URL} --include ${dirtosend}/ --exclude '**'

        verbose_exec echo "Envoi terminé"
}

#
# Fonction pour générer le rapport sur le stockage distant
#
function duplicity_report {

        verbose_exec echo "Récupération du rapport sur les sauvegardes le serveur distant"

        # Rapport sur le backup
        verbose_exec ${DUPLICITY_BIN} collection-status ${DUPLICITY_URL}

        verbose_exec echo "Récupération terminée"

}

#
# Fonction pour tester la dernière sauvegarde distante.
#
function test_duplicity {

        verbose_exec echo "Vérification des données"

        # On vérifie la sauvegarde
        verbose_exec ${DUPLICITY_BIN} verify --compare-data ${DUPLICITY_URL} ${DATADIR}
        
        verbose_exec echo "Vérification terminée"

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
        echo "  etd-backup.sh status [options]" 1>&3
        echo "" 1>&3
        echo "Commandes:" 1>&3
        echo "  backup  Sauvegarde les données localement et sur le serveur distant" 1>&3
        echo "  restore Restaure la dernière sauvegarde" 1>&3
        echo "  clean           Nettoie les anciennes sauvegardes" 1>&3
        echo "  purge           Supprime toutes les sauvegardes locales et distantes" 1>&3
        echo "  test            Teste la dernière sauvegarde" 1>&3
        echo "  status  Donne le statut actuel de la sauvegarde" 1>&3
        echo "" 1>&3
        echo "Options:" 1>&3
        echo "  -a, --archive   Crée une archive avant l'envoi des fichiers" 1>&3
        echo "  -h, --help              Affiche ce message" 1>&3
        echo "      --ignore-db Ignore les bases de données" 1>&3
        echo "      --ignore-files	Ignore les fichiers" 1>&3
        echo "  -v, --verbose           Rend le script bavard" 1>&3
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
# Fonction pour préparer l'appel à duplicity
#
function init_duplicity {

        DUPLICITY_URL="sftp://${SFTP_USER}@${SFTP_HOST}:${SFTP_PORT}/${SFTP_FOLDER}"
        export PASSPHRASE

}

#
# Fonction pour supprimer les variables sensibles.
#
function deinit_duplicity {
        unset PASSPHRASE
}

#
# Fonction pour nettoyer le système avant de quitter le script.
#
function cleanup {
        code=$?

        if [ $code -ne 0 ]; then
                verbose_exec echo "Attention: une erreur est survenue !"
        fi

        verbose_exec echo "Nettoyage en sortie"

        # On nettoie les variables sensibles.
        deinit_duplicity

        # On calcul le temps du script.
        end=$(date +"%s")
        diff=$(($end-$start))

        # Message de sortie
        verbose_exec echo "Commande terminée le $(date) en $(($diff / 60)) minutes et $(($diff % 60)) secondes."
        verbose_exec echo "-------- end --------"

        # On envoi le fichier de log par mail si erreur
        if [ $code -ne 0 ] && [ "`stat --format %s ${LOGFILE}`" != "0" ] && [ "$EMAIL" != "0" ] ; then
                cat ${LOGFILE} | mail -s "ETD Backup - $SAUVNAME - Erreur" ${EMAIL}
        fi

        exit $code
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
        if [[ "$1" != "backup" && "$1" != "restore" && "$1" != "clean" && "$1" != "test" && "$1" != "purge" && "$1" != "status" ]]; then
                verbose_exec echo "Attention: La commande $1 est inconnue et a été ignorée"
                usage
                exit
        fi

        func=$1
        shift
fi

# On traite les paramètres
while [ "$1" != "" ] ; do
        case "$1" in
                --ignore-db )           ignore_db=1
                                                        ;;
                --ignore-files )        ignore_files=1
                                                        ;;
                -a | --archive )        archive=1
                                                        ;;
                -v | --verbose )        verbose=1
                                                        ;;
                -h | --help )           usage
                                                        exit
                                                        ;;
                --)                             shift
                                                        break;
                                                        ;;
                -?*)                            verbose_exec echo "Attention: L'option $1 est inconnue et a été ignorée"
                                                        ;;
                * )                                     break
        esac
        shift
done

verbose_exec echo "-------- etd-backup - $(date) --------"

init

verbose_exec echo "Commande exécutée : ${func}"

case "${func}" in

        # Sauvegarde
        backup )

                # on prépare les variables pour duplicity
                init_duplicity

                # On crée les dossiers
                mk_dirs

                # Si la sauvegarde des bdd est activée
                if [ ${ignore_db} -eq 0 ]; then
                        db_backup
                fi

                # Si la sauvegarde des fichiers est activée
                if [ ${ignore_files} -eq 0 ]; then
                        files_backup
                fi

                # On crée l'archive
                if [ ${archive} -eq 1 ]; then
                        make_archive
                fi

                # On nettoie les anciennes sauvegardes
                clean_old_local_backups

                # On envoi les sauvegardes sur le serveur distant
                send_backups_to_duplicity

                # On supprime les vieilles sauvegardes sur le serveur distant
                remove_old_duplicity_backups

                # On crée le rapport
                duplicity_report

                # On nettoie les fichiers temporaires
                purge_tmp_files

                ;;

        # Nettoyage
        clean )

                # on prépare les variables pour duplicity
                init_duplicity

                # On nettoie les anciennes sauvegardes
                clean_old_local_backups

                # On supprime les vieilles sauvegardes sur le serveur distant
                clean_duplicity_backups

                # On vide le fichier de log
                clean_log_file

                ;;

        # Purge
        purge )

                # on prépare les variables pour duplicity
                init_duplicity

                # On supprime tous les fichiers et dossiers locaux
                purge_local

                # On supprime tous les distants
                purge_duplicity

                ;;

        # Test
        test )

                # on prépare les variables pour duplicity
                init_duplicity

                # On teste la dernière sauvegarde le serveur distant
                test_duplicity

                ;;

        # Statut
        status )

                # on prépare les variables pour duplicity
                init_duplicity

                duplicity_report

                ;;
esac

exit 0
