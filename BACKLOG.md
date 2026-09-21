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
- **Outros personagens contam como obstáculo na validação de volume** (surgiu na Fase 4): os
  raycasts só excluem o próprio personagem, então um NPC parado num corredor pode fazer a rota
  de outro reprovar como `corridor_too_narrow`. Excluir todo modelo com Humanoid dos
  `RaycastParams` resolveria (a detecção de bloqueio da Fase 4 já ignora personagens).
- **Partes que se movem para dentro da rota não disparam `Blocked`** (surgiu na Fase 4): só
  partes novas (`Geometry.PartAdded`) são detectadas. Portas e plataformas móveis exigiriam
  ouvir mudanças de posição perto da rota.
- **Falhas de rota não são cacheadas** (surgiu na Fase 2): um destino sem rota recalcula a
  escada inteira (várias chamadas de `ComputeAsync`) a cada pedido. Um cache negativo curto
  (1-2 s) protegeria o Scheduler de agentes que insistem num destino impossível.
