begin;

do $$
declare
  v_crypto_schema text;
  v_function record;
  v_updated integer := 0;
begin
  select n.nspname
    into v_crypto_schema
  from pg_catalog.pg_extension e
  join pg_catalog.pg_namespace n on n.oid = e.extnamespace
  where e.extname = 'pgcrypto';

  if v_crypto_schema is null
     or pg_catalog.to_regprocedure(format('%I.crypt(text,text)', v_crypto_schema)) is null
     or not exists (
       select 1
       from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname = v_crypto_schema
         and p.proname = 'gen_salt'
     ) then
    raise exception 'pgcrypto crypt() and gen_salt() were not found in the extension schema';
  end if;

  for v_function in
    select p.oid::pg_catalog.regprocedure as signature
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('create_project', 'update_project_password')
  loop
    execute format(
      'alter function %s set search_path to public, %I, pg_temp',
      v_function.signature,
      v_crypto_schema
    );
    v_updated := v_updated + 1;
  end loop;

  if v_updated = 0 then
    raise exception 'Password creation/update functions were not found in public schema';
  end if;
end;
$$;

commit;
