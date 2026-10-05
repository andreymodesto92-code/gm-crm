-- =====================================================================
-- GM Soluções - CRM de empréstimos
-- Estrutura do banco para o Supabase. Cole tudo no SQL Editor e rode.
-- Pode rodar mais de uma vez sem perder dados.
-- Valores em reais (numeric), datas no formato AAAA-MM-DD.
-- =====================================================================

-- 1) Quem pode usar o CRM. Só entra aqui por este SQL Editor (passo final).
create table if not exists public.equipe (
  user_id   uuid primary key references auth.users (id) on delete cascade,
  criado_em timestamptz not null default now()
);

create or replace function public.eh_equipe()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.equipe where user_id = (select auth.uid()));
$$;

revoke all on function public.eh_equipe() from public, anon;
grant execute on function public.eh_equipe() to authenticated;

-- 2) Tabelas
create table if not exists public.clientes (
  id        uuid primary key default gen_random_uuid(),
  nome      text not null,
  whatsapp  text not null,                 -- só dígitos, com DDD
  cpf       text not null unique,          -- só dígitos
  obs       text not null default '',
  criado_em timestamptz not null default now()
);

create table if not exists public.documentos (
  id         uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references public.clientes (id) on delete cascade,
  tipo       text not null,                -- CNH, RG, CPF, Comprovante, Outro
  caminho    text not null unique,         -- caminho do arquivo no bucket "documentos"
  criado_em  timestamptz not null default now()
);

create table if not exists public.emprestimos (
  id               uuid primary key default gen_random_uuid(),
  cliente_id       uuid not null references public.clientes (id) on delete cascade,
  valor_emprestado numeric(12,2) not null check (valor_emprestado > 0),
  data             date not null default current_date,
  frequencia       text not null check (frequencia in ('semanal', 'mensal')),
  obs              text not null default '',
  criado_em        timestamptz not null default now()
);

-- O valor a receber de um empréstimo é a soma das parcelas dele.
create table if not exists public.parcelas (
  id            uuid primary key default gen_random_uuid(),
  emprestimo_id uuid not null references public.emprestimos (id) on delete cascade,
  numero        integer not null check (numero > 0),
  valor         numeric(12,2) not null check (valor > 0),
  vencimento    date not null,
  pago          boolean not null default false,
  pago_em       date,
  valor_pago    numeric(12,2),             -- valor de fato recebido (com juros, se houver)
  aviso_em      date,                      -- último aviso enviado pelo WhatsApp
  unique (emprestimo_id, numero)
);

create table if not exists public.config (
  id    text primary key,                  -- sempre 'geral'
  dados jsonb not null default '{}'::jsonb -- mensagens, chave Pix, multa e juros
);

create index if not exists documentos_cliente_idx  on public.documentos (cliente_id);
create index if not exists emprestimos_cliente_idx on public.emprestimos (cliente_id);
create index if not exists parcelas_emprestimo_idx on public.parcelas (emprestimo_id);
create index if not exists parcelas_abertas_idx    on public.parcelas (vencimento) where not pago;

-- 3) Segurança: só usuário logado E cadastrado na equipe lê ou grava.
alter table public.equipe      enable row level security;
alter table public.clientes    enable row level security;
alter table public.documentos  enable row level security;
alter table public.emprestimos enable row level security;
alter table public.parcelas    enable row level security;
alter table public.config      enable row level security;

revoke all on public.equipe, public.clientes, public.documentos, public.emprestimos, public.parcelas, public.config from anon;
grant select on public.equipe to authenticated;
grant select, insert, update, delete on public.clientes, public.documentos, public.emprestimos, public.parcelas, public.config to authenticated;

drop policy if exists "equipe ve o proprio registro" on public.equipe;
create policy "equipe ve o proprio registro" on public.equipe
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "equipe gerencia clientes" on public.clientes;
create policy "equipe gerencia clientes" on public.clientes
  for all to authenticated using (public.eh_equipe()) with check (public.eh_equipe());

drop policy if exists "equipe gerencia documentos" on public.documentos;
create policy "equipe gerencia documentos" on public.documentos
  for all to authenticated using (public.eh_equipe()) with check (public.eh_equipe());

drop policy if exists "equipe gerencia emprestimos" on public.emprestimos;
create policy "equipe gerencia emprestimos" on public.emprestimos
  for all to authenticated using (public.eh_equipe()) with check (public.eh_equipe());

drop policy if exists "equipe gerencia parcelas" on public.parcelas;
create policy "equipe gerencia parcelas" on public.parcelas
  for all to authenticated using (public.eh_equipe()) with check (public.eh_equipe());

drop policy if exists "equipe gerencia config" on public.config;
create policy "equipe gerencia config" on public.config
  for all to authenticated using (public.eh_equipe()) with check (public.eh_equipe());

-- 4) Fotos dos documentos: bucket privado, só a equipe acessa.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documentos', 'documentos', false, 20971520, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "gm equipe acessa documentos" on storage.objects;
create policy "gm equipe acessa documentos" on storage.objects
  for all to authenticated
  using (bucket_id = 'documentos' and public.eh_equipe())
  with check (bucket_id = 'documentos' and public.eh_equipe());

-- 5) Visão pronta para automações (n8n): parcelas em aberto com dados do cliente.
--    dias_atraso > 0 = vencida; 0 = vence hoje; negativo = ainda vai vencer.
create or replace view public.parcelas_abertas
with (security_invoker = true) as
select
  p.id                as parcela_id,
  c.id                as cliente_id,
  c.nome,
  c.whatsapp,
  c.cpf,
  e.id                as emprestimo_id,
  e.frequencia,
  p.numero,
  (select count(*) from public.parcelas x where x.emprestimo_id = e.id) as total_parcelas,
  p.valor,
  p.vencimento,
  ((now() at time zone 'America/Sao_Paulo')::date - p.vencimento) as dias_atraso,
  p.aviso_em
from public.parcelas p
join public.emprestimos e on e.id = p.emprestimo_id
join public.clientes c    on c.id = e.cliente_id
where not p.pago;

revoke all on public.parcelas_abertas from anon;
grant select on public.parcelas_abertas to authenticated;

-- 6) LIBERAR O SEU USUÁRIO
--    Antes: crie o usuário em Authentication > Users > Add user (e-mail e senha).
--    Depois: troque o e-mail abaixo pelo dele e rode esta linha.
insert into public.equipe (user_id)
select id from auth.users where email = 'SEU_EMAIL_AQUI'
on conflict (user_id) do nothing;
