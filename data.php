<?php

$db = new PDO("pgsql:host=localhost;dbname=paranormal_map", "postgres", "your_password_here");

$sql = "SELECT jsonb_build_object(

    'type',     'FeatureCollection',

    'features', jsonb_agg(features.feature)

) FROM (

  SELECT jsonb_build_object(

    'type',       'Feature',

    'geometry',   ST_AsGeoJSON(geom)::jsonb,

    'properties', jsonb_build_object('name', name, 'info', info)

  ) AS feature FROM sightings

) AS features";


$rs = $db->query($sql);

echo $rs->fetchColumn();

?>
