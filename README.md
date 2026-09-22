# Radar

Seguimiento de oportunidades del departamento comercial de Onsecur.
Sustituye a Holded como capa de seguimiento. Beta10 sigue siendo la
fuente de la verdad de los importes.

## Cómo está montado

Una sola página estática. Sin compilación, sin `node_modules`.
Los datos viven en Supabase y el navegador habla directamente con él.
Quien decide qué puede ver y tocar cada persona es el RLS de la base,
no esta página.

- `index.html` — la aplicación entera
- `sql/` — esquema y carga inicial, en el orden en que se ejecutan

## Desplegar

Vercel detecta que es estático y no hay nada que configurar.
La URL y la clave pública de Supabase van dentro de `index.html`: la
clave `publishable` es pública por diseño y no da acceso a nada por sí
sola.

## Dar de alta a alguien

1. Supabase → Authentication → Users → invitar por correo.
2. Crear su ficha:

```sql
insert into radar.perfil (id, nombre, email, rol, tag_comercial)
select id, 'Nombre Apellido', email, 'comercial', 'tagcomercial'
  from auth.users where email = 'correo@onsecur.es';
```

El `tag_comercial` es el que aparece en `oportunidad.comercial`. Sin él,
la persona no verá ninguna oportunidad como propia.
