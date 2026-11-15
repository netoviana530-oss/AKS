-- ===== PONTO AKS — banco de dados (Supabase / PostgreSQL) =====
-- Cole este texto inteiro em Supabase > SQL Editor > Run. Pode rodar de novo sem perder dados.
-- A SENHA DA GESTORA vai na linha "insert into ponto_config" abaixo (troque TROQUE_A_SENHA pela senha escolhida).

create table if not exists ponto_config(k text primary key, v text not null);
insert into ponto_config(k,v) values ('admin','TROQUE_A_SENHA') on conflict (k) do update set v=excluded.v;

create table if not exists ponto_pessoas(
  id uuid primary key default gen_random_uuid(),
  token text unique not null,
  nome text not null,
  cpf text not null default '',
  tipo text not null default 'terceirizado',
  funcao text not null default '',
  h_ent text not null default '08:00',
  h_alm text not null default '12:00',
  h_vol text not null default '13:00',
  h_sai text not null default '18:00',
  ativo boolean not null default true,
  criado timestamptz not null default now());

create table if not exists ponto_marcacoes(
  id uuid primary key default gen_random_uuid(),
  pessoa_id uuid not null references ponto_pessoas(id) on delete cascade,
  tipo text not null check (tipo in ('entrada','saida_almoco','volta_almoco','saida','extra_ini','extra_fim')),
  ts timestamptz not null,
  lat double precision, lon double precision, prec double precision,
  foto text,
  origem text not null default 'app',
  obs text not null default '',
  recebido timestamptz not null default now(),
  unique (pessoa_id, ts, tipo));
create index if not exists ponto_marc_idx on ponto_marcacoes(pessoa_id, ts);

-- Ninguém acessa as tabelas direto: só pelas funções abaixo.
alter table ponto_config enable row level security;
alter table ponto_pessoas enable row level security;
alter table ponto_marcacoes enable row level security;
revoke all on ponto_config, ponto_pessoas, ponto_marcacoes from anon, authenticated;

create or replace function ponto_chk(p_admin text) returns void language plpgsql security definer set search_path=public as $$
begin
  if p_admin is null or p_admin is distinct from (select v from ponto_config where k='admin') then
    raise exception 'acesso negado' using errcode='28000';
  end if;
end $$;

/* ---------- funções da equipe (usam o código pessoal) ---------- */
create or replace function ponto_cfg(p_token text) returns json language plpgsql security definer set search_path=public as $$
declare r ponto_pessoas;
begin
  select * into r from ponto_pessoas where token=p_token and ativo;
  if not found then raise exception 'código inválido' using errcode='28000'; end if;
  return json_build_object('nome',r.nome,'tipo',r.tipo,'funcao',r.funcao,'h_ent',r.h_ent,'h_alm',r.h_alm,'h_vol',r.h_vol,'h_sai',r.h_sai);
end $$;

create or replace function ponto_bater(p_token text,p_tipo text,p_ts timestamptz,p_lat double precision,p_lon double precision,p_prec double precision,p_foto text) returns json language plpgsql security definer set search_path=public as $$
declare r ponto_pessoas;
begin
  select * into r from ponto_pessoas where token=p_token and ativo;
  if not found then raise exception 'código inválido' using errcode='28000'; end if;
  if p_ts > now() + interval '10 minutes' then raise exception 'horário inválido'; end if;
  if p_foto is not null and length(p_foto) > 250000 then raise exception 'foto grande demais'; end if;
  insert into ponto_marcacoes(pessoa_id,tipo,ts,lat,lon,prec,foto) values (r.id,p_tipo,p_ts,p_lat,p_lon,p_prec,p_foto) on conflict (pessoa_id,ts,tipo) do nothing;
  return json_build_object('ok',true);
end $$;

create or replace function ponto_hoje(p_token text,p_desde timestamptz) returns json language plpgsql security definer set search_path=public as $$
declare r ponto_pessoas;
begin
  select * into r from ponto_pessoas where token=p_token and ativo;
  if not found then raise exception 'código inválido' using errcode='28000'; end if;
  return coalesce((select json_agg(json_build_object('tipo',tipo,'ts',ts) order by ts) from ponto_marcacoes where pessoa_id=r.id and ts>=p_desde),'[]'::json);
end $$;

/* ---------- funções da gestora (usam a senha) ---------- */
create or replace function ponto_a_pessoas(p_admin text) returns json language plpgsql security definer set search_path=public as $$
begin
  perform ponto_chk(p_admin);
  return coalesce((select json_agg(row_to_json(p) order by p.nome) from ponto_pessoas p),'[]'::json);
end $$;

create or replace function ponto_a_salvar(p_admin text,p_id uuid,p_dados json) returns json language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  perform ponto_chk(p_admin);
  if p_id is null then
    insert into ponto_pessoas(token,nome,cpf,tipo,funcao,h_ent,h_alm,h_vol,h_sai)
    values (p_dados->>'token',p_dados->>'nome',coalesce(p_dados->>'cpf',''),coalesce(p_dados->>'tipo','terceirizado'),coalesce(p_dados->>'funcao',''),coalesce(p_dados->>'h_ent','08:00'),coalesce(p_dados->>'h_alm','12:00'),coalesce(p_dados->>'h_vol','13:00'),coalesce(p_dados->>'h_sai','18:00'))
    returning id into v_id;
  else
    update ponto_pessoas set nome=coalesce(p_dados->>'nome',nome),cpf=coalesce(p_dados->>'cpf',cpf),tipo=coalesce(p_dados->>'tipo',tipo),funcao=coalesce(p_dados->>'funcao',funcao),
      h_ent=coalesce(p_dados->>'h_ent',h_ent),h_alm=coalesce(p_dados->>'h_alm',h_alm),h_vol=coalesce(p_dados->>'h_vol',h_vol),h_sai=coalesce(p_dados->>'h_sai',h_sai),
      ativo=coalesce((p_dados->>'ativo')::boolean,ativo) where id=p_id returning id into v_id;
  end if;
  return json_build_object('id',v_id);
end $$;

create or replace function ponto_a_marcacoes(p_admin text,p_pessoa uuid,p_ini timestamptz,p_fim timestamptz) returns json language plpgsql security definer set search_path=public as $$
begin
  perform ponto_chk(p_admin);
  return coalesce((select json_agg(json_build_object('id',id,'tipo',tipo,'ts',ts,'lat',lat,'lon',lon,'prec',prec,'origem',origem,'obs',obs,'tem_foto',foto is not null) order by ts)
    from ponto_marcacoes where pessoa_id=p_pessoa and ts>=p_ini and ts<p_fim),'[]'::json);
end $$;

create or replace function ponto_a_foto(p_admin text,p_id uuid) returns text language plpgsql security definer set search_path=public as $$
begin
  perform ponto_chk(p_admin);
  return (select foto from ponto_marcacoes where id=p_id);
end $$;

create or replace function ponto_a_add(p_admin text,p_pessoa uuid,p_tipo text,p_ts timestamptz,p_obs text) returns json language plpgsql security definer set search_path=public as $$
begin
  perform ponto_chk(p_admin);
  insert into ponto_marcacoes(pessoa_id,tipo,ts,origem,obs) values (p_pessoa,p_tipo,p_ts,'manual',coalesce(p_obs,'')) on conflict (pessoa_id,ts,tipo) do nothing;
  return json_build_object('ok',true);
end $$;

create or replace function ponto_a_del(p_admin text,p_id uuid) returns json language plpgsql security definer set search_path=public as $$
begin
  perform ponto_chk(p_admin);
  delete from ponto_marcacoes where id=p_id;
  return json_build_object('ok',true);
end $$;

grant execute on function ponto_cfg(text), ponto_bater(text,text,timestamptz,double precision,double precision,double precision,text), ponto_hoje(text,timestamptz),
  ponto_a_pessoas(text), ponto_a_salvar(text,uuid,json), ponto_a_marcacoes(text,uuid,timestamptz,timestamptz), ponto_a_foto(text,uuid), ponto_a_add(text,uuid,text,timestamptz,text), ponto_a_del(text,uuid) to anon, authenticated;
-- ===== Parte 2: cancelamento de marcações (só a diretoria cancela; a equipe pede) =====
alter table ponto_marcacoes add column if not exists cancelada boolean not null default false;
alter table ponto_marcacoes add column if not exists cancel_motivo text not null default '';
alter table ponto_marcacoes add column if not exists cancel_em timestamptz;
alter table ponto_marcacoes add column if not exists pedido_cancel text;
alter table ponto_marcacoes add column if not exists pedido_em timestamptz;

create or replace function ponto_hoje(p_token text,p_desde timestamptz) returns json language plpgsql security definer set search_path=public as $$
declare r ponto_pessoas;
begin
  select * into r from ponto_pessoas where token=p_token and ativo;
  if not found then raise exception 'código inválido' using errcode='28000'; end if;
  return coalesce((select json_agg(json_build_object('tipo',tipo,'ts',ts,'cancelada',cancelada,'pedido',pedido_cancel is not null) order by ts) from ponto_marcacoes where pessoa_id=r.id and ts>=p_desde),'[]'::json);
end $$;

create or replace function ponto_a_marcacoes(p_admin text,p_pessoa uuid,p_ini timestamptz,p_fim timestamptz) returns json language plpgsql security definer set search_path=public as $$
begin
  perform ponto_chk(p_admin);
  return coalesce((select json_agg(json_build_object('id',id,'tipo',tipo,'ts',ts,'lat',lat,'lon',lon,'prec',prec,'origem',origem,'obs',obs,'tem_foto',foto is not null,'cancelada',cancelada,'cancel_motivo',cancel_motivo,'pedido_cancel',pedido_cancel) order by ts)
    from ponto_marcacoes where pessoa_id=p_pessoa and ts>=p_ini and ts<p_fim),'[]'::json);
end $$;

create or replace function ponto_pedir_cancel(p_token text,p_tipo text,p_ts timestamptz,p_motivo text) returns json language plpgsql security definer set search_path=public as $$
declare r ponto_pessoas; n int;
begin
  select * into r from ponto_pessoas where token=p_token and ativo;
  if not found then raise exception 'código inválido' using errcode='28000'; end if;
  if length(trim(coalesce(p_motivo,''))) < 3 then raise exception 'explique o motivo'; end if;
  update ponto_marcacoes set pedido_cancel=left(trim(p_motivo),300), pedido_em=now()
   where pessoa_id=r.id and tipo=p_tipo and abs(extract(epoch from (ts-p_ts)))<1 and not cancelada;
  get diagnostics n = row_count;
  if n=0 then raise exception 'marcação não encontrada'; end if;
  return json_build_object('ok',true);
end $$;

create or replace function ponto_a_cancelar(p_admin text,p_id uuid,p_motivo text) returns json language plpgsql security definer set search_path=public as $$
begin
  perform ponto_chk(p_admin);
  update ponto_marcacoes set cancelada=true, cancel_motivo=left(coalesce(p_motivo,''),300), cancel_em=now() where id=p_id;
  return json_build_object('ok',true);
end $$;

create or replace function ponto_a_restaurar(p_admin text,p_id uuid) returns json language plpgsql security definer set search_path=public as $$
begin
  perform ponto_chk(p_admin);
  update ponto_marcacoes set cancelada=false, cancel_motivo='', cancel_em=null, pedido_cancel=null, pedido_em=null where id=p_id;
  return json_build_object('ok',true);
end $$;

create or replace function ponto_a_recusar(p_admin text,p_id uuid) returns json language plpgsql security definer set search_path=public as $$
begin
  perform ponto_chk(p_admin);
  update ponto_marcacoes set pedido_cancel=null, pedido_em=null where id=p_id;
  return json_build_object('ok',true);
end $$;

create or replace function ponto_a_pedidos(p_admin text) returns json language plpgsql security definer set search_path=public as $$
begin
  perform ponto_chk(p_admin);
  return coalesce((select json_agg(json_build_object('id',m.id,'nome',p.nome,'pessoa_id',p.id,'tipo',m.tipo,'ts',m.ts,'motivo',m.pedido_cancel,'pedido_em',m.pedido_em) order by m.pedido_em)
    from ponto_marcacoes m join ponto_pessoas p on p.id=m.pessoa_id where m.pedido_cancel is not null and not m.cancelada),'[]'::json);
end $$;

grant execute on function ponto_hoje(text,timestamptz), ponto_a_marcacoes(text,uuid,timestamptz,timestamptz), ponto_pedir_cancel(text,text,timestamptz,text),
  ponto_a_cancelar(text,uuid,text), ponto_a_restaurar(text,uuid), ponto_a_recusar(text,uuid), ponto_a_pedidos(text) to anon, authenticated;
-- ===== Parte 3: pedido de correção com o horário certo =====
alter table ponto_marcacoes add column if not exists pedido_tipo text;
alter table ponto_marcacoes add column if not exists pedido_ts timestamptz;
alter table ponto_marcacoes add column if not exists corr_id uuid;

drop function if exists ponto_pedir_cancel(text,text,timestamptz,text);
create or replace function ponto_pedir_cancel(p_token text,p_tipo text,p_ts timestamptz,p_motivo text,p_novo_tipo text default null,p_novo_ts timestamptz default null) returns json language plpgsql security definer set search_path=public as $$
declare r ponto_pessoas; n int;
begin
  select * into r from ponto_pessoas where token=p_token and ativo;
  if not found then raise exception 'código inválido' using errcode='28000'; end if;
  if length(trim(coalesce(p_motivo,''))) < 3 then raise exception 'explique o motivo'; end if;
  if p_novo_ts is not null then
    if p_novo_tipo is null or p_novo_tipo not in ('entrada','saida_almoco','volta_almoco','saida','extra_ini','extra_fim') then raise exception 'tipo inválido'; end if;
    if p_novo_ts > now() + interval '10 minutes' then raise exception 'horário inválido'; end if;
    if p_novo_ts < now() - interval '3 days' then raise exception 'horário muito antigo: peça à diretoria'; end if;
  end if;
  update ponto_marcacoes set pedido_cancel=left(trim(p_motivo),300), pedido_em=now(), pedido_tipo=case when p_novo_ts is null then null else p_novo_tipo end, pedido_ts=p_novo_ts
   where pessoa_id=r.id and tipo=p_tipo and abs(extract(epoch from (ts-p_ts)))<1 and not cancelada;
  get diagnostics n = row_count;
  if n=0 then raise exception 'marcação não encontrada'; end if;
  return json_build_object('ok',true);
end $$;

create or replace function ponto_hoje(p_token text,p_desde timestamptz) returns json language plpgsql security definer set search_path=public as $$
declare r ponto_pessoas;
begin
  select * into r from ponto_pessoas where token=p_token and ativo;
  if not found then raise exception 'código inválido' using errcode='28000'; end if;
  return coalesce((select json_agg(json_build_object('tipo',tipo,'ts',ts,'cancelada',cancelada,'pedido',pedido_cancel is not null,'novo_tipo',pedido_tipo,'novo_ts',pedido_ts) order by ts) from ponto_marcacoes where pessoa_id=r.id and ts>=p_desde),'[]'::json);
end $$;

create or replace function ponto_a_marcacoes(p_admin text,p_pessoa uuid,p_ini timestamptz,p_fim timestamptz) returns json language plpgsql security definer set search_path=public as $$
begin
  perform ponto_chk(p_admin);
  return coalesce((select json_agg(json_build_object('id',id,'tipo',tipo,'ts',ts,'lat',lat,'lon',lon,'prec',prec,'origem',origem,'obs',obs,'tem_foto',foto is not null,'cancelada',cancelada,'cancel_motivo',cancel_motivo,'pedido_cancel',pedido_cancel,'novo_tipo',pedido_tipo,'novo_ts',pedido_ts) order by ts)
    from ponto_marcacoes where pessoa_id=p_pessoa and ts>=p_ini and ts<p_fim),'[]'::json);
end $$;

create or replace function ponto_a_pedidos(p_admin text) returns json language plpgsql security definer set search_path=public as $$
begin
  perform ponto_chk(p_admin);
  return coalesce((select json_agg(json_build_object('id',m.id,'nome',p.nome,'pessoa_id',p.id,'tipo',m.tipo,'ts',m.ts,'motivo',m.pedido_cancel,'pedido_em',m.pedido_em,'novo_tipo',m.pedido_tipo,'novo_ts',m.pedido_ts) order by m.pedido_em)
    from ponto_marcacoes m join ponto_pessoas p on p.id=m.pessoa_id where m.pedido_cancel is not null and not m.cancelada),'[]'::json);
end $$;

create or replace function ponto_a_cancelar(p_admin text,p_id uuid,p_motivo text) returns json language plpgsql security definer set search_path=public as $$
declare m ponto_marcacoes; nid uuid;
begin
  perform ponto_chk(p_admin);
  update ponto_marcacoes set cancelada=true, cancel_motivo=left(coalesce(p_motivo,''),300), cancel_em=now() where id=p_id and not cancelada returning * into m;
  if found and m.pedido_ts is not null and m.pedido_tipo is not null then
    insert into ponto_marcacoes(pessoa_id,tipo,ts,origem,obs) values (m.pessoa_id,m.pedido_tipo,m.pedido_ts,'manual','Corrigido a pedido da pessoa') on conflict (pessoa_id,ts,tipo) do nothing returning id into nid;
    if nid is null then select id into nid from ponto_marcacoes where pessoa_id=m.pessoa_id and tipo=m.pedido_tipo and ts=m.pedido_ts; end if;
    update ponto_marcacoes set corr_id=nid where id=p_id;
  end if;
  return json_build_object('ok',true);
end $$;

create or replace function ponto_a_restaurar(p_admin text,p_id uuid) returns json language plpgsql security definer set search_path=public as $$
declare c uuid;
begin
  perform ponto_chk(p_admin);
  select corr_id into c from ponto_marcacoes where id=p_id;
  if c is not null then delete from ponto_marcacoes where id=c and origem='manual'; end if;
  update ponto_marcacoes set cancelada=false, cancel_motivo='', cancel_em=null, pedido_cancel=null, pedido_em=null, pedido_tipo=null, pedido_ts=null, corr_id=null where id=p_id;
  return json_build_object('ok',true);
end $$;

create or replace function ponto_a_recusar(p_admin text,p_id uuid) returns json language plpgsql security definer set search_path=public as $$
begin
  perform ponto_chk(p_admin);
  update ponto_marcacoes set pedido_cancel=null, pedido_em=null, pedido_tipo=null, pedido_ts=null where id=p_id;
  return json_build_object('ok',true);
end $$;

grant execute on function ponto_pedir_cancel(text,text,timestamptz,text,text,timestamptz), ponto_hoje(text,timestamptz), ponto_a_marcacoes(text,uuid,timestamptz,timestamptz),
  ponto_a_pedidos(text), ponto_a_cancelar(text,uuid,text), ponto_a_restaurar(text,uuid), ponto_a_recusar(text,uuid) to anon, authenticated;
