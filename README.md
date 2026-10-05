# GM Soluções - CRM de empréstimos

Site estático (um único `index.html`) que usa o Supabase como banco, login e armazenamento.

- `index.html` - o CRM
- `supabase.sql` - estrutura do banco (já aplicada no projeto Supabase)

A chave usada no `index.html` é a *publishable* (pública por design). Quem protege os dados são as regras de segurança (RLS) e a tabela `equipe`.
