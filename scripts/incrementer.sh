num_records=379236162;
chunksize=10000000
iterations=$(($num_records/$chunksize))
iterations=$(($iterations + 1))
echo $iterations
for ((i==1; i<=$iterations; i++))
do
 min=$(( i * $chunksize))
 max=$(( (i + 1) * $chunksize))
 echo "insert  into obs (obs_datetime,value_numeric,value_text,uuid,concept_id,person_id,encounter_id,creator,date_created) select obs_queue.obs_datetime,obs_queue.value_numeric,obs_queue.value_text,obs_queue.observation_uuid,concept.concept_id,person.person_id,encounter.encounter_id,'1',now() from obs_queue left join concept on obs_queue.concept_uuid = concept.uuid left join person on obs_queue.patient_uuid = person.uuid  left join encounter on encounter.uuid = obs_queue.encounter_uuid where id > $min and id <= $max;"
done
