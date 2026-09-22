-- =====================================================================
-- Radar - esquema v3
-- Onsecur (S.I. Alerta S.L.) - departamento comercial
--
-- Sustituye a radar_v2.sql, que se escribio antes de cerrar las reglas.
-- Cambios respecto a v2, uno por uno:
--   1. Una oportunidad, un comercial. Desaparece oportunidad_comercial
--      y el reparto por porcentaje. Port d'Addaia va integra a Ramon.
--   2. Una oportunidad puede tener VARIOS presupuestos de Beta10.
--      Aparece la tabla presupuesto. En v2 era uno a uno.
--   3. Vertical "Smart" pasa a "Pisos".
--   4. Cinco motivos de perdida, no siete.
--   5. La probabilidad inicial sale de la etapa (10/20/30/10),
--      no de un 20 % plano.
--   6. La direccion se parte en calle, poblacion y provincia.
--   7. Entra el propietario de cuenta, que decide el comercial por
--      encima de lo que diga Beta10 (caso Ramon Palou).
--   8. Entra la cuota anual como campo, no como tipo de oportunidad.
--   9. Entran tipo de oportunidad, tipo de actuacion y tipo de sistema
--      como listas cerradas.
--
-- Ejecutar de una vez en el SQL editor de Supabase. Supabase ya envuelve
-- la ejecucion en su propia transaccion: si algo falla, no queda nada a medias.
-- =====================================================================


create schema if not exists radar;

-- =====================================================================
-- 1. PERSONAS Y ROLES
-- =====================================================================

create table if not exists radar.perfil (
  id            uuid primary key references auth.users(id) on delete cascade,
  nombre        text not null,
  email         text not null unique,
  rol           text not null default 'lectura'
                check (rol in ('director','comercial','lectura')),
  -- tag tal y como se venia usando en Holded: alejandropuig, ramonpalou...
  -- es la clave que une al usuario con oportunidad.comercial
  tag_comercial text unique,
  activo        bool not null default true,
  creado_en     timestamptz not null default now()
);

comment on table radar.perfil is
  'Una fila por persona con acceso. El alta la hace el director tras invitar
   al usuario desde Supabase Auth.';

create or replace function radar.rol_actual() returns text
language sql stable security definer set search_path = radar, public as $$
  select rol from radar.perfil where id = auth.uid() and activo
$$;

create or replace function radar.es_director() returns bool
language sql stable security definer set search_path = radar, public as $$
  select coalesce(radar.rol_actual() = 'director', false)
$$;

create or replace function radar.tag_actual() returns text
language sql stable security definer set search_path = radar, public as $$
  select tag_comercial from radar.perfil where id = auth.uid() and activo
$$;

-- Ve todo: el director y los perfiles de solo lectura.
create or replace function radar.ve_todo() returns bool
language sql stable security definer set search_path = radar, public as $$
  select coalesce(radar.rol_actual() in ('director','lectura'), false)
$$;

-- =====================================================================
-- 2. CATALOGOS
-- =====================================================================

-- --- Etapas del embudo ---------------------------------------------
-- La probabilidad por defecto sale de aqui y es editable por el comercial.
-- Los porcentajes se revisaran con datos reales dentro de dos o tres
-- trimestres.
create table if not exists radar.etapa (
  codigo            text primary key,
  nombre            text not null,
  probabilidad      int  not null check (probabilidad between 0 and 100),
  orden             int  not null,
  -- Stand By no entra en la prevision mensual y no lleva cierre previsto
  en_prevision      bool not null default true,
  pide_revision     bool not null default false,
  activa            bool not null default true
);

insert into radar.etapa (codigo, nombre, probabilidad, orden, en_prevision, pide_revision) values
  ('estudio',     'Estudio',          10, 1, true,  false),
  ('enviada',     'Enviada',          20, 2, true,  false),
  ('standby',     'Stand By',         10, 3, false, true),
  ('negociacion', 'En negociaciones', 30, 4, true,  false),
  ('cerrado',     'Cerrado',         100, 5, false, false)
on conflict (codigo) do nothing;

-- --- Tipo de oportunidad --------------------------------------------
-- Solo Obra cuenta en el resultado comercial. Las averias van a su KPI.
-- Mantenimiento, cambio de titularidad y gestion de cliente van al KPI
-- de Mantenimiento y SAT. Ninguno de los dos entra en objetivos ni en
-- rankings.
create table if not exists radar.tipo_oportunidad (
  codigo    text primary key,
  nombre    text not null,
  kpi       text not null check (kpi in ('comercial','averias','mantenimiento')),
  orden     int  not null,
  activo    bool not null default true
);

insert into radar.tipo_oportunidad (codigo, nombre, kpi, orden) values
  ('obra',        'Obra',                  'comercial',     1),
  ('averia',      'Averia',                'averias',       2),
  ('mantenimiento','Mantenimiento',        'mantenimiento', 3),
  ('titularidad', 'Cambio de titularidad', 'mantenimiento', 4),
  ('gestion',     'Gestion de cliente',    'mantenimiento', 5)
on conflict (codigo) do nothing;

-- --- Tipo de actuacion (viene de Beta10) -----------------------------
-- Mapea al tipo de oportunidad, que es lo que decide el KPI.
create table if not exists radar.tipo_actuacion (
  codigo            text primary key,
  nombre            text not null,
  tipo_oportunidad  text not null references radar.tipo_oportunidad(codigo),
  orden             int  not null,
  activo            bool not null default true
);

insert into radar.tipo_actuacion (codigo, nombre, tipo_oportunidad, orden) values
  ('instalacion',  'Instalacion',           'obra',         1),
  ('ampliacion',   'Ampliacion',            'obra',         2),
  ('averia',       'Averia',                'averia',       3),
  ('revision',     'Revision',              'mantenimiento',4),
  ('titularidad',  'Cambio de titularidad', 'titularidad',  5),
  ('gestion',      'Gestion de cliente',    'gestion',      6)
on conflict (codigo) do nothing;

-- --- Tipo de sistema (viene de Beta10) -------------------------------
create table if not exists radar.tipo_sistema (
  codigo text primary key,
  nombre text not null,
  orden  int  not null,
  activo bool not null default true
);

insert into radar.tipo_sistema (codigo, nombre, orden) values
  ('combinado', 'Combinado',         1),
  ('cctv',      'CCTV',              2),
  ('intrusion', 'Intrusion',         3),
  ('acceso',    'Control de acceso', 4),
  ('fisica',    'Seguridad fisica',  5),
  ('pci',       'PCI',               6),
  ('otros',     'Otros',             7)
on conflict (codigo) do nothing;

-- --- Verticales ------------------------------------------------------
-- Ocho. "Smart" de v2 pasa a "Pisos".
create table if not exists radar.vertical (
  codigo text primary key,
  nombre text not null,
  orden  int  not null,
  activa bool not null default true
);

insert into radar.vertical (codigo, nombre, orden) values
  ('casas',        'Casas',                  1),
  ('pisos',        'Pisos',                  2),
  ('comunidades',  'Comunidades',            3),
  ('industria',    'Industria',              4),
  ('corporativos', 'Edificios corporativos', 5),
  ('retail',       'Retail',                 6),
  ('hoteles',      'Hoteles',                7),
  ('otros',        'Otros',                  8)
on conflict (codigo) do nothing;

-- Traduccion desde los tags del board de Holded. El prefijo s del tag ya
-- viene quitado: sgranresidencial se busca aqui como granresidencial.
create table if not exists radar.vertical_alias (
  alias  text primary key,
  codigo text not null references radar.vertical(codigo)
);

insert into radar.vertical_alias (alias, codigo) values
  ('granresidencial','casas'), ('residencial','casas'), ('casas','casas'),
  ('smart','pisos'), ('pisos','pisos'),
  ('comunidadprime','comunidades'), ('comunidad','comunidades'),
  ('comunidades','comunidades'), ('trastero','comunidades'), ('parking','comunidades'),
  ('industria','industria'), ('pyme','industria'),
  ('oficinas','corporativos'), ('coworking','corporativos'), ('despacho','corporativos'),
  ('retail','retail'), ('tienda','retail'), ('showroom','retail'),
  ('hotel','hoteles'), ('hoteles','hoteles'),
  ('otros','otros'), ('ai','otros'), ('fisica','otros'), ('restauracion','retail')
on conflict (alias) do nothing;

comment on table radar.vertical_alias is
  'Smart se mapea a Pisos. Pendiente de confirmar cuando se revise la
   clasificacion. 28 oportunidades de 2026 no llevan tag y entran sin vertical.';

-- --- Origenes --------------------------------------------------------
-- En Beta10 este campo esta vacio: canal de conocimiento aparece en 14
-- presupuestos de 1.082. Se construye desde cero dentro de Radar.
create table if not exists radar.origen (
  codigo            text primary key,
  nombre            text not null,
  -- Prescriptor y Referido de cliente son los unicos que piden prescriptor
  pide_prescriptor  bool not null default false,
  orden             int  not null,
  activo            bool not null default true
);

insert into radar.origen (codigo, nombre, pide_prescriptor, orden) values
  ('prescriptor', 'Prescriptor',            true,  1),
  ('referido',    'Referido de cliente',    true,  2),
  ('cartera',     'Cartera existente',      false, 3),
  ('captacion',   'Captacion del comercial',false, 4),
  ('web',         'Entrada web',            false, 5),
  ('publicidad',  'Publicidad',             false, 6),
  ('otros',       'Otros',                  false, 7)
on conflict (codigo) do nothing;

-- --- Motivos de perdida ----------------------------------------------
-- Cinco. En v2 habia siete, de una version anterior de las reglas.
create table if not exists radar.motivo_perdida (
  codigo text primary key,
  nombre text not null,
  orden  int  not null,
  activo bool not null default true
);

insert into radar.motivo_perdida (codigo, nombre, orden) values
  ('precio',    'Precio',                1),
  ('plazo',     'Plazo',                 2),
  ('solucion',  'Solucion',              3),
  ('sin_respuesta','No responde',        4),
  ('pospone',   'Pospone la inversion',  5)
on conflict (codigo) do nothing;

-- --- Motivos de exclusion de resultados -------------------------------
-- conmutable = false: exclusiones administrativas que ni el director
-- quita desde la ficha.
create table if not exists radar.motivo_exclusion (
  codigo      text primary key,
  nombre      text not null,
  descripcion text,
  conmutable  bool not null default true,
  activo      bool not null default true
);

insert into radar.motivo_exclusion (codigo, nombre, descripcion, conmutable) values
  ('cuenta_nacional','Cuenta nacional',    'Orona, ICS 360 y similares',               false),
  ('sat',            'SAT / mantenimiento','Avisos de servicio, no comercial',         false),
  ('duplicada',      'Duplicada',          'La misma operacion ya esta en otra ficha', true),
  ('traspaso',       'Traspaso entre ejercicios', null,                                true),
  ('prueba',         'Prueba o formacion', null,                                       true)
on conflict (codigo) do nothing;

-- --- Proyectistas -----------------------------------------------------
-- Los antiguos no son seleccionables, pero se conservan en las 1.037
-- fichas historicas donde ya figuran.
create table if not exists radar.proyectista (
  codigo        text primary key,
  nombre        text not null,
  seleccionable bool not null default true,
  orden         int  not null default 0
);

insert into radar.proyectista (codigo, nombre, seleccionable, orden) values
  ('eloilloveras',    'Eloi Lloveras',       true, 1),
  ('miguelangelmaza', 'Miguel Angel Maza',   true, 2),
  ('raulvera',        'Raul Vera',           true, 3),
  ('alejandropuig',   'Alejandro Puig',      true, 4),
  ('sergiomartinez',  'Sergio Martinez',     true, 5),
  ('ramonpalou',      'Ramon Palou',         true, 6),
  ('jorgemorera',     'Jorge Morera',        true, 7),
  ('miguelangel',     'Miguel Angel Bunuel', true, 8),
  ('gustavocallizo',  'Gustavo Callizo',     true, 9),
  ('jordisimo',       'Jordi Simo',          true,10)
on conflict (codigo) do nothing;

-- --- Tramos para estimar el cierre previsto ---------------------------
-- p75 historico de dias entre emision y aceptacion.
create table if not exists radar.tramo_importe (
  codigo        text primary key,
  importe_desde numeric(14,2) not null,
  importe_hasta numeric(14,2),
  dias          int not null,
  orden         int not null
);

insert into radar.tramo_importe (codigo, importe_desde, importe_hasta, dias, orden) values
  ('<3k',     0,      3000,   15, 1),
  ('3-25k',   3000,   25000,  30, 2),
  ('25-50k',  25000,  50000,  60, 3),
  ('>50k',    50000,  null,  110, 4)
on conflict (codigo) do nothing;

create table if not exists radar.ajuste (
  clave text primary key,
  valor text,
  nota  text
);

insert into radar.ajuste (clave, valor, nota) values
  ('umbral_compromiso', '80',
     'A partir de aqui la oportunidad se considera compromiso'),
  ('dias_estancada',    '14',
     'Dias sin actividad a partir de los cuales la ficha se marca estancada'),
  ('puesta_marcha',     null,
     'Fecha de arranque de Radar. Origen del contador de dias sin actividad'),
  ('revision_standby_inicial', '2026-10-15',
     'Fecha de revision con la que entraron las 240 Stand By de la carga inicial')
on conflict (clave) do nothing;

-- =====================================================================
-- 3. CUENTAS Y PRESCRIPTORES
-- =====================================================================

-- El propietario de cuenta decide el comercial de la oportunidad, por
-- encima del nombre que figure en el presupuesto de Beta10.
-- Ramon Palou no aparece como comercial en Beta10 por decision propia:
-- sus presupuestos salen a nombre de Alejandro Puig y se corrigen aqui.
create table if not exists radar.cuenta (
  id            bigint generated always as identity primary key,
  nombre        text not null,
  cliente_b10   int,
  propietario   text,          -- tag_comercial; manda sobre Beta10
  nif           text,
  creada_en     timestamptz not null default now()
);

create unique index if not exists cuenta_nombre_uniq on radar.cuenta (lower(nombre));
create index if not exists cuenta_propietario_idx on radar.cuenta (propietario);

comment on column radar.cuenta.propietario is
  'Si esta informado, el importador asigna sus oportunidades a este comercial
   aunque Beta10 diga otro. IESE y Sierra Blanca a Ramon, Borges a Alejandro,
   Agefred y Casa Batllo a Gustavo, Kave Home a Miguel Angel.';

-- Equivalencias aprendidas entre el nombre de Beta10 y el de Holded.
create table if not exists radar.cuenta_alias (
  alias     text primary key,
  cuenta_id bigint not null references radar.cuenta(id) on delete cascade
);

comment on table radar.cuenta_alias is
  'Nonika = Promociones Los Jardines de Velazquez, Iurii Sberdlov = Casa
   Platja d Aro, Intelec = C.P. Velazquez 53, Mister Storage = Miquel Guila,
   Sierra Blanca = Suma Ingenieria / Design Hills, Frinvert = Mesura /
   Familia Arenas, Kave Home = Julia Grup Furniture Solutions.';

-- Modulo de prescriptores. La ficha vive aqui; el campo Prescriptor de la
-- oportunidad apunta a esta tabla.
create table if not exists radar.prescriptor (
  id         bigint generated always as identity primary key,
  nombre     text not null,
  tipo       text,          -- arquitecto, instalador, interiorista...
  comercial  text,          -- tag_comercial que lo gestiona
  notas      text,
  activo     bool not null default true,
  creado_en  timestamptz not null default now()
);

create unique index if not exists prescriptor_nombre_uniq on radar.prescriptor (lower(nombre));

create table if not exists radar.prescriptor_contacto (
  id             bigint generated always as identity primary key,
  prescriptor_id bigint not null references radar.prescriptor(id) on delete cascade,
  nombre         text not null,
  cargo          text,
  email          text,
  telefono       text
);

-- =====================================================================
-- 4. OPORTUNIDAD
-- =====================================================================

create table if not exists radar.oportunidad (
  id              bigint generated always as identity primary key,

  -- --- identificacion ---
  titulo          text not null,
  cuenta_id       bigint references radar.cuenta(id),
  cliente         text not null,          -- denormalizado para listados
  calle           text,
  poblacion       text,
  provincia       text,

  -- --- equipo. Una oportunidad, un comercial. ---
  -- Opcional a proposito: hay 21 fichas sin comercial que se iran
  -- asignando a mano. Sin dueno solo las ve direccion.
  comercial       text,                   -- tag_comercial
  proyectista     text references radar.proyectista(codigo),

  -- --- clasificacion ---
  tipo            text not null default 'obra'
                  references radar.tipo_oportunidad(codigo),
  tipo_actuacion  text references radar.tipo_actuacion(codigo),
  tipo_sistema    text references radar.tipo_sistema(codigo),
  vertical        text references radar.vertical(codigo),
  origen          text references radar.origen(codigo),
  prescriptor_id  bigint references radar.prescriptor(id),

  -- --- economico. Manda Beta10 cuando hay presupuesto. ---
  importe         numeric(14,2) not null default 0,   -- sin IVA, con descuento
  cuota_anual     numeric(14,2) not null default 0,   -- recurrente, NUNCA se suma
  coste           numeric(14,2),
  margen          numeric(14,2) generated always as (importe - coste) stored,

  -- --- seguimiento ---
  etapa           text not null default 'estudio' references radar.etapa(codigo),
  estado          text not null default 'abierta'
                  check (estado in ('abierta','ganada','perdida')),
  probabilidad    int  not null default 10
                  check (probabilidad between 0 and 100 and probabilidad % 5 = 0),
  cierre_previsto date,
  cierre_estimado bool not null default false,
  fecha_revision  date,                   -- solo en Stand By
  cierre_real     date,
  motivo_perdida  text references radar.motivo_perdida(codigo),

  -- --- exclusion de resultados ---
  motivo_exclusion  text references radar.motivo_exclusion(codigo),
  cuenta_resultados bool generated always as (motivo_exclusion is null) stored,

  -- --- trazabilidad ---
  origen_dato     text not null default 'radar'
                  check (origen_dato in ('beta10','holded','radar')),
  importacion_id  bigint,
  creado_en       timestamptz not null default now(),
  creado_por      uuid references radar.perfil(id),
  actualizado_en  timestamptz not null default now(),
  ultima_actividad date,

  -- Una cerrada necesita fecha de cierre real.
  constraint cierre_si_cerrada
    check (estado = 'abierta' or cierre_real is not null),
  -- El motivo de perdida solo tiene sentido en una perdida.
  constraint motivo_solo_si_perdida
    check (motivo_perdida is null or estado = 'perdida'),
  -- Stand By entra sin cierre previsto, por regla.
  constraint standby_sin_cierre
    check (etapa <> 'standby' or cierre_previsto is null),
  -- El prescriptor solo se informa si el origen lo pide.
  constraint prescriptor_solo_si_procede
    check (prescriptor_id is null or origen in ('prescriptor','referido'))
);

create index if not exists oportunidad_comercial_idx  on radar.oportunidad (comercial);
create index if not exists oportunidad_etapa_idx      on radar.oportunidad (etapa);
create index if not exists oportunidad_estado_idx     on radar.oportunidad (estado);
create index if not exists oportunidad_cierre_idx     on radar.oportunidad (cierre_real);
create index if not exists oportunidad_previsto_idx   on radar.oportunidad (cierre_previsto);
create index if not exists oportunidad_cuenta_idx     on radar.oportunidad (cuenta_id);
create index if not exists oportunidad_vertical_idx   on radar.oportunidad (vertical);

comment on column radar.oportunidad.importe is
  'Importe del cubo de Beta10, que ya lleva el descuento aplicado. El importe
   neto de la descarga de presupuestos es precio de tarifa y no se usa nunca.';
comment on column radar.oportunidad.cuota_anual is
  'Cuota recurrente anual. Alimenta el indicador de cartera recurrente y no
   entra en el resultado comercial. Las renovaciones no crean oportunidad.';
comment on column radar.oportunidad.cierre_estimado is
  'true = la fecha la calculo el importador desde el tramo de importe. En
   cuanto alguien la edita pasa a false y el importador ya no la toca.';
comment on column radar.oportunidad.probabilidad is
  'La probabilidad la pone el comercial. La de la etapa es solo el valor de
   partida de una ficha nueva. Las heredadas de Holded (40, 80, 95) se
   respetan tal cual, incluidas las Stand By que entran por encima del 10 %.';
comment on column radar.oportunidad.fecha_revision is
  'Solo en Stand By. No es fecha de cierre. Las 240 de la carga inicial
   entraron con revision el 15/10/2026.';
comment on column radar.oportunidad.margen is
  'Sin coste informado se muestra como margen pendiente, en gris.
   Visible solo para direccion.';

-- =====================================================================
-- 5. PRESUPUESTOS DE BETA10
-- =====================================================================
-- Una oportunidad puede tener varios presupuestos. Un presupuesto
-- pertenece a una sola oportunidad. Esto es lo que v2 no contemplaba.

create table if not exists radar.presupuesto (
  id              bigint generated always as identity primary key,
  oportunidad_id  bigint references radar.oportunidad(id) on delete set null,

  numero          text not null,          -- E26/1296, sin version
  version         text,                   -- E26/1296.2
  principal       bool not null default true,

  importe         numeric(14,2) not null default 0,   -- Importe del cubo
  importe_cuotas  numeric(14,2) not null default 0,
  coste           numeric(14,2),

  fecha           date,                   -- fecha del presupuesto
  fecha_aceptacion date,                  -- manda sobre la fecha del presupuesto
  estado          text,                   -- En estudio tecnico, Aceptado...
  estado_facturacion text
                  check (estado_facturacion is null or estado_facturacion in
                        ('aceptado','parcialmente_facturado','totalmente_facturado')),

  cliente_b10     text,
  titulo          text,
  tipo_actuacion  text,
  tipo_sistema    text,
  comercial_b10   text,                   -- lo que dice Beta10, antes de corregir

  visto_en        timestamptz not null default now(),
  desaparecido    bool not null default false,
  importacion_id  bigint
);

create unique index if not exists presupuesto_numero_uniq on radar.presupuesto (numero);
create index if not exists presupuesto_oportunidad_idx on radar.presupuesto (oportunidad_id);

comment on column radar.presupuesto.principal is
  'La columna Principal de Beta10 decide que version cuenta. No es siempre
   la version mas alta.';
comment on column radar.presupuesto.desaparecido is
  'El presupuesto estaba en una descarga anterior y ya no aparece. Pendiente
   de decidir que hace Radar con ellos.';

-- =====================================================================
-- 6. HISTORICO, NOTAS Y ACTIVIDAD
-- =====================================================================
-- Arranca vacio el dia de la puesta en marcha. Los desajustes de la
-- reconciliacion de Holded con Beta10 NO entran aqui: eso es historia
-- reconstruida y vive en el fichero de auditoria de la carga.

create table if not exists radar.cambio (
  id             bigint generated always as identity primary key,
  oportunidad_id bigint not null references radar.oportunidad(id) on delete cascade,
  campo          text not null,
  valor_anterior text,
  valor_nuevo    text,
  autor_id       uuid references radar.perfil(id),
  autor_nombre   text not null,
  importacion_id bigint,
  ocurrido_en    timestamptz not null default now()
);

create index if not exists cambio_oportunidad_idx
  on radar.cambio (oportunidad_id, ocurrido_en desc);

-- Solo los campos que mueven la metrica. Si se graba todo, el historico
-- se llena de ruido y deja de leerse.
create or replace function radar.registra_cambio() returns trigger
language plpgsql security definer set search_path = radar, public as $$
declare
  v_autor text;
  v_campo text;
  v_ant   text;
  v_nue   text;
begin
  select nombre into v_autor from radar.perfil where id = auth.uid();
  v_autor := coalesce(v_autor, 'Importacion Beta10');

  foreach v_campo in array array[
    'importe','cuota_anual','coste','etapa','estado','probabilidad',
    'cierre_previsto','cierre_real','comercial','tipo',
    'motivo_exclusion','motivo_perdida','vertical','origen'
  ] loop
    execute format('select ($1).%I::text, ($2).%I::text', v_campo, v_campo)
      into v_ant, v_nue using old, new;
    if v_ant is distinct from v_nue then
      insert into radar.cambio (oportunidad_id, campo, valor_anterior, valor_nuevo,
                                autor_id, autor_nombre, importacion_id)
      values (new.id, v_campo, v_ant, v_nue, auth.uid(), v_autor, new.importacion_id);
    end if;
  end loop;

  new.actualizado_en := now();
  return new;
end $$;

drop trigger if exists registra_cambio on radar.oportunidad;
create trigger registra_cambio before update on radar.oportunidad
  for each row execute function radar.registra_cambio();

-- Notas y actividad. Inmutables: no se editan ni se borran.
create table if not exists radar.nota (
  id              bigint generated always as identity primary key,
  oportunidad_id  bigint not null references radar.oportunidad(id) on delete cascade,
  tipo            text not null default 'nota'
                  check (tipo in ('llamada','visita','email','nota','propuesta')),
  texto           text not null check (length(trim(texto)) > 0),
  fecha_actividad date not null,
  proxima_accion  date,
  autor_id        uuid references radar.perfil(id),
  autor_nombre    text not null,
  creada_en       timestamptz not null default now()
);

create index if not exists nota_oportunidad_idx
  on radar.nota (oportunidad_id, fecha_actividad desc);
create index if not exists nota_proxima_idx
  on radar.nota (proxima_accion) where proxima_accion is not null;

-- El contador de dias sin actividad se reinicia con la fecha real de la
-- actividad, no con la fecha en que se escribio la nota.
create or replace function radar.toca_actividad() returns trigger
language plpgsql as $$
begin
  update radar.oportunidad
     set ultima_actividad = greatest(coalesce(ultima_actividad, new.fecha_actividad),
                                     new.fecha_actividad)
   where id = new.oportunidad_id;
  return new;
end $$;

drop trigger if exists toca_actividad on radar.nota;
create trigger toca_actividad after insert on radar.nota
  for each row execute function radar.toca_actividad();

-- =====================================================================
-- 7. IMPORTACIONES
-- =====================================================================

create table if not exists radar.importacion (
  id           bigint generated always as identity primary key,
  fichero      text,
  lanzada_en   timestamptz not null default now(),
  lanzada_por  uuid references radar.perfil(id),
  filas_leidas int,
  altas        int,
  actualizadas int,
  para_revisar int,
  nota         text
);

-- Cola de revision: lo que el emparejador no resuelve solo.
-- Es la pantalla que sustituye al Excel de duplicados.
create table if not exists radar.import_revision (
  id             bigint generated always as identity primary key,
  importacion_id bigint not null references radar.importacion(id) on delete cascade,
  tipo           text not null check (tipo in
                  ('posible_duplicado','version_multiple','conflicto_importe',
                   'conflicto_estado','sin_comercial','presupuesto_huerfano',
                   'desaparecido')),
  presupuesto    text,
  oportunidad_id bigint references radar.oportunidad(id) on delete set null,
  candidata_id   bigint references radar.oportunidad(id) on delete set null,
  detalle        text,
  puntuacion     numeric(5,3),
  resuelta       bool not null default false,
  resolucion     text,
  resuelta_por   uuid references radar.perfil(id),
  resuelta_en    timestamptz
);

create index if not exists import_revision_pend_idx
  on radar.import_revision (importacion_id) where not resuelta;

-- =====================================================================
-- 8. OBJETIVOS
-- =====================================================================

create table if not exists radar.objetivo (
  tag_comercial text not null,
  anio          int  not null,
  mes           int  check (mes between 1 and 12),   -- null = objetivo anual
  importe       numeric(14,2) not null,
  primary key (tag_comercial, anio, mes)
);

-- =====================================================================
-- 9. REGLAS DE CALCULO
-- =====================================================================

-- Fecha prevista de cierre para un presupuesto de Beta10 sin fecha.
-- Si la fecha calculada ya ha pasado, se lleva al ultimo dia del mes
-- siguiente.
create or replace function radar.estima_cierre(p_importe numeric, p_fecha date)
returns date language sql stable set search_path = radar, public as $$
  with calc as (
    select (p_fecha + (t.dias || ' days')::interval)::date as f
      from radar.tramo_importe t
     where p_importe >= t.importe_desde
       and (t.importe_hasta is null or p_importe < t.importe_hasta)
     limit 1
  )
  select case when f >= current_date then f
              else (date_trunc('month', current_date)
                    + interval '2 months - 1 day')::date
         end
    from calc
$$;

comment on function radar.estima_cierre is
  'p75 historico entre emision y aceptacion: +15 dias por debajo de 3.000,
   +30 entre 3.000 y 25.000, +60 entre 25.000 y 50.000, +110 por encima.
   Solo se aplica a etapas activas. Stand By entra sin fecha.';

-- Vencida: la fecha prevista cae en un mes anterior al actual, no en un dia
-- anterior. El equipo fecha a fin de mes, asi que el aviso por dia pintaria
-- media cartera en rojo cada dia 1.
create or replace function radar.es_vencida(p_previsto date) returns bool
language sql immutable as $$
  select p_previsto is not null
     and date_trunc('month', p_previsto) < date_trunc('month', current_date)
$$;

-- Al mover a Stand By se limpia el cierre previsto. Al salir de Stand By
-- se limpia la fecha de revision.
create or replace function radar.normaliza_standby() returns trigger
language plpgsql as $$
begin
  if new.etapa = 'standby' then
    new.cierre_previsto := null;
  else
    new.fecha_revision := null;
  end if;
  if new.estado = 'abierta' then
    new.cierre_real := null;
    new.motivo_perdida := null;
  end if;
  return new;
end $$;

drop trigger if exists normaliza_standby on radar.oportunidad;
create trigger normaliza_standby before insert or update on radar.oportunidad
  for each row execute function radar.normaliza_standby();

-- =====================================================================
-- 10. VISTAS
-- =====================================================================
-- Todo el acceso pasa por aqui. Las tablas quedan cerradas por RLS.
-- Cada comercial ve lo suyo; direccion lo ve todo.

create or replace view radar.v_oportunidad
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

-- Resultado comercial del mes. Solo Obra, solo lo que cuenta en resultados.
create or replace view radar.v_resultado
with (security_invoker = true) as
select
  o.comercial,
  extract(year  from o.cierre_real)::int as anio,
  extract(month from o.cierre_real)::int as mes,
  t.kpi,
  count(*)              as operaciones,
  sum(o.importe)        as importe,
  sum(o.cuota_anual)    as cuota_anual
from radar.oportunidad o
join radar.tipo_oportunidad t on t.codigo = o.tipo
where o.estado = 'ganada'
  and o.cuenta_resultados
  and o.cierre_real is not null
  and (radar.ve_todo() or o.comercial = radar.tag_actual())
group by 1,2,3,4;

comment on view radar.v_resultado is
  'Filtrar por kpi = comercial para el resultado del mes. Los KPI averias y
   mantenimiento salen aqui tambien, pero no entran en objetivos ni rankings.';

-- Prevision mensual. Stand By queda fuera por regla: va en bloque aparte.
create or replace view radar.v_prevision
with (security_invoker = true) as
select
  o.comercial,
  date_trunc('month', o.cierre_previsto)::date as mes,
  count(*)                                        as operaciones,
  sum(o.importe)                                  as pipeline,
  sum(o.importe * o.probabilidad / 100)           as ponderado,
  sum(case when o.probabilidad >= 80 then o.importe else 0 end) as compromiso,
  count(*) filter (where radar.es_vencida(o.cierre_previsto)) as vencidas,
  count(*) filter (where o.cierre_estimado)                   as fecha_estimada
from radar.oportunidad o
join radar.etapa e on e.codigo = o.etapa
where o.estado = 'abierta'
  and e.en_prevision
  and o.cuenta_resultados
  and o.cierre_previsto is not null
  and (radar.ve_todo() or o.comercial = radar.tag_actual())
group by 1,2;

-- Bloque de Stand By, sin mes asignado.
create or replace view radar.v_standby
with (security_invoker = true) as
select
  o.comercial,
  count(*)                              as operaciones,
  sum(o.importe)                        as pipeline,
  sum(o.importe * o.probabilidad / 100) as ponderado,
  count(*) filter (where o.fecha_revision <= current_date) as a_revisar
from radar.oportunidad o
where o.estado = 'abierta'
  and o.etapa = 'standby'
  and o.cuenta_resultados
  and (radar.ve_todo() or o.comercial = radar.tag_actual())
group by 1;

-- Cartera recurrente. Separada del resultado comercial, por regla.
create or replace view radar.v_recurrente
with (security_invoker = true) as
select
  o.comercial,
  extract(year from o.cierre_real)::int as anio,
  count(*)           as operaciones,
  sum(o.cuota_anual) as cuota_anual
from radar.oportunidad o
where o.estado = 'ganada'
  and o.cuota_anual > 0
  and (radar.ve_todo() or o.comercial = radar.tag_actual())
group by 1,2;

-- =====================================================================
-- 11. RLS
-- =====================================================================
-- Nadie lee las tablas directamente: se lee por las vistas, que son
-- security_invoker y filtran por rol.

alter table radar.perfil          enable row level security;
alter table radar.oportunidad     enable row level security;
alter table radar.presupuesto     enable row level security;
alter table radar.cuenta          enable row level security;
alter table radar.prescriptor     enable row level security;
alter table radar.nota            enable row level security;
alter table radar.cambio          enable row level security;
alter table radar.importacion     enable row level security;
alter table radar.import_revision enable row level security;
alter table radar.objetivo        enable row level security;

drop policy if exists perfil_propio on radar.perfil;
create policy perfil_propio on radar.perfil
  for select using (id = auth.uid() or radar.es_director());

-- Lectura de las tablas base: la vista filtra, pero RLS tiene que dejar pasar.
drop policy if exists oportunidad_lee on radar.oportunidad;
create policy oportunidad_lee on radar.oportunidad
  for select using (radar.ve_todo() or comercial = radar.tag_actual());
-- Nota: comercial null solo lo alcanza ve_todo(), es decir direccion.

drop policy if exists oportunidad_escribe on radar.oportunidad;
create policy oportunidad_escribe on radar.oportunidad
  for update using (radar.es_director() or comercial = radar.tag_actual());

drop policy if exists oportunidad_alta on radar.oportunidad;
create policy oportunidad_alta on radar.oportunidad
  for insert with check (radar.rol_actual() in ('director','comercial'));

drop policy if exists presupuesto_lee on radar.presupuesto;
create policy presupuesto_lee on radar.presupuesto
  for select using (
    radar.ve_todo()
    or exists (select 1 from radar.oportunidad o
                where o.id = presupuesto.oportunidad_id
                  and o.comercial = radar.tag_actual()));

drop policy if exists cuenta_lee on radar.cuenta;
create policy cuenta_lee on radar.cuenta for select using (auth.uid() is not null);

drop policy if exists prescriptor_lee on radar.prescriptor;
create policy prescriptor_lee on radar.prescriptor for select using (auth.uid() is not null);

drop policy if exists prescriptor_escribe on radar.prescriptor;
create policy prescriptor_escribe on radar.prescriptor
  for all using (radar.rol_actual() in ('director','comercial'))
  with check (radar.rol_actual() in ('director','comercial'));

drop policy if exists nota_lee on radar.nota;
create policy nota_lee on radar.nota
  for select using (
    radar.ve_todo()
    or exists (select 1 from radar.oportunidad o
                where o.id = nota.oportunidad_id
                  and o.comercial = radar.tag_actual()));

-- Las notas no se editan ni se borran.
drop policy if exists nota_alta on radar.nota;
create policy nota_alta on radar.nota
  for insert with check (radar.rol_actual() in ('director','comercial'));

drop policy if exists objetivo_lee on radar.objetivo;
create policy objetivo_lee on radar.objetivo
  for select using (radar.ve_todo() or tag_comercial = radar.tag_actual());

-- Solo direccion cambia la exclusion de resultados. Para el comercial el
-- campo sale con candado.
create or replace function radar.controla_exclusion() returns trigger
language plpgsql security definer set search_path = radar, public as $$
declare v_conmutable bool;
begin
  if new.motivo_exclusion is distinct from old.motivo_exclusion then
    if not radar.es_director() then
      raise exception 'Solo direccion puede cambiar si la oportunidad cuenta en resultados';
    end if;
    select conmutable into v_conmutable from radar.motivo_exclusion
     where codigo = coalesce(old.motivo_exclusion, new.motivo_exclusion);
    if v_conmutable is false and auth.uid() is not null then
      raise exception 'El motivo % es administrativo y no se conmuta desde la ficha',
        coalesce(old.motivo_exclusion, new.motivo_exclusion);
    end if;
  end if;
  return new;
end $$;

drop trigger if exists controla_exclusion on radar.oportunidad;
create trigger controla_exclusion before update on radar.oportunidad
  for each row execute function radar.controla_exclusion();

-- El historico no se toca desde la aplicacion.
revoke insert, update, delete on radar.cambio from authenticated;

-- =====================================================================
-- 12. PERMISOS
-- =====================================================================
-- anon no recibe nada: sin sesion activa, Radar no devuelve una fila.

revoke all on schema radar from anon, public;
revoke all on all tables in schema radar from anon, public;

grant usage on schema radar to authenticated;

grant select on radar.v_oportunidad, radar.v_resultado, radar.v_prevision,
                radar.v_standby, radar.v_recurrente to authenticated;

grant select on radar.etapa, radar.tipo_oportunidad, radar.tipo_actuacion,
                radar.tipo_sistema, radar.vertical, radar.vertical_alias,
                radar.origen, radar.motivo_perdida, radar.motivo_exclusion,
                radar.proyectista, radar.tramo_importe, radar.ajuste,
                radar.perfil, radar.cuenta, radar.cuenta_alias
  to authenticated;

grant select, insert, update on radar.oportunidad to authenticated;
grant select, insert, update on radar.presupuesto to authenticated;
grant select, insert, update on radar.prescriptor, radar.prescriptor_contacto
  to authenticated;
grant select, insert on radar.nota to authenticated;
grant select on radar.cambio, radar.importacion, radar.import_revision,
                radar.objetivo to authenticated;
grant usage on all sequences in schema radar to authenticated;

-- =====================================================================
-- COMPROBACION
-- =====================================================================

select 'tablas' as objeto, count(*) from information_schema.tables where table_schema='radar'
union all select 'vistas',       count(*) from information_schema.views where table_schema='radar'
union all select 'etapas',       count(*) from radar.etapa
union all select 'tipos op.',    count(*) from radar.tipo_oportunidad
union all select 'actuaciones',  count(*) from radar.tipo_actuacion
union all select 'sistemas',     count(*) from radar.tipo_sistema
union all select 'verticales',   count(*) from radar.vertical
union all select 'alias vert.',  count(*) from radar.vertical_alias
union all select 'origenes',     count(*) from radar.origen
union all select 'mot. perdida', count(*) from radar.motivo_perdida
union all select 'mot. exclus.', count(*) from radar.motivo_exclusion
union all select 'proyectistas', count(*) from radar.proyectista
union all select 'tramos',       count(*) from radar.tramo_importe;

