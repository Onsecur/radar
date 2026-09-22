-- =====================================================================
-- Radar - ajuste 1
-- La ficha tiene un campo de notas libres que no estaba en el esquema.
-- Ejecutar DESPUES de radar_v3_carga.sql.
-- =====================================================================

alter table radar.oportunidad add column if not exists notas text;

-- La vista se recrea para que la aplicacion pueda leerlo. Hay que borrarla
-- antes: create or replace solo admite columnas nuevas al final, y notas va
-- en medio.
drop view if exists radar.v_oportunidad;

create view radar.v_oportunidad
with (security_invoker = true) as
select
  o.id, o.titulo, o.cliente, o.cuenta_id,
  o.calle, o.poblacion, o.provincia,
  nullif(concat_ws(', ', o.calle, o.poblacion, o.provincia), '') as direccion,
  o.comercial, p.nombre as comercial_nombre,
  o.proyectista, o.tipo, t.nombre as tipo_nombre, t.kpi,
  o.tipo_actuacion, o.tipo_sistema,
  o.vertical, v.nombre as vertical_nombre,
  o.origen, o.prescriptor_id, pr.nombre as prescriptor_nombre,
  o.importe, o.cuota_anual,
  case when radar.es_director() then o.coste  end as coste,
  case when radar.es_director() then o.margen end as margen,
  case when radar.es_director() and o.importe <> 0
       then round(o.margen / o.importe * 100, 2) end as margen_pct,
  o.etapa, e.nombre as etapa_nombre, e.en_prevision,
  o.estado, o.probabilidad,
  round(o.importe * o.probabilidad / 100, 2) as ponderado,
  (o.probabilidad >= (select valor::int from radar.ajuste
                       where clave = 'umbral_compromiso')) as es_compromiso,
  o.cierre_previsto, o.cierre_estimado,
  radar.es_vencida(o.cierre_previsto) as vencida,
  o.fecha_revision, o.cierre_real, o.motivo_perdida,
  o.motivo_exclusion, o.cuenta_resultados,
  o.notas,
  o.ultima_actividad,
  case when o.ultima_actividad is not null
       then (current_date - o.ultima_actividad)
       else greatest(0, current_date
            - coalesce((select valor::date from radar.ajuste where clave='puesta_marcha'),
                       current_date))
  end as dias_sin_actividad,
  (select count(*) from radar.presupuesto b where b.oportunidad_id = o.id)
    as presupuestos,
  o.origen_dato, o.creado_en, o.actualizado_en
from radar.oportunidad o
left join radar.etapa            e  on e.codigo  = o.etapa
left join radar.tipo_oportunidad t  on t.codigo  = o.tipo
left join radar.vertical         v  on v.codigo  = o.vertical
left join radar.prescriptor      pr on pr.id     = o.prescriptor_id
left join radar.perfil           p  on p.tag_comercial = o.comercial
where radar.ve_todo() or o.comercial = radar.tag_actual();

grant select on radar.v_oportunidad to authenticated;

-- Fecha de arranque: desde aqui cuenta el indicador de dias sin actividad
-- para las fichas que nunca se han tocado.
update radar.ajuste set valor = current_date::text where clave = 'puesta_marcha';

select 'notas' as comprobacion,
       count(*) filter (where column_name = 'notas')::text as existe
  from information_schema.columns
 where table_schema = 'radar' and table_name = 'oportunidad';
