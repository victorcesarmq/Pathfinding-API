# DECISIONS

Registro de decisões de design não triviais da SmartPath (Seção 9 do
`SMARTPATH_PLANO_DE_EXECUCAO.md`). Toda entrada nova também deve ser refletida em
`src/SmartPath/DECISIONS.luau`.

## D-001 — Origem não é parâmetro da API
Data: 2026-09-20
Contexto: a assinatura natural seria (startPos, goalPos).
Decisão: receber Humanoid/Model e derivar a origem internamente.
Motivo: do humanoid extraímos posição aterrada, JumpHeight real, WalkSpeed e rig — exatamente
a informação que falta ao PathfindingService. Um Vector3 não carrega nada disso.
Consequência: quem só tem coordenadas usa a camada de compatibilidade (`SmartPath.Service`).

## D-002 — Rota com raio reduzido exige validação por Spherecast
Data: 2026-09-20
Contexto: a escada de raio adaptativo (Fase 2) tenta raios menores quando o raio real falha.
Decisão: toda rota obtida com raio reduzido é validada por Spherecast no raio real do agente
ao longo de cada segmento antes de ser aceita.
Motivo: sem essa validação a lib passaria a recomendar rotas onde o personagem não cabe de
fato, o que é pior que o `NoPath` original — o problema deixaria de ser "sem rota" e passaria a
ser "rota falsa".
Consequência: se nenhum raio da escada passar na validação, o erro é `corridor_too_narrow`
com `requiredRadius`.

## D-003 — Sem dependências externas na v1
Data: 2026-09-20
Contexto: bibliotecas como Promise ou Knit facilitariam parte do código assíncrono.
Decisão: a v1 não depende de nenhuma biblioteca externa.
Motivo: a lib precisa ser autocontida e instalável em uma linha (Wally ou cópia direta),
sem exigir que o consumidor resolva árvore de dependências.
Consequência: yields são feitos com primitivas nativas (`task.spawn`, `task.wait`, sinais
próprios).

## D-004 — O gerador de PathfindingLink fica para a v2
Data: 2026-09-20
Contexto: gerar `PathfindingLink` automaticamente (baker) resolveria salto de forma mais
barata em runtime que a predição balística.
Decisão: não implementar na v1; registrado como Fase 10 do plano.
Motivo: é a peça mais valiosa e mais trabalhosa do projeto — misturá-la à v1 arrisca inflar
o escopo e atrasar o lançamento (ver Seção 10, risco "Escopo infla").
Consequência: a v1 depende de predição em runtime (`SmartPath.Predictor`) para saltos não
mapeados por level design.

## D-005 — A biblioteca nunca altera propriedades do mapa do usuário
Data: 2026-09-20
Contexto: filtrar geometria invisível colidível poderia ser feito desligando `CanCollide`.
Decisão: a única alteração permitida no mapa é criar/remover `PathfindingModifier` filho, de
forma reversível e desligável por opção (`Geometry.AutoFilter`). `CanCollide`, `Transparency`
e `Anchored` nunca são tocados.
Motivo: mudar `CanCollide` automaticamente altera a física do jogo do consumidor de formas
que ele não pediu e não consegue prever; é regra permanente (Seção 5, regra 4).
Consequência: partes invisíveis colidíveis não classificadas ficam listadas em
`Geometry.audit()` para o desenvolvedor etiquetar manualmente.

## D-006 — Geometry é global; AutoFilter/RequireNameMatch não são por agente
Data: 2026-09-20
Contexto: a Options.Geometry pública (Seção 3.5) tem `AutoFilter`/`RequireNameMatch` na
tabela de opções de cada agente, mas `PathfindingModifier` é um efeito de mundo — não dá
para um agente ver uma parte como atravessável e outro não, a navmesh é uma só.
Decisão: `Geometry` é o singleton documentado (regra 2) e mantém um único estado global de
classificação por ambiente (cliente/servidor). `Geometry.setAutoFilter`/`setRequireNameMatch`
mudam esse estado global; quando um agente (Fase 4) definir `Options.Geometry` diferente de
outro já ativo, o último a chamar `setAutoFilter`/`setRequireNameMatch` decide para todos —
não existe "visão de mundo" por agente.
Motivo: qualquer alternativa exigiria estado por agente sobre uma feature que é
inerentemente de mundo compartilhado (regra 4: só criamos/removemos `PathfindingModifier`
de forma global e reversível).
Consequência: tags `NavSolid`/`NavIgnore` continuam funcionando independente do AutoFilter
(são intenção explícita do desenvolvedor, nunca desligam); só a heurística de auto-detecção
por Transparency+nome é afetada pelo toggle global.

## D-007 — Prioridade do Scheduler: número maior = mais urgente
Data: 2026-09-20
Contexto: o plano não especifica a direção da prioridade numérica do `Scheduler.submit`.
Decisão: número maior é processado primeiro; em empate, o pedido mais antigo (FIFO) vence.
Motivo: `Options.Scheduler.Priority` (Seção 3.5) tem default `0` — um valor neutro que faz
mais sentido como "meio da escala" se prioridades mais urgentes forem positivas e crescentes
(ex.: jogador em perigo = prioridade alta) do que se a escala fosse invertida.
Consequência: quem chamar `Scheduler.submit` com prioridade alta (ex.: 10) é atendido antes
de quem usa o default. Sem aging: sob carga constante de prioridade alta, um pedido de
prioridade baixa pode esperar indefinidamente — ver item correspondente em `BACKLOG.md`.
