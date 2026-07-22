# ADR-001 — Estratégia de baseline upstream

- Status: **Proposto**
- Data: 2026-07-22
- Decisores: produto e engenharia do WACRM customizado
- Snapshot local: `077993266400a2ac6be58843324c8d8c87b03d3a`
- Upstream avaliado: `3180f06da6eaa73d84b09b99ea30b01e78db62f5` (0.8.1)

## Contexto

A `main` do fork é ancestral direto do upstream e está 125 commits atrás. O fork ainda não contém customizações próprias relevantes além do vínculo do repositório, o que torna este o momento de menor custo para decidir a base técnica.

O upstream posterior contém correções e capacidades úteis:

- notificações;
- correções adicionais de RLS;
- deduplicação autoritativa de conversa por conta/contato;
- mensagens interativas;
- quick replies;
- ampliação da API pública e webhooks de saída;
- testes adicionais e correções de WhatsApp.

Também contém ampliações que não são prioridade para a finalização do CRM comercial:

- agentes e respostas com IA;
- base de conhecimento vetorial;
- internacionalização inicial;
- servidor MCP separado.

A atualização completa não resolve as lacunas de domínio identificadas. Na versão 0.8.1 ainda existem:

- hard delete de contatos no cliente;
- etapa `Won` sem comando de fechamento;
- `/flows` fora da lista explícita de rotas protegidas;
- ausência de Lead e Task;
- permissões operacionais excessivamente amplas.

## Opções consideradas

### A. Permanecer no snapshot atual

Vantagens:

- menor mudança imediata;
- nenhum módulo adicional.

Desvantagens:

- mantém bugs já corrigidos;
- obriga a recriar correções de integridade e testes;
- aumenta divergência e custo futuro.

### B. Cherry-pick seletivo de dezenas de commits

Vantagens:

- controle fino do escopo.

Desvantagens:

- alto risco de dependências ocultas entre migrations, tipos, APIs e testes;
- histórico fragmentado;
- custo de revisão e conflito maior que o benefício;
- manutenção difícil quando uma correção depende de infraestrutura introduzida antes.

### C. Adotar o upstream 0.8.1 como baseline técnico e desativar/retirar escopo não prioritário

Vantagens:

- incorpora a linha testada mais recente;
- reduz a distância do projeto original antes da customização;
- preserva correções de integridade, segurança e WhatsApp;
- cria ponto claro de separação para o produto próprio.

Desvantagens:

- traz migrations e módulos que precisam ser classificados;
- exige retirada ou feature gate para IA/MCP/i18n não desejados;
- exige homologação de banco antes de produção.

## Decisão proposta

**Adotar a opção C em uma branch de integração isolada, sem merge imediato.**

Branch criada:

`integration/upstream-0.8.1-evaluation`

Ela aponta exatamente para o commit upstream avaliado e não altera a `main`.

## Plano de adoção

### Etapa 1 — Avaliação técnica

- executar lint, typecheck, testes e build;
- revisar migrations 027–036;
- testar aplicação das migrations em banco limpo;
- testar aplicação sobre uma cópia do banco atual;
- identificar variáveis de ambiente adicionais;
- medir impacto no bundle e rotas.

### Etapa 2 — Classificação de escopo

#### Incorporar como baseline

- notificações, após revisão do modelo;
- webhooks de saída e melhorias da API, se não ampliarem risco operacional;
- correções de RLS;
- deduplicação de conversas;
- correções e testes de WhatsApp;
- mensagens interativas e quick replies, com validação de produto.

#### Manter desativado ou remover antes do merge

- agentes/auto-reply com IA;
- base de conhecimento/pgvector;
- menu e configurações de IA;
- MCP server;
- internacionalização parcial, até existir estratégia de idioma.

### Etapa 3 — Preparação do baseline próprio

Criar uma branch derivada da avaliação upstream:

`integration/product-baseline`

Nessa branch:

- retirar ou feature-gate escopo adiado;
- manter migrations aplicáveis em ordem coerente;
- aplicar correções P0 próprias;
- atualizar branding e metadados básicos;
- documentar incompatibilidades e rollback.

### Etapa 4 — Merge controlado

O baseline somente poderá ser promovido quando:

- CI estiver verde;
- migrations forem testadas nos dois caminhos;
- nenhum segredo adicional estiver sem documentação;
- hard delete estiver bloqueado ou explicitamente aceito temporariamente;
- rotas privadas estiverem protegidas;
- plano de rollback estiver documentado.

## Consequências

- A `main` permanece estável durante a avaliação.
- Não serão desenvolvidas novas funcionalidades sobre o snapshot antigo, exceto contenções P0 indispensáveis.
- Blocos de domínio serão implementados sobre o baseline aprovado.
- O projeto deixa de acompanhar upstream automaticamente após a criação do baseline próprio; futuras incorporações serão analisadas por tema.

## Critérios de aprovação

- [ ] CI da branch de avaliação concluído;
- [ ] migrations 027–036 classificadas;
- [ ] IA/MCP/i18n removidos ou desativados no baseline próprio;
- [ ] riscos P0 reavaliados;
- [ ] plano de banco e rollback aprovado;
- [ ] decisão alterada de **Proposto** para **Aceito**.
