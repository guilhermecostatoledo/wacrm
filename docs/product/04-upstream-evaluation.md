# Avaliação do upstream 0.8.1

## Referências

- Baseline atual: `077993266400a2ac6be58843324c8d8c87b03d3a`
- Upstream avaliado: `3180f06da6eaa73d84b09b99ea30b01e78db62f5`
- Diferença: 125 commits
- Branch isolada: `integration/upstream-0.8.1-evaluation`

## Conclusão executiva

A atualização é tecnicamente recomendável como ponto de partida, mas não deve ser promovida diretamente à `main`.

O upstream contém correções relevantes de integridade, segurança, WhatsApp e testes. Entretanto, traz também módulos de IA, internacionalização parcial e MCP que não resolvem o objetivo principal do CRM e aumentam o escopo operacional.

A versão mais recente também mantém riscos estruturais já identificados:

- hard delete de contatos na interface;
- fechamento comercial inferido visualmente pela etapa `Won`;
- ausência de Lead e Task;
- autorização baseada em quatro papéis lineares;
- lista de rotas privadas incompleta no middleware.

## Matriz de classificação

| Tema | Mudanças observadas | Classificação | Justificativa |
|---|---|---|---|
| RLS e contas | correções pós-migração 017, ajustes de membership/profile | Incorporar | reduz risco de isolamento e inconsistência |
| Deduplicação de conversas | migration 036 e resolver transacional/único | Incorporar | evita múltiplas threads para o mesmo contato |
| Notificações | migration 027, página e hooks | Incorporar com revisão | útil para tarefas/SLA, mas modelo atual deve ser adaptado ao domínio alvo |
| Webhooks de saída | migration 028, assinatura, SSRF e retries básicos | Incorporar | melhora integrações e observabilidade externa |
| API pública | endpoints de contatos, conversas, mensagens e broadcasts | Incorporar com hardening | útil, desde que capacidades e comandos sejam alinhados ao domínio |
| Mensagens interativas | migration 035 e componentes | Incorporar com teste | melhora atendimento e campanhas |
| Quick replies | APIs e interface | Incorporar | ganho operacional de baixo conflito |
| Correções de WhatsApp | envio, webhook, mídia, testes | Incorporar | reduz retrabalho e regressões |
| Testes adicionais | auth, API, WhatsApp, webhooks, dedupe | Incorporar | aumenta baseline de qualidade |
| Internacionalização | `next-intl`, inglês/coreano e alteração ampla de textos | Adiar/reverter | produto será inicialmente pt-BR; tradução parcial aumenta complexidade |
| IA de resposta | migrations 029–033, providers, agentes e usage | Adiar/feature gate | não é requisito para concluir o CRM e adiciona custo, risco e suporte |
| Base vetorial | pgvector e knowledge base | Adiar/remover | amplia banco e operação sem resolver os fluxos prioritários |
| MCP server | pacote e serviço separado | Adiar/remover | novo processo de deploy e superfície de segurança |
| Branding original | textos/metadados mantidos | Substituir | produto próprio não deve parecer template upstream |

## Migrations 027–036

| Migration | Tema | Direção |
|---|---|---|
| 027 | notificações | manter, revisar estados e vínculo com tarefa/evento |
| 028 | webhook endpoints | manter, revisar retry/dead-letter |
| 029 | AI reply | não aplicar no baseline inicial |
| 030 | AI knowledge/pgvector | não aplicar no baseline inicial |
| 031 | AI reply slot grant | não aplicar no baseline inicial |
| 032 | fix AI knowledge membership | dispensável sem IA |
| 033 | AI reply polish | não aplicar no baseline inicial |
| 034 | fix profiles update RLS | manter |
| 035 | interactive messages | manter após teste |
| 036 | conversation/contact dedup | manter; prioridade alta |

## Dependência crítica de migrations

Não basta excluir arquivos de IA da interface. É necessário verificar se migrations e código posteriores fazem referência a colunas/tabelas de IA. O baseline próprio deve ter uma sequência coerente e testada, sem lacunas silenciosas.

Caminhos aceitos:

1. aplicar toda a sequência upstream e manter IA desativada; ou
2. gerar uma sequência consolidada própria para instalações novas e uma migração incremental separada para instalações existentes.

O segundo caminho é mais limpo para o produto final, mas exige maior rigor de teste. Não se deve simplesmente apagar migrations intermediárias de um histórico já aplicado.

## Riscos que permanecem após atualização

### Hard delete

A tela continua executando exclusão única e em massa diretamente na tabela `contacts`.

**Tratamento:** correção P0 própria antes de uso produtivo.

### Pipeline sem comando de fechamento

Mover card continua atualizando somente `stage_id`.

**Tratamento:** comandos `move`, `win`, `lose`, `reopen` no Bloco 1/5.

### Middleware incompleto

A lista ainda não inclui `/flows` e também deverá acompanhar novos módulos privados.

**Tratamento:** proteção por convenção/grupo de rotas e testes de matriz.

### Domínio incompleto

Lead, tarefa, atividade comercial e event log continuam ausentes.

**Tratamento:** Bloco 1 em diante.

## Plano de validação da branch

- [ ] abrir PR de avaliação sem intenção de merge imediato;
- [ ] executar CI;
- [ ] inspecionar falhas de lint/typecheck/test/build;
- [ ] criar banco limpo e aplicar migrations completas;
- [ ] criar cópia de homologação e aplicar incrementalmente;
- [ ] validar login, conta, inbox, contatos, pipeline, broadcast, automações e flows;
- [ ] medir bundle, dependências e variáveis novas;
- [ ] registrar módulos a remover/feature-gate;
- [ ] criar `integration/product-baseline`.

## Recomendação

Prosseguir com o upstream como base técnica isolada, retirar o escopo não prioritário e somente então criar o baseline próprio. Fazer desenvolvimento extensivo sobre a `main` antiga criaria dívida e conflitos evitáveis.
