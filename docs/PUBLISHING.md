# Publicando a SmartPath 1.0

O que falta para a 1.0 sair de fato. Tudo aqui depende da **sua conta** (GitHub, Roblox), então nada disto foi feito automaticamente.

## Antes de publicar

- [ ] Rode `Phase1()` até `Phase8()` e `Curves()`, e o demo (`run:N` de cada cenário), numa cópia limpa, e confira que tudo passa.
- [ ] Confirme o titular da licença em `LICENSE` (hoje: "Victor").
- [ ] Troque os links de exemplo do README que você quiser (Creator Store, GitHub) pelos reais.
- [ ] Faça o teste do README: peça a alguém que **nunca viu o projeto** para instalar e mover um NPC seguindo só o README, cronometrando. O critério é 5 minutos.

## 1. Repositório no GitHub e tag

```bash
git remote add origin https://github.com/<usuario>/smartpath.git   # se ainda não existe
git push -u origin master
git tag -a v1.0.0 -m "SmartPath 1.0.0"
git push origin v1.0.0
```

Marque a versão no GitHub (Releases → "Draft a new release" → tag `v1.0.0`) e cole o trecho `[1.0.0]` do `CHANGELOG.md` como descrição.

## 2. Modelo no Creator Store

Monte a biblioteca no Studio a partir dos arquivos de `src/SmartPath`: um `ModuleScript` `SmartPath` (o conteúdo de `init.luau`) com um `ModuleScript` filho para cada um dos outros arquivos (a tabela está no README, em "Instalação"). Confira com um `Script` de teste que `require(game.ReplicatedStorage.SmartPath)` funciona e que `SmartPath.Version` devolve `"1.0.0"`.

Depois: selecione o `ModuleScript` `SmartPath` → botão direito → **Save/Export → Publish as Model** (com o nome "SmartPath" e a descrição do README). Marque como distribuição pública e cole o link no README.

## 3. Place de demonstração público

Monte o demo no Studio a partir de `src/demo`: `server/` vira a pasta `SmartPathDemo` em `ServerScriptService` (o `Main.server.luau` é um `Script` chamado `Main`; os outros arquivos são `ModuleScript`s), e `client/HUD.client.luau` vira um `LocalScript` `SmartPathDemoHUD` em `StarterPlayerScripts`. Coloque a SmartPath em `ReplicatedStorage`. Rode e confira o `pronto` no Output.

Depois: **File → Publish to Roblox As...** → crie um place novo (público). Os cenários rodam pelo HUD. Cole o link no README e no post.

## 4. GIFs para o README e o post

Nenhum foi gravado. Cenas sugeridas (uma por GIF, ~8 s, câmera de cima, lado a lado):

1. **Plataforma de 18 studs (cenário 4).** O NPC clássico fica parado; o da SmartPath salta.
2. **Labirinto com gatilho invisível (cenário 5).** Idem, com a rota da SmartPath desenhada (`Debug = true` já vem ligado no demo).
3. **Caverna (cenários 9 a 11).** O clássico sobe pelo teto; a SmartPath entra, anda dentro e sai.
4. **Sala com porta estreita (cenário 2).** O clássico não sai do lugar; a SmartPath chega, com o disco do raio laranja (reduzido).
5. **20 NPCs (cenário 8).** Os dois lados, com o HUD mostrando o FPS.

Grave com o gravador do Studio (Ctrl+Shift+F12 no editor) ou uma ferramenta de captura de tela, converta para GIF e salve em `docs/media/`.

## 5. Post no DevForum

Categoria **Community Resources**. O rascunho está em [DEVFORUM_POST.md](DEVFORUM_POST.md): troque os `[GIF]` e os links antes de postar.
