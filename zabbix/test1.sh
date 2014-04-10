#!/bin/bash
shopt -s extglob
shopt -s expand_aliases
set +H

startDate='2013-10-16'
partByField='clock'
alterPartScript='/root/Scripts/Apamynche/mysql/alter_part'
declare -A zbxServer=(
	['host']='nms31.svc.ot.ru'
	['config']='zabbix_server.conf'
)
declare -A zbxFrontend=(
	['host']='fe01.svc.ot.ru'
	['config']='zabbix.conf.php'
)
declare -A sqlSkel=(
	['WITHOUT_DATA']='dump_skel_of_big_tables.sql'
	['WITH_DATA']='dump_tables_w_data.sql'
)


declare -i rc=0

[[ ${zbxServer[config]} =~ \/ ]] || zbxServer[config]="/etc/zabbix/${zbxServer[config]}"
[[ ${zbxFrontend[config]} =~ \/ ]] || zbxFrontend[config]="/etc/zabbix/${zbxFrontend[config]}"
source <(
 for v in {User,Password}; do
  ssh nms31 "sed -nr '/^\s*DB${v}=/I{ s%^[^=]+=%&\"%; s%$%\"%; p; q }' ${zbxServer[config]}"
 done
)

doShowUsage () {
 cat >&2 <<EOUSAGE
Usage: $0 [-x] [-f] [-s] [-z] [-d DB_NAME]
 -x		For BASH native trace
 -f		To force load data from source database
 -s		Skip new database recreation (so partitioning will be applied to already existing and data-filled database)
 -z		Direct manage zabbix-server and zabbix-frontend (maybe dangerous!) 
 -d DB_NAME 	Set the new database (default: use script file name without .sh extension)
 -h		Show this very useful help message :)
EOUSAGE
 return 0
}

sql_ () { 
 local ret db=$dbName flShowTimings=1 opt i
 while [[ ${1:0:1} == '-' ]]; do
  opt=${1##+(-)}
  [[ $opt ]] || { shift; break; }
  for ((i=0; i<${#opt}; i++)); do
   case ${opt:$i:1} in
    g) shift; db='' ;;
    T) unset flShowTimings ;;
    t) flShowTimings=1 ;;
    d) (( (i+1)==${#opt} )) || return 1
       shift; dbName="$1"
    ;;
    *) return 1 ;;    
   esac
  done
  shift
 done
 if [[ -t 0 ]]; then
  alias out='echo "$@"'
 else
  alias out='cat'
 fi 
 if [[ $flShowTimings ]]; then
  time mysql $db < <(out)
  ret=$?
 else
  mysql $db < <(out)
  ret=$? 
 fi
 unalias out
 rc+=$ret
 return $ret
}

while getopts ':xfszh d:' k; do
 case $k in
  x) set -x; DEBUG=1 ;;
  f) flForce=1 ;;
  s) flSkipDbRecreate=1
#   [[ -f ${sqlSkel[WITH_DATA]} && -f ${sqlSkel[WITHOUT_DATA]} ]] || \
#    echo "One of the required files is absent. Required: $(echo ${sqlSkel[@]//+([[:space:]])/<WHITE_SPACE>} | tr ' ' '\n')"
  ;;
  d) dbName=$OPTARG ;;
  z) flZabbixManage=1 ;;
  h) doShowUsage; exit 0 ;;
  *) echo "\"-$OPTARG\" is unknown parameter, see usage for more info" >&2
     doShowUsage; exit 1 ;;
 esac
done
shift $((OPTIND-1))

[[ $dbName ]] || {
 dbName=${0##*/}; dbName=${dbName%.sh}
}

echo "DBNAME=$dbName" >&2

if [[ ! $flSkipDbRecreate ]]; then
 if [[ $flForce || ! -f ${sqlSkel[WITH_DATA]} ]]; then
  [[ $flZabbixManage ]] && ssh ${zbxServer[host]} 'service zabbix-server stop'
  time mysqldump \
	--single-transaction \
	--skip-comments \
	--quick \
	--add-locks \
	--disable-keys \
	--extended-insert \
	--routines \
	--triggers \
	zabbix \
	 $(mysql <<<'SELECT table_name AS "Tables" FROM information_schema.TABLES 
	 		WHERE table_schema = "zabbix" AND (data_length + index_length)<=(1<<30)
	 		ORDER BY (data_length + index_length) DESC;' | \
	    fgrep -v 'manage_partitions' | sed 1d) > ${sqlSkel[WITH_DATA]}
  rc+=$?
  [[ $flZabbixManage ]] && ssh ${zbxServer[host]} 'service zabbix-server start'
 fi	 		
 if [[ $flForce || ! -f ${sqlSkel[WITHOUT_DATA]} ]]; then
  time mysqldump \
	--no-data \
	--skip-comments \
	zabbix \
	 $(mysql <<<'SELECT table_name AS "Tables" FROM information_schema.TABLES
	 		WHERE table_schema = "zabbix" AND (data_length + index_length)>(1<<30)
	 		ORDER BY (data_length + index_length) DESC;' | \
	    sed 1d) > ${sqlSkel[WITHOUT_DATA]}
  rc+=$?
 fi
	 		 
 sql_ -g "DROP DATABASE IF EXISTS $dbName; CREATE DATABASE $dbName;" 

 for k in WITH{,OUT}_DATA; do
  sql_ < "${sqlSkel[$k]}"
 done
 
fi

sql_ -T "GRANT ALL PRIVILEGES ON $dbName.* TO '$DBUser'@'${zbxServer[host]}' IDENTIFIED BY '$DBPassword';"

[[ $(mysql -e 'show variables like "event_scheduler%"\G' | sed -nr 's%^\s*Value:\s*%%p') == 'ON' ]] || {
 echo 'Turning on event_scheduler. Make this changes permanent by adding event_scheduler=1 to my.cnf' >&2
 sql_ -T 'SET GLOBAL event_scheduler=ON;'
}

tmpFile=$(mktemp /tmp/XXXXXXXXXXXX)
trap "rm -f $tmpFile" EXIT

exec 3<&1 1>>$tmpFile
for t in {log,text}; do
 echo 'ALTER TABLE `history_'${t}'` DROP PRIMARY KEY, ADD PRIMARY KEY (`id`,`clock`);'
 [[ $(sed -nr '/(KEY|INDEX)\s*`?history_'${t}'_2`?/{ p; q }' dump_skel_of_big_tables.sql) ]] && \
  echo 'ALTER TABLE `history_'${t}'` DROP KEY `history_'${t}'_2`;'
 echo 'ALTER TABLE `history_'${t}'` ADD UNIQUE INDEX `history_'${t}'_2`(`itemid`,`id`,`clock`);'
done

cat <<'EOSQL'
DROP TABLE IF EXISTS `manage_partitions`;
CREATE TABLE `manage_partitions` (
  `tablename` VARCHAR(64) NOT NULL COMMENT 'Имя секционируемой таблицы',
  `period` VARCHAR(64) NOT NULL COMMENT 'Период секционирования: day или month',
  `keep_history` INT(3) UNSIGNED NOT NULL DEFAULT '1' COMMENT 'Количество дней или месяцев хранения секций',
  `last_updated` DATETIME DEFAULT NULL COMMENT 'Время последнего добавления секции',
  `comments` VARCHAR(128) DEFAULT '1' COMMENT 'Комментарии',
  PRIMARY KEY (`tablename`)
) ENGINE=INNODB;

INSERT INTO manage_partitions
 (tablename        , period , keep_history, last_updated, comments)
VALUES 
 ('history'        , 'day',   30,           now()       , ''),
 ('history_uint'   , 'day',   30,           now()       , ''),
 ('history_str'    , 'day',   120,          now()       , ''),
 ('history_text'   , 'day',   120,          now()       , ''),
 ('history_log'    , 'day',   120,          now()       , ''),
 ('trends'         , 'month', 24,           now()       , ''),
 ('trends_uint'    , 'month', 24,           now()       , '');

DELIMITER $$

DROP PROCEDURE IF EXISTS `create_partition_by_day`$$
 
CREATE PROCEDURE `create_partition_by_day`(IN_SCHEMANAME VARCHAR(64), IN_TABLENAME VARCHAR(64))
BEGIN
    DECLARE ROWS_CNT INT UNSIGNED;
    DECLARE BEGINTIME TIMESTAMP;
        DECLARE ENDTIME INT UNSIGNED;
        DECLARE PARTITIONNAME VARCHAR(16);
        SET BEGINTIME = DATE(NOW()) + INTERVAL 1 DAY;
        SET PARTITIONNAME = DATE_FORMAT( BEGINTIME, 'p%Y_%m_%d' );
 
        SET ENDTIME = UNIX_TIMESTAMP(BEGINTIME + INTERVAL 1 DAY) div 1;
 
        SELECT COUNT(*) INTO ROWS_CNT
                FROM information_schema.partitions
                WHERE table_schema = IN_SCHEMANAME AND table_name = IN_TABLENAME AND partition_name = PARTITIONNAME;
 
    IF ROWS_CNT = 0 THEN
                     SET @SQL = CONCAT( 'ALTER TABLE `', IN_SCHEMANAME, '`.`', IN_TABLENAME, '`',
                                ' ADD PARTITION (PARTITION ', PARTITIONNAME, ' VALUES LESS THAN (', ENDTIME, '));' );
                PREPARE STMT FROM @SQL;
                EXECUTE STMT;
                DEALLOCATE PREPARE STMT;
        ELSE
        SELECT CONCAT("partition `", PARTITIONNAME, "` for table `",IN_SCHEMANAME, ".", IN_TABLENAME, "` already exists") AS result;
        END IF;
END$$
 
DROP PROCEDURE IF EXISTS `create_partition_by_month`$$
 
CREATE PROCEDURE `create_partition_by_month`(IN_SCHEMANAME VARCHAR(64), IN_TABLENAME VARCHAR(64))
BEGIN
    DECLARE ROWS_CNT INT UNSIGNED;
    DECLARE BEGINTIME TIMESTAMP;
        DECLARE ENDTIME INT UNSIGNED;
        DECLARE PARTITIONNAME VARCHAR(16);
        SET BEGINTIME = DATE(NOW() - INTERVAL DAY(NOW()) DAY + INTERVAL 1 DAY + INTERVAL 1 MONTH);
        SET PARTITIONNAME = DATE_FORMAT( BEGINTIME, 'p%Y_%m' );
 
        SET ENDTIME = UNIX_TIMESTAMP(BEGINTIME + INTERVAL 1 MONTH) div 1;
 
        SELECT COUNT(*) INTO ROWS_CNT
                FROM information_schema.partitions
                WHERE table_schema = IN_SCHEMANAME AND table_name = IN_TABLENAME AND partition_name = PARTITIONNAME;
 
    IF ROWS_CNT = 0 THEN
                     SET @SQL = CONCAT( 'ALTER TABLE `', IN_SCHEMANAME, '`.`', IN_TABLENAME, '`',
                                ' ADD PARTITION (PARTITION ', PARTITIONNAME, ' VALUES LESS THAN (', ENDTIME, '));' );
                PREPARE STMT FROM @SQL;
                EXECUTE STMT;
                DEALLOCATE PREPARE STMT;
        ELSE
        SELECT CONCAT("partition `", PARTITIONNAME, "` for table `",IN_SCHEMANAME, ".", IN_TABLENAME, "` already exists") AS result;
        END IF;
END$$
 
DROP PROCEDURE IF EXISTS `create_next_partitions`$$
 
CREATE PROCEDURE `create_next_partitions`(IN_SCHEMANAME VARCHAR(64))
BEGIN
    DECLARE TABLENAME_TMP VARCHAR(64);
    DECLARE PERIOD_TMP VARCHAR(12);
    DECLARE DONE INT DEFAULT 0;
 
    DECLARE get_prt_tables CURSOR FOR
        SELECT `tablename`, `period`
            FROM manage_partitions;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
 
    OPEN get_prt_tables;
 
    loop_create_part: LOOP
        IF DONE THEN
            LEAVE loop_create_part;
        END IF;
 
        FETCH get_prt_tables INTO TABLENAME_TMP, PERIOD_TMP;
 
        CASE WHEN PERIOD_TMP = 'day' THEN
                    CALL `create_partition_by_day`(IN_SCHEMANAME, TABLENAME_TMP);
             WHEN PERIOD_TMP = 'month' THEN
                    CALL `create_partition_by_month`(IN_SCHEMANAME, TABLENAME_TMP);
             ELSE
            BEGIN
                            ITERATE loop_create_part;
            END;
        END CASE;
 
                UPDATE manage_partitions set last_updated = NOW() WHERE tablename = TABLENAME_TMP;
    END LOOP loop_create_part;
 
    CLOSE get_prt_tables;
END$$ 
 
DROP PROCEDURE IF EXISTS `drop_partitions`$$
 
CREATE PROCEDURE `drop_partitions`(IN_SCHEMANAME VARCHAR(64))
BEGIN
    DECLARE TABLENAME_TMP VARCHAR(64);
    DECLARE PARTITIONNAME_TMP VARCHAR(64);
    DECLARE VALUES_LESS_TMP INT;
    DECLARE PERIOD_TMP VARCHAR(12);
    DECLARE KEEP_HISTORY_TMP INT;
    DECLARE KEEP_HISTORY_BEFORE INT;
    DECLARE DONE INT DEFAULT 0;
    DECLARE get_partitions CURSOR FOR
        SELECT p.`table_name`, p.`partition_name`, LTRIM(RTRIM(p.`partition_description`)), mp.`period`, mp.`keep_history`
            FROM information_schema.partitions p
            JOIN manage_partitions mp ON mp.tablename = p.table_name
            WHERE p.table_schema = IN_SCHEMANAME
            ORDER BY p.table_name, p.subpartition_ordinal_position;
 
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
 
    OPEN get_partitions;
 
    loop_check_prt: LOOP
        IF DONE THEN
            LEAVE loop_check_prt;
        END IF;
 
        FETCH get_partitions INTO TABLENAME_TMP, PARTITIONNAME_TMP, VALUES_LESS_TMP, PERIOD_TMP, KEEP_HISTORY_TMP;
        CASE WHEN PERIOD_TMP = 'day' THEN
                SET KEEP_HISTORY_BEFORE = UNIX_TIMESTAMP(DATE(NOW() - INTERVAL KEEP_HISTORY_TMP DAY));
             WHEN PERIOD_TMP = 'month' THEN
                SET KEEP_HISTORY_BEFORE = UNIX_TIMESTAMP(DATE(NOW() - INTERVAL KEEP_HISTORY_TMP MONTH - INTERVAL DAY(NOW())-1 DAY));
             ELSE
            BEGIN
                ITERATE loop_check_prt;
            END;
        END CASE;
 
        IF KEEP_HISTORY_BEFORE >= VALUES_LESS_TMP THEN
                CALL drop_old_partition(IN_SCHEMANAME, TABLENAME_TMP, PARTITIONNAME_TMP);
        END IF;
        END LOOP loop_check_prt;
 
        CLOSE get_partitions;
END$$
 
DROP PROCEDURE IF EXISTS `drop_old_partition`$$
 
CREATE PROCEDURE `drop_old_partition`(IN_SCHEMANAME VARCHAR(64), IN_TABLENAME VARCHAR(64), IN_PARTITIONNAME VARCHAR(64))
BEGIN
    DECLARE ROWS_CNT INT UNSIGNED;
 
        SELECT COUNT(*) INTO ROWS_CNT
                FROM information_schema.partitions
                WHERE table_schema = IN_SCHEMANAME AND table_name = IN_TABLENAME AND partition_name = IN_PARTITIONNAME;
 
    IF ROWS_CNT = 1 THEN
                     SET @SQL = CONCAT( 'ALTER TABLE `', IN_SCHEMANAME, '`.`', IN_TABLENAME, '`',
                                ' DROP PARTITION ', IN_PARTITIONNAME, ';' );
                PREPARE STMT FROM @SQL;
                EXECUTE STMT;
                DEALLOCATE PREPARE STMT;
        ELSE
        SELECT CONCAT("partition `", IN_PARTITIONNAME, "` for table `",IN_SCHEMANAME, ".", IN_TABLENAME, "` not exists") AS result;
        END IF;
END$$
 
CREATE EVENT IF NOT EXISTS `e_part_manage`
       ON SCHEDULE EVERY 1 DAY
       STARTS '%yesterday% 00:00:00'
       ON COMPLETION PRESERVE
       ENABLE
       COMMENT 'Управление созданием и удалением секций'
       DO BEGIN
            CALL %dbName%.drop_partitions('%dbName%');
            CALL %dbName%.create_next_partitions('%dbName%');
       END$$
 
DELIMITER ;
EOSQL
exec 1<&3

sql_ < <(sed "s/%dbName%/$dbName/g; s/%yesterday%/$(date -d yesterday +'%Y-%m-%d')/g" $tmpFile)
rm -f $tmpFile

flForeignKeyChecks=$(mysql -e 'show global variables like "foreign_key_checks%"\G' | sed -nr 's%^\s+Value:\s*(.+)$%\1%p')
[[ $flForeignKeyChecks == 'OFF' ]] || sql_ 'SET GLOBAL foreign_key_checks=OFF;'
sql_ < <($alterPartScript -d $dbName -z $startDate -f $partByField)
[[ $flForeignKeyChecks == 'OFF' ]] || sql_ "SET GLOBAL foreign_key_checks=${flForeignKeyChecks};"

if [[ $flZabbixManage && $rc -eq 0 ]]; then
 ssh ${zbxServer[host]} "sed -ri '/^\s*DBName=/I{ s%^.+$%DBName=$dbName% }' ${zbxServer[config]}; service zabbix-server restart"
 ssh ${zbxFrontend[host]} "sed -ri '/^[^#/]+DATABASE/{ s%^([^=]+=\s*).*$%\1\"${dbName}\"% }' ${zbxFrontend[config]}" 
fi
