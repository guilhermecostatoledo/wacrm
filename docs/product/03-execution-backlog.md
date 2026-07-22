# Backlog de execução por blocos

> O GitHub Issues está desativado neste repositório. Até que seja habilitado, este arquivo é a fonte de rastreamento do programa e deve ser atualizado em cada PR.

## Convenções

- Estado: `TODO`, `DOING`, `BLOCKED`, `DONE`, `CANCELLED`
- Prioridade: `P0`, `P1`, `P2`, `P3`
- Cada item concluído deve apontar para PR, migração e teste correspondente.
- Itens P0 impedem avanço de funcionalidades relacionadas.

## Bloco 0 — Diagnóstico e baseline

| ID | Prioridade | Estado | Item | Evidência de saída |
|---|---:|---|---|---|
| B0-001 | P0 | DONE | Criar branch de diagnóstico | `strategy/block-0-diagnostic` |
| B0-002 | P1 | DONE | Documentar roadmap | `00-strategy-roadmap.md` |
| B0-003 | P1 | DONE | Registrar diagnóstico inicial | `01-block-0-diagnostic.md` |
| B0-004 | P1 | DONE | Definir modelo de domínio alvo | `02-target-domain-model.md` |
| B0-005 | P0 | TODO | Inventariar todas as rotas privadas e APIs | matriz rota × autenticação × capacidade |
| B0-006 | P0 | TODO | Inventariar migrations e dependências | catálogo ordenado e teste de reaplicação |
| B0-007 | P0 | TODO | Medir baseline de lint/typecheck/test/build | execução CI registrada |
| B0-008 | P0 | TODO | Decidir estratégia upstream | ADR-001 aprovado |
| B0-009 | P1 | TODO | Criar mapa de dados e FKs destrutivas | diagrama + relatório de impacto |
| B0-010 | P1 | TODO | Registrar baseline de desempenho | dashboard, contatos, inbox e pipeline |
| B0-011 | P1 | TODO | Definir dados de homologação | seed sem dados pessoais reais |
| B0-012 | P1 | TODO | Habilitar Issues ou escolher Project externo | ferramenta de acompanhamento definida |

## Correções de contenção antes do Bloco 1

| ID | Prioridade | Estado | Item | Critério de aceite |
|---|---:|---|---|---|
| HOT-001 | P0 | TODO | Bloquear hard delete de contatos na UI | exclusão física não acessível por agente |
| HOT-002 | P0 | TODO | Proteger `/flows` no middleware | anônimo é redirecionado para login |
| HOT-003 | P1 | TODO | Testar contato → conversa → mensagem em exclusão | histórico não é apagado inadvertidamente |
| HOT-004 | P1 | TODO | Corrigir semântica de etapa `Won` | card ganho não aparece como negócio aberto |
| HOT-005 | P1 | TODO | Tornar criação de pipeline + etapas atômica | falha não deixa pipeline vazio |
| HOT-006 | P1 | TODO | Tornar atualização de campos customizados atômica | falha preserva valores anteriores |

## Bloco 1 — Domínio, integridade e banco

| ID | Prioridade | Estado | Item | Critério de aceite |
|---|---:|---|---|---|
| B1-001 | P0 | TODO | Criar `domain_events` append-only | transições críticas geram evento |
| B1-002 | P0 | TODO | Adicionar política de arquivamento | contatos não são apagados no fluxo normal |
| B1-003 | P0 | TODO | Criar entidade `leads` | contato pode ter ciclos de captação distintos |
| B1-004 | P0 | TODO | Criar entidade `tasks` | tarefa possui responsável, prazo e estado |
| B1-005 | P1 | TODO | Criar `activities` comerciais | timeline separada das mensagens |
| B1-006 | P1 | TODO | Normalizar autoria e responsabilidade | `created_by` não é `assigned_to` |
| B1-007 | P1 | TODO | Definir comandos de oportunidade | `move`, `win`, `lose`, `reopen` |
| B1-008 | P1 | TODO | Criar testes SQL/RLS das novas tabelas | isolamento por conta comprovado |
| B1-009 | P1 | TODO | Preparar migração compatível de `deals` | dados existentes preservados |
| B1-010 | P2 | TODO | Remover coluna `profiles.role` legada | nenhum consumidor restante |

## Bloco 2 — Segurança, contas e permissões

| ID | Prioridade | Estado | Item | Critério de aceite |
|---|---:|---|---|---|
| B2-001 | P0 | TODO | Definir matriz de capacidades | ações sensíveis têm capability própria |
| B2-002 | P0 | TODO | Auditar autenticação de todas as APIs | rota privada sem guarda = zero |
| B2-003 | P0 | TODO | Testar isolamento cross-account | suíte negativa automatizada |
| B2-004 | P1 | TODO | Avaliar memberships many-to-many | ADR-002 aprovado |
| B2-005 | P1 | TODO | Criar equipes e escopo de visualização | gestor vê equipe; agente vê escopo permitido |
| B2-006 | P1 | TODO | Criar delegação temporária | férias sem conceder admin |
| B2-007 | P1 | TODO | Separar superadmin da plataforma | cliente não recebe privilégio da operadora |
| B2-008 | P2 | TODO | Criar suporte temporário auditado | acesso possui início, fim e motivo |

## Bloco 3 — Entrada e tratamento de leads

| ID | Prioridade | Estado | Item | Critério de aceite |
|---|---:|---|---|---|
| B3-001 | P0 | TODO | Implementar criação idempotente de lead | mesma entrada não duplica ciclo |
| B3-002 | P0 | TODO | Deduplicar e permitir merge de contatos | histórico preservado |
| B3-003 | P1 | TODO | Criar origens e UTMs | entrada possui atribuição estruturada |
| B3-004 | P1 | TODO | Criar regras de distribuição | responsável/fila definido automaticamente |
| B3-005 | P1 | TODO | Criar SLA de primeiro contato | atraso é mensurável e notificável |
| B3-006 | P1 | TODO | Criar qualificação estruturada | relatório não depende de nota livre |
| B3-007 | P1 | TODO | Criar nutrição/desqualificação | motivo obrigatório e reabertura controlada |
| B3-008 | P2 | TODO | Importação CSV com dry-run | erros e duplicidades antes da gravação |

## Bloco 4 — Tarefas, agenda e cadência

| ID | Prioridade | Estado | Item | Critério de aceite |
|---|---:|---|---|---|
| B4-001 | P0 | TODO | CRUD de tarefa por serviço | invariantes fora do componente |
| B4-002 | P0 | TODO | Tratar tarefa ao arquivar entidade | cancelar, transferir ou bloquear explicitamente |
| B4-003 | P1 | TODO | Criar agenda diária/semanal | prazos por timezone da conta |
| B4-004 | P1 | TODO | Criar lembretes e notificações | leitura e resolução são estados distintos |
| B4-005 | P1 | TODO | Criar recorrência | geração idempotente |
| B4-006 | P1 | TODO | Exigir resultado por tipo | conclusão consistente |
| B4-007 | P1 | TODO | Criar cadências comerciais | tentativas e saídas configuráveis |
| B4-008 | P2 | TODO | Criar delegação em massa | férias e troca de carteira seguras |

## Bloco 5 — Pipeline e processo comercial

| ID | Prioridade | Estado | Item | Critério de aceite |
|---|---:|---|---|---|
| B5-001 | P0 | TODO | Implementar estados finais transacionais | ganho/perdido consistentes |
| B5-002 | P1 | TODO | Registrar histórico de etapa | ator, origem e datas disponíveis |
| B5-003 | P1 | TODO | Definir critérios por etapa | transição inválida é explicada |
| B5-004 | P1 | TODO | Exigir próxima atividade | negócio aberto sem ação é sinalizado |
| B5-005 | P1 | TODO | Criar motivo de perda | relatório estruturado |
| B5-006 | P1 | TODO | Criar aging e probabilidade | forecast confiável |
| B5-007 | P1 | TODO | Reconciliar pipeline e dashboard | mesmas regras e totais |
| B5-008 | P2 | TODO | Testar drag em desktop/mobile/teclado | usabilidade e acessibilidade |

## Bloco 6 — WhatsApp e atendimento

| ID | Prioridade | Estado | Item | Critério de aceite |
|---|---:|---|---|---|
| B6-001 | P0 | TODO | Definir contrato `WhatsAppProvider` | domínio não depende de Meta diretamente |
| B6-002 | P0 | TODO | Garantir idempotência de webhook | evento repetido não duplica mensagem |
| B6-003 | P0 | TODO | Criar reprocessamento seguro | falhas rastreáveis e recuperáveis |
| B6-004 | P1 | TODO | Avaliar Evolution API | ADR-003 aprovado |
| B6-005 | P1 | TODO | Decidir múltiplos canais/números | ADR-004 aprovado |
| B6-006 | P1 | TODO | Validar todas as mídias | texto, áudio, vídeo, imagem e documento |
| B6-007 | P1 | TODO | Separar timeline comercial e mensagens | sem poluição de histórico |
| B6-008 | P2 | TODO | Criar métricas de fila e SLA | atendimento gerenciável |

## Bloco 7 — Marketing e automações

| ID | Prioridade | Estado | Item | Critério de aceite |
|---|---:|---|---|---|
| B7-001 | P0 | TODO | Versionar execução de automação | log identifica versão e etapa |
| B7-002 | P0 | TODO | Prevenir loops e duplicidade | limites e idempotência testados |
| B7-003 | P1 | TODO | Criar campanha separada de broadcast | objetivo e atribuição disponíveis |
| B7-004 | P1 | TODO | Criar consentimento e supressão | envio respeita política vigente |
| B7-005 | P1 | TODO | Criar aprovação de disparo | capacidade distinta de criar/enviar |
| B7-006 | P1 | TODO | Ligar campanha a lead/oportunidade/receita | ROI mensurável |
| B7-007 | P1 | TODO | Criar retry e dead-letter | erro não desaparece silenciosamente |
| B7-008 | P2 | TODO | Criar pressão/frequência de comunicação | evitar excesso de mensagens |

## Bloco 8 — UX/UI e design system

| ID | Prioridade | Estado | Item | Critério de aceite |
|---|---:|---|---|---|
| B8-001 | P1 | TODO | Redefinir arquitetura de informação | módulos agrupados por trabalho |
| B8-002 | P1 | TODO | Criar tokens e padrões | componentes consistentes |
| B8-003 | P1 | TODO | Redesenhar visão de lead | timeline e próxima ação prioritárias |
| B8-004 | P1 | TODO | Redesenhar tarefas | alta densidade e ação rápida |
| B8-005 | P1 | TODO | Redesenhar pipeline | critérios, aging e tarefa no card |
| B8-006 | P1 | TODO | Dashboard por função | operacional ≠ gerencial |
| B8-007 | P1 | TODO | Testes de acessibilidade | fluxo crítico por teclado e leitor |
| B8-008 | P2 | TODO | Testes de usabilidade | tarefas-chave concluídas sem assistência |
| B8-009 | P2 | TODO | Definir identidade e pt-BR | remover branding herdado |

## Bloco 9 — Gestão, relatórios e administração

| ID | Prioridade | Estado | Item | Critério de aceite |
|---|---:|---|---|---|
| B9-001 | P1 | TODO | Criar indicadores operacionais | tarefas, fila, SLA e pendências |
| B9-002 | P1 | TODO | Criar indicadores gerenciais | conversão, ciclo, forecast e perdas |
| B9-003 | P1 | TODO | Relatórios por origem/campanha/equipe | filtros e exportação consistentes |
| B9-004 | P1 | TODO | Criar metas | período, equipe e responsável |
| B9-005 | P1 | TODO | Criar auditoria consultável | busca por ator, entidade e ação |
| B9-006 | P2 | TODO | Criar feature entitlements | plano controla recurso sem texto ambíguo |
| B9-007 | P2 | TODO | Criar política de retenção | regras documentadas e executáveis |

## Bloco 10 — Qualidade, implantação e aceite

| ID | Prioridade | Estado | Item | Critério de aceite |
|---|---:|---|---|---|
| B10-001 | P0 | TODO | Criar suíte E2E | fluxos críticos automatizados |
| B10-002 | P0 | TODO | Testar migrations em banco limpo e atualizado | dois caminhos verdes |
| B10-003 | P0 | TODO | Testar backup e restore | restauração comprovada |
| B10-004 | P1 | TODO | Definir cobertura crítica | regras P0/P1 protegidas |
| B10-005 | P1 | TODO | Testar carga | limites conhecidos e registrados |
| B10-006 | P1 | TODO | Revisar segurança | auth, RLS, secrets, webhooks e rate limits |
| B10-007 | P1 | TODO | Criar observabilidade | logs, métricas e alertas úteis |
| B10-008 | P1 | TODO | Documentar operação | deploy, rollback e incidentes |
| B10-009 | P1 | TODO | Executar homologação | checklist assinado |

## Registro de riscos inicial

| Risco | Probabilidade | Impacto | Mitigação |
|---|---|---|---|
| Hard delete apagar histórico | Alta | Crítico | HOT-001/HOT-003 e soft delete |
| Customização conflitar com upstream | Alta | Alto | ADR-001 antes do Bloco 1 |
| Permissões excessivas | Alta | Alto | capabilities no Bloco 2 |
| Pipeline divergir dos relatórios | Alta | Alto | comandos e eventos no Bloco 5 |
| Dashboard degradar com volume | Média | Alto | RPC/views e teste de carga |
| Webhook duplicar/perder eventos | Média | Crítico | idempotência, retry e observabilidade |
| Redesign mascarar regra incorreta | Alta | Alto | UX somente após domínio estabilizado |
| Escopo de IA desviar o produto | Média | Médio | adiar até decisão explícita |
