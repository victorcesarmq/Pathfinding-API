# BACKLOG

Itens explicitamente fora do escopo da v1.0 (Seção 2.2 do
`SMARTPATH_PLANO_DE_EXECUCAO.md`) e qualquer ideia nova que surja durante a implementação.
Regra: qualquer coisa fora da Seção 2.1 do plano vira linha aqui, nunca é implementada sem
autorização.

## Fora da v1.0 (backlog explícito do plano)

- **Gerador automático de `PathfindingLink` ("baker")** → v2, Fase 10. Varredura do mapa por
  bordas e desníveis, teste de alcançabilidade por par (origem, destino) com o perfil de
  salto real, geração de `PathfindingLink` com `Label`. Ver D-004 em `DECISIONS.md`.
- **Evitação dinâmica entre agentes** (RVO/steering).
- **Pathfinding em voo, natação, escalada.**
- **Pathfinding hierárquico para mapas gigantes.**
- **Suporte a rigs não-Humanoid.**

## Surgidos durante a implementação

- **Aging de prioridade no `Scheduler`** (surgiu na Fase 1): hoje a fila é estritamente por
  prioridade (maior primeiro, empate por ordem de chegada — ver D-007 em `DECISIONS.md`).
  Sob carga constante de pedidos de prioridade alta, um pedido de prioridade baixa pode
  esperar indefinidamente (starvation). Não é crítico para a v1 (poucos NPCs, orçamento por
  frame já dá vazão), mas vale revisitar se o cenário 8 da Fase 7 (20 NPCs simultâneos)
  mostrar algum agente nunca recalculando rota.
- **Centralização de waypoints em portas/corredores** (surgiu na Fase 2, tratada na Fase 4 como
  relaxamento, D-018): agora só entra como recurso quando a rota não cabe. Falta validar os
  fatores em mapas reais e considerar centralizar também segmentos longos entre waypoints.
- **Cache de rotas sem invalidação por geometria arbitrária** (surgiu na Fase 2): o
  `RouteCache` invalida por TTL, por versão do `Geometry` (modifiers) e por `invalidateGoal`,
  mas não percebe uma parte comum movida/criada sobre a rota até o `Path.Blocked` (Fase 4)
  ou o TTL de 15s. Avaliar se vale ouvir `workspace.DescendantAdded` para partes colidíveis.
- ~~**Outros personagens contam como obstáculo na validação de volume** (surgiu na Fase 4)~~ **resolvido na Fase 7, D-028**: os
  raycasts só excluem o próprio personagem, então um NPC parado num corredor pode fazer a rota
  de outro reprovar como `corridor_too_narrow`. Excluir todo modelo com Humanoid dos
  `RaycastParams` resolveria (a detecção de bloqueio da Fase 4 já ignora personagens).
- **Partes que se movem para dentro da rota só são detectadas em até ~1.25 s** (surgiu na Fase 4; mitigado na Fase 7, D-030 com revalidação periódica): só
  partes novas (`Geometry.PartAdded`) são detectadas. Portas e plataformas móveis exigiriam
  ouvir mudanças de posição perto da rota.
- **Falhas de rota não são cacheadas** (surgiu na Fase 2): um destino sem rota recalcula a
  escada inteira (várias chamadas de `ComputeAsync`) a cada pedido. Um cache negativo curto
  (1-2 s) protegeria o Scheduler de agentes que insistem num destino impossível.
- **`invisible_collider` só olha a primeira batida** (surgiu na Fase 6, D-024): num labirinto em
  que uma parede visível vem antes da parte invisível, o erro fica `no_path`. Um diagnóstico
  melhor testaria cada parte invisível colidível perto da reta (ou do trecho bloqueado).
- **`obstacle_too_tall`/`no_landing` só analisam o primeiro obstáculo da reta** (Fase 6, D-024):
  um obstáculo alto atrás de um desvio não é apontado, e sai `no_path`.
- **`timeout` sem opção pública** (Fase 6, D-025): 45 s + 4x o tempo ideal, fixo. Um jogo com
  agentes muito lentos em mapas enormes pode precisar de um campo em `Options`; isso exige
  reabrir a Seção 3.5 congelada.
- **`Scheduler` faz `warn` incondicional quando um job lança erro** (Fase 6): a regra 10 diz que
  só `Options.Debug` imprime, mas o `Scheduler` não conhece opções. Hoje só dispara em bug.
- **Painel de debug não validado no cliente** (Fase 6): o conteúdo foi verificado no servidor
  (`GetText`), mas a aparência e o `PlayerGui` só existem num jogador real.
- **O atalho por salto só enxerga obstáculos a até 10 studs** (surgiu na Fase 7): o `Predictor` sonda
  10 studs à frente (`PROBE_DISTANCE`). Uma mureta ou plataforma a 40 studs do agente não vira atalho
  nem salto direto; o agente só a percebe ao chegar perto (sonda reativa). Os cenários 3 e 4 do demo
  começam a ~7 studs para contornar isso. Corrigir pede que o `DirectJump` corra distâncias
  maiores que o `DIRECT_TIMEOUT` atual (4 s).
- **Sem desvio local entre NPCs** (surgiu na Fase 7, cenário 8): dois agentes que se encontram se
  empurram e um pode acabar encostado num pilar; o anti-stuck resolve quase sempre (1 `stuck` em ~88
  trechos no último relatório). Evitar colisão entre agentes (avoidance) não faz parte do escopo da
  v1, mas é o próximo passo natural para multidões.
- **Pior frame da SmartPath maior que o do clássico no cenário 8** (Fase 7): a média de FPS é igual
  (60), mas o pico da SmartPath é de 147 a 183 ms contra 116 a 122 ms. Provavelmente o cálculo
  simultâneo das 20 rotas iniciais; o `Scheduler` limita o orçamento por frame, então vale medir
  antes de mexer.
- **README, API e post em inglês** (surgiu na Fase 9, D-034): a documentação está só em português,
  como o `explain`. Uma versão em inglês alcança a comunidade internacional do DevForum; as
  mensagens do `explain` também precisariam de tradução (já estão numa tabela por código).
- **GIFs do antes/depois** (Fase 9): não foram gravados; a lista de cenas está em `docs/PUBLISHING.md`.
- **Validar o passo a passo do README com uma pessoa** (Fase 9): o critério "instala e move um NPC em
  menos de 5 minutos" precisa de alguém que nunca viu o projeto.
