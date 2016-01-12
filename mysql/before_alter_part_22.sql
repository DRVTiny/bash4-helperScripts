ALTER TABLE `history_log` DROP PRIMARY KEY, ADD INDEX `history_log_0` (`id`);
ALTER TABLE `history_log` DROP KEY `history_log_2`;
ALTER TABLE `history_text` DROP PRIMARY KEY, ADD INDEX `history_text_0` (`id`);
ALTER TABLE `history_text` DROP KEY `history_text_2`;

CREATE TABLE `manage_partitions` (
  `tablename` VARCHAR(64) NOT NULL COMMENT 'Table name',
  `period` VARCHAR(64) NOT NULL COMMENT 'Period - daily or monthly',
  `keep_history` INT(3) UNSIGNED NOT NULL DEFAULT '1' COMMENT 'For how many days or months to keep the partitions',
  `last_updated` DATETIME DEFAULT NULL COMMENT 'When a partition was added last time',
  `comments` VARCHAR(128) DEFAULT '1' COMMENT 'Comments',
  PRIMARY KEY (`tablename`)
) ENGINE=INNODB;

INSERT INTO manage_partitions (tablename, period, keep_history, last_updated, comments) VALUES ('history', 'day', 30, now(), '');
INSERT INTO manage_partitions (tablename, period, keep_history, last_updated, comments) VALUES ('history_uint', 'day', 30, now(), '');
INSERT INTO manage_partitions (tablename, period, keep_history, last_updated, comments) VALUES ('history_str', 'day', 120, now(), '');
INSERT INTO manage_partitions (tablename, period, keep_history, last_updated, comments) VALUES ('history_text', 'day', 120, now(), '');
INSERT INTO manage_partitions (tablename, period, keep_history, last_updated, comments) VALUES ('history_log', 'day', 120, now(), '');
INSERT INTO manage_partitions (tablename, period, keep_history, last_updated, comments) VALUES ('trends', 'month', 24, now(), '');
INSERT INTO manage_partitions (tablename, period, keep_history, last_updated, comments) VALUES ('trends_uint', 'month', 24, now(), '');
--
-- STOP here if you partition zabbix database starting from 2.2
-- next queries usually used for zabbix database before 2.2
--
INSERT INTO manage_partitions (tablename, period, keep_history, last_updated, comments) VALUES ('acknowledges', 'month', 6, now(), '');
INSERT INTO manage_partitions (tablename, period, keep_history, last_updated, comments) VALUES ('alerts', 'month', 6, now(), '');
INSERT INTO manage_partitions (tablename, period, keep_history, last_updated, comments) VALUES ('auditlog', 'month', 6, now(), '');
INSERT INTO manage_partitions (tablename, period, keep_history, last_updated, comments) VALUES ('events', 'month', 6, now(), '');
INSERT INTO manage_partitions (tablename, period, keep_history, last_updated, comments) VALUES ('service_alarms', 'month', 6, now(), '');
