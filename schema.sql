-- ============================================================
-- SISTEMA DE BECAS ESEPA
-- Schema para Supabase (PostgreSQL)
-- ============================================================

-- Extensión para UUIDs
create extension if not exists "uuid-ossp";

-- ============================================================
-- TABLA: perfiles de usuario
-- Se crea automáticamente cuando el usuario se registra en Auth
-- ============================================================
create table public.perfiles (
  id uuid references auth.users(id) on delete cascade primary key,
  rol text not null default 'estudiante' check (rol in ('estudiante', 'admin', 'junta')),
  nombre_completo text not null,
  numero_identificacion text,
  telefono text,
  sexo text check (sexo in ('Hombre', 'Mujer', 'Prefiero no indicar')),
  pais text default 'Costa Rica',
  ciudad text,
  iglesia text,
  nombre_pastor text,
  correo_pastor text,
  ministerio text,
  dedicacion_ministerio text check (dedicacion_ministerio in ('Tiempo Completo', 'Medio Tiempo', 'Cuarto de Tiempo', 'Casual o Servicio')),
  tiene_trabajo_secular boolean default false,
  descripcion_trabajo_secular text,
  programa text,
  cuatrimestre_ingreso text,
  creado_en timestamptz default now(),
  actualizado_en timestamptz default now()
);

-- Trigger para actualizar fecha de modificación
create or replace function public.actualizar_timestamp()
returns trigger as $$
begin
  new.actualizado_en = now();
  return new;
end;
$$ language plpgsql;

create trigger trigger_perfiles_actualizar
  before update on public.perfiles
  for each row execute function public.actualizar_timestamp();

-- ============================================================
-- TABLA: fondos de beca
-- Administrador crea fondos (Providence, Mesa Global, etc.)
-- ============================================================
create table public.fondos_beca (
  id uuid default uuid_generate_v4() primary key,
  nombre text not null,
  descripcion text,
  monto_total numeric(12,2) default 0,
  monto_disponible numeric(12,2) default 0,
  activo boolean default true,
  creado_por uuid references public.perfiles(id),
  creado_en timestamptz default now(),
  actualizado_en timestamptz default now()
);

create trigger trigger_fondos_actualizar
  before update on public.fondos_beca
  for each row execute function public.actualizar_timestamp();

-- Insertar fondos iniciales
insert into public.fondos_beca (nombre, descripcion, monto_total, monto_disponible) values
  ('Fondo General ESEPA', 'Fondo general de becas de la institución', 0, 0),
  ('Beca Providence', 'Fondo proveniente de Providence Church', 0, 0),
  ('Mesa Global', 'Fondo de Mesa Global para formación ministerial', 0, 0),
  ('The Brook Ministries', 'Fondo de The Brook Ministries', 0, 0),
  ('Beca Estudiante Indígena', 'Fondo especial para estudiantes indígenas', 0, 0);

-- ============================================================
-- TABLA: solicitudes de beca
-- ============================================================
create table public.solicitudes (
  id uuid default uuid_generate_v4() primary key,
  estudiante_id uuid references public.perfiles(id) on delete cascade not null,
  periodo text not null, -- ej: "2C 2026"
  tipo_solicitud text not null check (tipo_solicitud in ('primera_vez', 'renovacion')),
  programa text not null,
  cantidad_cursos integer not null default 1,
  motivo text not null,
  estado text not null default 'pendiente' check (estado in ('pendiente', 'en_revision', 'aprobada', 'rechazada', 'aplicada')),
  -- Campos de asignación (los llena el admin)
  fondo_id uuid references public.fondos_beca(id),
  monto_asignado numeric(10,2),
  notas_admin text,
  -- Metadatos
  creado_en timestamptz default now(),
  actualizado_en timestamptz default now()
);

create trigger trigger_solicitudes_actualizar
  before update on public.solicitudes
  for each row execute function public.actualizar_timestamp();

-- ============================================================
-- TABLA: historial de cambios de estado
-- Para trazabilidad completa
-- ============================================================
create table public.historial_estados (
  id uuid default uuid_generate_v4() primary key,
  solicitud_id uuid references public.solicitudes(id) on delete cascade not null,
  estado_anterior text,
  estado_nuevo text not null,
  cambiado_por uuid references public.perfiles(id),
  nota text,
  creado_en timestamptz default now()
);

-- ============================================================
-- TABLA: notificaciones pendientes de envío
-- Edge Function de Supabase las procesa
-- ============================================================
create table public.notificaciones_pendientes (
  id uuid default uuid_generate_v4() primary key,
  solicitud_id uuid references public.solicitudes(id) on delete cascade,
  correo_destino text not null,
  nombre_estudiante text not null,
  estado_nuevo text not null,
  monto_asignado numeric(10,2),
  nombre_fondo text,
  periodo text,
  enviado boolean default false,
  creado_en timestamptz default now()
);

-- ============================================================
-- TRIGGER: registrar cambio de estado automáticamente
-- ============================================================
create or replace function public.registrar_cambio_estado()
returns trigger as $$
begin
  if old.estado is distinct from new.estado then
    insert into public.historial_estados (solicitud_id, estado_anterior, estado_nuevo)
    values (new.id, old.estado, new.estado);

    -- Insertar notificación pendiente
    insert into public.notificaciones_pendientes (
      solicitud_id, correo_destino, nombre_estudiante, estado_nuevo,
      monto_asignado, periodo
    )
    select
      new.id,
      au.email,
      p.nombre_completo,
      new.estado,
      new.monto_asignado,
      new.periodo
    from public.perfiles p
    join auth.users au on au.id = p.id
    where p.id = new.estudiante_id;
  end if;
  return new;
end;
$$ language plpgsql security definer;

create trigger trigger_cambio_estado
  after update on public.solicitudes
  for each row execute function public.registrar_cambio_estado();

-- ============================================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================================

-- Activar RLS en todas las tablas
alter table public.perfiles enable row level security;
alter table public.fondos_beca enable row level security;
alter table public.solicitudes enable row level security;
alter table public.historial_estados enable row level security;
alter table public.notificaciones_pendientes enable row level security;

-- PERFILES: cada usuario ve y edita solo su perfil; admin ve todos
create policy "perfil_propio" on public.perfiles
  for all using (auth.uid() = id);

create policy "admin_ve_perfiles" on public.perfiles
  for select using (
    exists (select 1 from public.perfiles p where p.id = auth.uid() and p.rol in ('admin', 'junta'))
  );

create policy "admin_edita_perfiles" on public.perfiles
  for update using (
    exists (select 1 from public.perfiles p where p.id = auth.uid() and p.rol = 'admin')
  );

-- FONDOS: admin gestiona, junta y estudiantes solo leen nombres activos
create policy "fondos_lectura_publica" on public.fondos_beca
  for select using (activo = true);

create policy "fondos_admin" on public.fondos_beca
  for all using (
    exists (select 1 from public.perfiles p where p.id = auth.uid() and p.rol = 'admin')
  );

-- SOLICITUDES: estudiante ve las suyas; admin ve todas
create policy "solicitud_propia" on public.solicitudes
  for select using (auth.uid() = estudiante_id);

create policy "solicitud_crear" on public.solicitudes
  for insert with check (auth.uid() = estudiante_id);

create policy "admin_solicitudes" on public.solicitudes
  for all using (
    exists (select 1 from public.perfiles p where p.id = auth.uid() and p.rol in ('admin', 'junta'))
  );

-- HISTORIAL: estudiante ve el de sus solicitudes; admin ve todo
create policy "historial_propio" on public.historial_estados
  for select using (
    exists (
      select 1 from public.solicitudes s
      where s.id = solicitud_id and s.estudiante_id = auth.uid()
    )
  );

create policy "admin_historial" on public.historial_estados
  for select using (
    exists (select 1 from public.perfiles p where p.id = auth.uid() and p.rol in ('admin', 'junta'))
  );

-- ============================================================
-- FUNCIÓN: resumen por fondo (para reportes de Junta)
-- ============================================================
create or replace function public.resumen_fondos()
returns table (
  fondo_nombre text,
  total_asignado numeric,
  total_aplicado numeric,
  cantidad_beneficiarios bigint
) as $$
  select
    f.nombre,
    coalesce(sum(s.monto_asignado) filter (where s.estado in ('aprobada','aplicada')), 0) as total_asignado,
    coalesce(sum(s.monto_asignado) filter (where s.estado = 'aplicada'), 0) as total_aplicado,
    count(distinct s.estudiante_id) filter (where s.estado in ('aprobada','aplicada')) as cantidad_beneficiarios
  from public.fondos_beca f
  left join public.solicitudes s on s.fondo_id = f.id
  group by f.nombre
  order by total_asignado desc;
$$ language sql security definer;

-- ============================================================
-- FUNCIÓN: crear perfil al registrarse
-- ============================================================
create or replace function public.crear_perfil_nuevo_usuario()
returns trigger as $$
begin
  insert into public.perfiles (id, nombre_completo, rol)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nombre_completo', 'Sin nombre'),
    coalesce(new.raw_user_meta_data->>'rol', 'estudiante')
  );
  return new;
end;
$$ language plpgsql security definer;

create trigger trigger_nuevo_usuario
  after insert on auth.users
  for each row execute function public.crear_perfil_nuevo_usuario();

-- ============================================================
-- VISTA: panel admin con datos completos de solicitudes
-- ============================================================
create or replace view public.vista_solicitudes_admin as
select
  s.id,
  s.periodo,
  s.tipo_solicitud,
  s.programa,
  s.cantidad_cursos,
  s.motivo,
  s.estado,
  s.monto_asignado,
  s.notas_admin,
  s.creado_en,
  p.nombre_completo,
  p.numero_identificacion,
  p.telefono,
  p.iglesia,
  p.nombre_pastor,
  p.ministerio,
  p.dedicacion_ministerio,
  p.tiene_trabajo_secular,
  p.descripcion_trabajo_secular,
  p.pais,
  p.ciudad,
  au.email,
  f.nombre as nombre_fondo
from public.solicitudes s
join public.perfiles p on p.id = s.estudiante_id
join auth.users au on au.id = s.estudiante_id
left join public.fondos_beca f on f.id = s.fondo_id;

-- Dar acceso a la vista solo a admin/junta
create policy "vista_admin_acceso" on public.solicitudes
  for select using (
    exists (select 1 from public.perfiles p where p.id = auth.uid() and p.rol in ('admin','junta'))
  );
