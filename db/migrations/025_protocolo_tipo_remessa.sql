-- =====================================================================================
-- 025 — REMESSA DE VENDA À ORDEM NO PROTOCOLO (Silvio 06/11/2026): "devemos incluir no protocolo toda e qualquer nota que
-- represente REALIZAR EXPEDIÇÃO DO PRODUTO — só não em duplicidade (NF-mãe que gera duplicata × nota-filha de remessa)".
-- A rotina passa a gravar a remessa (CFOP 5923/6923) com origem 'REM'. Aqui só o RÓTULO da coluna Tipo nas funções da aba
-- (aptas, notas do protocolo): BON → 'BONIF.', REM → 'REMESSA V.O.', demais → 'VENDA'. Troca feita por texto em TODAS as
-- funções que têm o rótulo antigo (pega a versão em uso de cada uma, sem reescrevê-las). Pode rodar de novo.
-- =====================================================================================
do $$ declare r record; nova text; n int := 0; begin
  for r in select p.oid, p.proname, pg_get_functiondef(p.oid) as d
           from pg_proc p join pg_namespace s on s.oid = p.pronamespace
           where s.nspname = 'public' and p.proname like 'prot\_%'
             and pg_get_functiondef(p.oid) ~ 'then ''BONIF\.'' else ''VENDA'' end'
             and pg_get_functiondef(p.oid) !~ 'REMESSA V\.O\.' loop
    nova := regexp_replace(r.d, 'case when (\w+)\.origem = ''BON'' then ''BONIF\.'' else ''VENDA'' end',
                           'case when \1.origem = ''BON'' then ''BONIF.'' when \1.origem = ''REM'' then ''REMESSA V.O.'' else ''VENDA'' end', 'g');
    execute nova; n := n + 1;
    raise notice 'rótulo REMESSA V.O. em %', r.proname;
  end loop;
  raise notice '% função(ões) atualizada(s)', n;
end $$;

-- conferência: funções do protocolo com o rótulo novo e nenhuma sobrando com o antigo
select (select count(*) from pg_proc where proname like 'prot\_%' and prosrc ~ 'REMESSA V\.O\.') as com_rotulo_novo,
       (select count(*) from pg_proc where proname like 'prot\_%' and prosrc ~ 'then ''BONIF\.'' else ''VENDA'' end') as com_rotulo_antigo;
