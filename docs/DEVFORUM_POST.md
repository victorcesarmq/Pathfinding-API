# Rascunho do post: DevForum → Community Resources

> Troque os marcadores `[GIF ...]` e `[LINK ...]` antes de postar. O texto está em português; para o fórum em inglês, veja o item do backlog.

**Título:** SmartPath: pathfinding que conhece o agente de verdade (raio adaptativo, saltos por `JumpHeight`, zonas invisíveis e erros com diagnóstico)

---

## O problema

Se você já usou o `PathfindingService` em NPCs, provavelmente já viu isto:

- o NPC **não passa** por um lugar por onde o personagem passaria, e o `ComputeAsync` devolve `NoPath`;
- ele **não pula** um obstáculo que o `JumpHeight` dele alcançaria, porque a malha só conhece "pula / não pula";
- uma **zona invisível** com `CanCollide = true` (aquela que dispara "você entrou na caverna") vira uma parede, e a rota dá a volta por cima do teto ou some;
- quando falha, o único diagnóstico é um enum genérico.

A causa é a mesma: a malha é construída com um modelo pobre do personagem.

## O que é a SmartPath

Uma biblioteca que usa o `PathfindingService` por baixo, mas **valida cada rota contra o corpo real do `Humanoid`**, calcula saltos com o `JumpHeight` de verdade e responde **por que** uma rota falhou.

```lua
local SmartPath = require(game.ReplicatedStorage.SmartPath)
local ok, reason, details = SmartPath.MoveTo(workspace.Zombie.Humanoid, workspace.Base.Position)
if not ok then warn(SmartPath.explain(reason, details)) end
```

Sem tabela de opções, sem origem, sem configuração: raio, altura, velocidade e força do pulo saem do próprio personagem.

## O que ela faz

- **Raio adaptativo** para ambientes fechados, e toda rota é validada por `Spherecast` no corpo real.
- **Saltos por balística** com o `JumpHeight` real, inclusive além do limite fixo da malha.
- **Filtro de geometria invisível** com `PathfindingModifier.PassThrough`, e as tags `NavIgnore` e `NavSolid` para você decidir (a biblioteca nunca altera o seu mapa).
- **Erros com diagnóstico**: `corridor_too_narrow`, `obstacle_too_tall`, `invisible_collider`... com dados, e `SmartPath.explain` para uma frase legível.
- **Estabilidade**: origem aterrada, cache, suavização e histerese (a rota não oscila entre chamadas iguais).
- **Agendador**: um orçamento de cálculos por frame para muitos NPCs.
- **Debug visual** com uma opção (`Debug = true`) e um painel opcional.
- **Compatibilidade**: `SmartPath.Service` espelha o `PathfindingService`; um script clássico passa a usá-la trocando **uma linha**.

## Comparação lado a lado

O place de demonstração tem cenários com dois NPCs idênticos sobre a mesma geometria: à esquerda o `PathfindingService` puro (do jeito da documentação), à direita a SmartPath.

[GIF: plataforma de 18 studs com JumpHeight 25]
[GIF: caverna com zona invisível: entrar, sair e andar dentro]
[GIF: labirinto com gatilho invisível]

| Situação | `PathfindingService` puro | SmartPath |
|---|---|---|
| Plataforma de 18 studs, `JumpHeight` 25 | `NoPath` | Salta e chega |
| Labirinto com gatilho invisível na passagem | `NoPath` | Chega |
| Caverna com zona invisível cobrindo o interior | Sem rota, ou rota por cima do teto | Entra, anda e sai |
| Sala com porta de 3 studs | `NoPath` | Chega (raio reduzido de 2,0 para 1,0) |
| 20 NPCs ao mesmo tempo | 60 FPS | 60 FPS, mais trechos concluídos |

[LINK: place de demonstração]

## O que ela **não** faz

Prefiro dizer aqui do que descobrir no seu jogo:

- **Empata** onde a engine já resolve: corredores de 3 a 4 studs e muretas de ~3 studs. Testei, e os dois lados passam.
- **Só reduz o raio, não a altura.** Um teto mais baixo que o agente continua dando `NoPath`.
- O atalho por salto **só vê obstáculos a até 10 studs**.
- **Não gera `PathfindingLink`**, não faz evitação entre agentes, não faz voo, natação nem escalada, e não suporta rigs sem `Humanoid`.
- **Ainda não validei** o agente controlando o personagem de um **jogador no cliente**, nem com `StreamingEnabled`. NPCs de servidor foram exercitados (incluindo 500 agentes criados e destruídos e 20 NPCs por 10 minutos, sem vazamento).

## Instalação

- **Wally:** `SmartPath = "seu-usuario/smartpath@1.0.0"`
- **Modelo do Creator Store:** [LINK: modelo]
- **GitHub:** [LINK: repositório] (MIT)

A documentação completa da API está no README do repositório.

## Feedback

Relatos de casos que quebram são o que mais me ajuda: se a SmartPath falhar num caso seu, ligue `Debug = true`, copie o que o `SmartPath.explain(reason, details)` disser e abra uma issue com a geometria (um place mínimo ajuda muito).
