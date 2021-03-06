--CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
DROP TABLE if exists uuids cascade;
CREATE TABLE uuids
(
  uuid uuid,
  src character(32),
  row_id integer,
  state smallint default 0
)
WITH (
  OIDS=FALSE
);
--ALTER TABLE uuids OWNER TO postgres;
CREATE UNIQUE INDEX uuid_idx ON uuids (uuid);
CREATE UNIQUE INDEX lookup_idx ON uuids (src,row_id);

DROP TABLE if exists locations;
CREATE TABLE locations
(
  row_id SERIAL,
  location character varying(50)
);
insert into locations (location)  (select admission_location from mimiciii.admissions group by admission_location);
insert into locations (location)  (select discharge_location from mimiciii.admissions group by discharge_location);
insert into locations (location)  (select curr_careunit from mimiciii.transfers group by curr_careunit);
insert into locations (location)  (select curr_service from mimiciii.services group by curr_service);
delete from locations where location is null;

CREATE UNIQUE INDEX location_idx ON locations (location);


DROP TABLE if exists encountertypes;
CREATE TABLE encountertypes
(
  row_id SERIAL,
  encountertype character varying(50)
);
insert into encountertypes (encountertype) (select category from mimiciii.noteevents group by category);
CREATE UNIQUE INDEX encountertype_idx ON encountertypes (encountertype);


DROP TABLE if exists visittypes;
CREATE TABLE visittypes
(
  row_id SERIAL,
  visittype character varying(50)
);
insert into visittypes (visittype) (select admission_type from mimiciii.admissions group by admission_type);
CREATE UNIQUE INDEX visittype_idx ON visittypes (visittype);


-- offset to set events in the past
drop table if exists deltadate;
create table deltadate as select floor(EXTRACT(epoch FROM(min(admissions.admittime)-'2000-01-01'))/(3600*24)) as offset,subject_id from mimiciii.admissions group by subject_id;

-- Process text chart data
--  extract distinct values and items where value is alphabetical 
drop table if exists cetxt_tmp;
create temporary table cetxt_tmp as select value,itemid,count(*) num from mimiciii.chartevents where value ~ '[a-zA-Z]'  and valuenum is null  group by itemid,value order by itemid;

-- Generate concepts
drop table if exists concepts;
CREATE TABLE concepts
(
  row_id SERIAL,
  itemid integer,
  openmrs_id integer,
  shortname character varying(255),
  longname character varying(255),
  description character varying(255),
  icd9_code character varying(10),
  loinc_code character varying(10),
  linksto character varying(50),
  concept_type character varying(50),
  concept_class_id integer,
  concept_datatype_id integer,
  num_records integer default 0,
  min_val double precision,
  avg_val double precision,
  max_val double precision,
  units character varying(50)
);
CREATE UNIQUE INDEX conceptname_idx ON concepts (longname);

-- Generate concepts from d_items table
insert into concepts (itemid,shortname,longname,concept_type,linksto) select itemid,label,concat(label,' [',concept_type,'_',itemid,']'),concat('test_',concept_type),linksto from (select itemid,label,unnest('{text,enum,num,set}'::text[]) concept_type,linksto,dbsource from mimiciii.d_items) c;

-- Generate concepts from d_labitems table
insert into concepts (itemid,shortname,longname,loinc_code,concept_type,linksto) select itemid,label,concat(label,' [',concept_type,'_',itemid,']'),loinc_code,concat('test_',concept_type),'labevents' linksto from (select itemid,label,loinc_code,unnest('{text,num,set}'::text[]) concept_type from mimiciii.d_labitems) c;

-- map distinct values for each chartevents item where avg occurance > 1000 
drop table if exists cetxt_map;
create table cetxt_map as select cetxt_tmp.value,summary.itemid from (select itemid,round(sum(num)/count(*)) density from cetxt_tmp group by itemid order by density) summary left join cetxt_tmp on cetxt_tmp.itemid = summary.itemid where summary.density > 1000 order by itemid,value;
-- add common chartevent text values as concepts
insert into concepts (longname,shortname,concept_type) select concat(value,' [answer]'),value,'answer' from cetxt_map group by value order by value;

-- Process numeric labevents data
-- summarize units
drop table if exists lenum_tmp_1;
create temporary table lenum_tmp_1 as select itemid,valueuom,count(*) from mimiciii.labevents where valuenum is not null group by itemid,valueuom order by itemid;
-- summarize values
drop table if exists lenum_tmp_2;
create temporary table lenum_tmp_2 as select max(valuenum) max_val,min(valuenum) min_val,avg(valuenum) avg_val,itemid,count(*) from mimiciii.labevents where valuenum is not null group by itemid order by itemid,count desc;
-- numeric questions grouped by itemid
drop table if exists lenum;
create table lenum as select lenum_tmp_2.itemid,min_val,avg_val,max_val,unitcounts.valueuom units,lenum_tmp_2.count num from lenum_tmp_2 left join (SELECT (mi).* FROM (SELECT  (SELECT mi FROM lenum_tmp_1 mi WHERE  mi.itemid = m.itemid ORDER BY count DESC LIMIT 1) AS mi FROM  lenum_tmp_1 m GROUP BY itemid) q ORDER BY  (mi).itemid) unitcounts on lenum_tmp_2.itemid = unitcounts.itemid;

-- Process numeric chart data
-- summarize units
drop table if exists cenum_tmp_1;
create temporary table cenum_tmp_1 as select itemid,valueuom,count(*) from mimiciii.chartevents where valuenum is not null group by itemid,valueuom order by itemid;
-- summarize values
drop table if exists cenum_tmp_2;
create temporary table cenum_tmp_2 as select max(valuenum) max_val,min(valuenum) min_val,avg(valuenum) avg_val,itemid,count(*) from mimiciii.chartevents where valuenum is not null group by itemid order by itemid,count desc;
-- numeric questions grouped by itemid
drop table if exists cenum;
create table cenum as select cenum_tmp_2.itemid,min_val,avg_val,max_val,unitcounts.valueuom units,cenum_tmp_2.count num from cenum_tmp_2 left join (SELECT (mi).* FROM (SELECT  (SELECT mi FROM cenum_tmp_1 mi WHERE  mi.itemid = m.itemid ORDER BY count DESC LIMIT 1) AS mi FROM  cenum_tmp_1 m GROUP BY itemid) q ORDER BY  (mi).itemid) unitcounts on cenum_tmp_2.itemid = unitcounts.itemid;

-- diagnoses
insert into concepts (shortname,longname,concept_type) (select diagnosis,concat(diagnosis,' [diagnosis]'),'diagnosis' from mimiciii.admissions group by diagnosis);
-- noteevents categories
insert into concepts (shortname,longname,concept_type) (select category,concat(category,' [note category]'),'category' from mimiciii.noteevents group by category);

-- add numeric concept params
update concepts set min_val = cenum.min_val, max_val = cenum.max_val, avg_val = cenum.avg_val, units = cenum.units from cenum where  concepts.itemid = cenum.itemid and concepts.concept_type = 'test_num';
update concepts set min_val = lenum.min_val, max_val = lenum.max_val, avg_val = lenum.avg_val, units = lenum.units from lenum where  concepts.itemid = lenum.itemid and concepts.concept_type = 'test_num';

--add icd_diagnoses dictionary
insert into concepts (icd9_code,shortname,longname,description,concept_type) select icd9_code,short_title,concat(short_title,' [diagnoses_icd_',icd9_code,']'),long_title,'diagnoses_icd' from mimiciii.d_icd_diagnoses;
insert into concepts (icd9_code,shortname,longname,description,concept_type) select foo.icd9_code,foo.icd9_code,concat('[diagnoses_icd_',foo.icd9_code,']'),foo.icd9_code,'diagnoses_icd' from (select icd9_code,count(*) num from mimiciii.diagnoses_icd group by icd9_code order by num desc) foo left join mimiciii.d_icd_diagnoses on foo.icd9_code = mimiciii.d_icd_diagnoses.icd9_code where row_id is null and foo.icd9_code != '' order by foo.icd9_code;

--add procedure_icds dictionary
insert into concepts (icd9_code,shortname,longname,description,concept_type) select icd9_code,short_title,concat(short_title,' [procedure_icd_',icd9_code,']'),long_title,'procedure_icd' from mimiciii.d_icd_procedures;

-- set class and datatype for concepts
update concepts set concept_class_id = 5, concept_datatype_id = 4 where concept_type  = 'answer';
update concepts set concept_class_id = 4,  concept_datatype_id = 4 where concept_type  = 'diagnosis';
update concepts set concept_class_id = 1,  concept_datatype_id = 1 where concept_type  = 'diagnoses_icd';
update concepts set concept_class_id = 2,  concept_datatype_id = 4 where concept_type  = 'procedure_icd';
update concepts set concept_class_id = 7, concept_datatype_id = 3 where concept_type  = 'category';
update concepts set concept_class_id = 1, concept_datatype_id = 1 where concept_type  = 'test_num';
update concepts set concept_class_id = 1, concept_datatype_id = 2 where concept_type  = 'test_enum';
update concepts set concept_class_id = 1, concept_datatype_id = 3 where concept_type  = 'test_text';
update concepts set concept_class_id = 8, concept_datatype_id = 4 where concept_type  = 'test_set';

-- add numeric concept params
update concepts set min_val = cenum.min_val, max_val = cenum.max_val, avg_val = cenum.avg_val, units = cenum.units from cenum where  concepts.itemid = cenum.itemid and concepts.concept_type = 'test_num';
update concepts set min_val = lenum.min_val, max_val = lenum.max_val, avg_val = lenum.avg_val, units = lenum.units from lenum where  concepts.itemid = lenum.itemid and concepts.concept_type = 'test_num';

update concepts set num_records = num_records + num from  (select itemid,count(*) num from mimiciii.outputevents group by itemid) counts where  concepts.itemid = counts.itemid and concepts.concept_type = 'test_num';
update concepts set num_records = num_records + num from  (select itemid,count(*) num from mimiciii.procedureevents_mv group by itemid) counts where  concepts.itemid = counts.itemid and concepts.concept_type = 'test_num';
update concepts set num_records = num_records + num from  (select itemid,count(*) num from mimiciii.inputevents_cv group by itemid) counts where  concepts.itemid = counts.itemid and concepts.concept_type = 'test_num';
update concepts set num_records = num_records + num from  (select itemid,count(*) num from mimiciii.inputevents_mv group by itemid) counts where  concepts.itemid = counts.itemid and concepts.concept_type = 'test_num';
update concepts set num_records = num_records + num from  (select itemid,count(*) num from mimiciii.chartevents where valuenum is not null group by itemid) counts where concepts.itemid = counts.itemid and concepts.concept_type = 'test_num';
update concepts set num_records = num_records + num from  (select itemid,count(*) num from mimiciii.chartevents where value is not null group by itemid) counts where  concepts.itemid = counts.itemid and concepts.concept_type = 'test_text';
update concepts set num_records = num_records + num from  (select itemid,count(*) num from mimiciii.labevents where valuenum is not null group by itemid) counts where concepts.itemid = counts.itemid and concepts.concept_type = 'test_num';
update concepts set num_records = num_records + num from  (select itemid,count(*) num from mimiciii.labevents where value is not null group by itemid) counts where  concepts.itemid = counts.itemid and concepts.concept_type = 'test_text';
 update concepts set num_records = num_records + num from  (select icd9_code,count(*) num from mimiciii.diagnoses_icd group by icd9_code) counts where  concepts.icd9_code = counts.icd9_code and concepts.concept_type = 'diagnoses_icd';

-- microbiology concepts
create temporary table mb_concepts as select * from concepts limit 0;
-- create concepts for organisms without an itemid
insert into mb_concepts (itemid,shortname,concept_type,num_records)  (select org_itemid,org_name,'ORGANISM',count(*) from mimiciii.microbiologyevents where org_name is not null and org_itemid is null group by org_itemid,org_name);
-- create concepts for specimens without an itemid
insert into mb_concepts (itemid,shortname,concept_type,num_records)  (select spec_itemid,spec_type_desc,'SPECIMEN',count(*) from mimiciii.microbiologyevents where spec_type_desc is not null and spec_itemid is null group by spec_itemid,spec_type_desc);
insert into mb_concepts (itemid,shortname,concept_type) (select itemid,label,category from mimiciii.d_items where linksto = 'microbiologyevents' and label is not null);
update mb_concepts set longname = concat(shortname,' [',concept_type,'_',itemid,']') where itemid is not null;
update mb_concepts set longname = concat(shortname,' [',concept_type,']') where itemid is null;
update mb_concepts set concept_class_id = 1, concept_datatype_id = 3 where concept_type = 'ANTIBACTERIUM';
update mb_concepts set concept_class_id = 1, concept_datatype_id = 3 where concept_type = 'SPECIMEN';
update mb_concepts set concept_class_id = 1, concept_datatype_id = 4 where concept_type = 'ORGANISM';
insert into concepts (itemid,shortname,longname,concept_type,concept_class_id,concept_datatype_id) (select itemid,shortname,longname,concept_type,concept_class_id,concept_datatype_id from mb_concepts);
-- create drug concepts
create temporary table drug_concepts as select drug from mimiciii.prescriptions group by drug;
insert into drug_concepts (drug) (select drug_name_poe from mimiciii.prescriptions group by drug_name_poe);
insert into drug_concepts (drug) (select drug_name_generic from mimiciii.prescriptions group by drug_name_generic);
insert into concepts (shortname,longname,concept_type,concept_class_id,concept_datatype_id) (select drug,concat(drug,' [drug]'),'drug',3,4 from drug_concepts group by drug);

-- cleanup
delete from concepts where shortname is null;
delete from concepts where concept_type = 'test_num' and num_records = 0;
delete from concepts where concept_type = 'test_text' and num_records = 0;
delete from concepts where concept_type = 'diagnoses_icd' and num_records = 0;
delete from concepts where concept_type = 'test_enum' and itemid not in (select itemid from cetxt_map);
-- delete from concepts where concept_type = 'test_enum';
create view visits as select a.*,visittype_uuids.uuid visit_type_uuid,discharge_location_uuids.uuid discharge_location_uuid,admission_location_uuids.uuid admission_location_uuid,patient_uuid,visittypes.row_id visit_type_code from mimiciii.admissions a left join (select uuid patient_uuid,patients.* from mimiciii.patients left join uuids on mimiciii.patients.row_id = uuids.row_id where uuids.src = 'patients') p  on a.subject_id = p.subject_id left join locations admission_locations on a.admission_location = admission_locations.location left join locations discharge_locations on a.discharge_location = discharge_locations.location left join uuids admission_location_uuids on admission_locations.row_id = admission_location_uuids.row_id  and admission_location_uuids.src = 'locations' left join uuids discharge_location_uuids on discharge_locations.row_id = discharge_location_uuids.row_id  and discharge_location_uuids.src = 'locations' left join visittypes on a.admission_type = visittypes.visittype left join uuids visittype_uuids on visittype_uuids.row_id = visittypes.row_id and visittype_uuids.src = 'visittypes' where patient_uuid is not null order by subject_id;
-- Generate process queue
drop table if exists process_queue;
CREATE TABLE process_queue
(
  src character(32),
  row_id integer,
  process_type character varying(50),
  state smallint default 0
);
