DROP TABLE IF EXISTS `obs_queue`;
CREATE TABLE `obs_queue` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `obs_datetime` datetime NOT NULL,
  `value_numeric` double DEFAULT NULL,
  `value_text` text,
  `observation_uuid` char(38) NOT NULL,
  `concept_uuid` char(38) NOT NULL,
  `patient_uuid` char(38) NOT NULL,
  `encounter_uuid` char(38) NOT NULL,
  `src` char(24) NOT NULL,
  `row_id` int(11) NOT NULL,
   PRIMARY KEY (`id`)
);

