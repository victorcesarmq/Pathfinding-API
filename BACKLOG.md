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
