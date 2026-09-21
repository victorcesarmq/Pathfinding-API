# Publicando a SmartPath 1.0

O que falta para a 1.0 sair de fato. Tudo aqui depende da **sua conta** (GitHub, Wally, Roblox), então nada disto foi feito automaticamente.

## Antes de publicar

- [ ] Rode `Phase1()` até `Phase8()` e o demo (`run` de cada cenário) numa cópia limpa do repositório e confira que tudo passa.
- [ ] Troque `seu-usuario` pelo seu escopo do Wally em `wally.toml` e no README (busque por `seu-usuario`).
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

Marque a versão no GitHub (Releases → "Draft a new release" → tag `v1.0.0`) e cole o trecho `[1.0.0]` do `CHANGELOG.md` como descrição. Anexe o `SmartPath.rbxm` (passo 3).

## 2. Wally

```bash
wally login            # uma vez; autentica com o GitHub
wally package          # confere o que vai ser empacotado (gera um .zip)
wally publish
```

- O `wally.toml` já exclui os testes, o demo, os `.rbxlx` e os documentos internos do plano.
- O pacote sai com o `default.project.json` da raiz, que monta só `src/SmartPath`.
- Depois de publicado, quem usar coloca `SmartPath = "<usuario>/smartpath@1.0.0"` no `wally.toml` dele.

## 3. Modelo no Creator Store

```bash
rojo build default.project.json -o SmartPath.rbxm
```

Abra o `SmartPath.rbxm` no Studio, selecione o `ModuleScript` `SmartPath` → botão direito → **Save/Export → Publish as Model** (com o nome "SmartPath" e a descrição do README). Marque como distribuição pública. Depois cole o link no README.

## 4. Place de demonstração público

```bash
rojo build demo.project.json -o SmartPathDemo.rbxlx
```

Abra no Studio → **File → Publish to Roblox As...** → crie um place novo (público, com acesso liberado para cópia se você quiser que outros o abram). Os cenários rodam sozinhos; o HUD tem os botões de reiniciar. Cole o link no README e no post.

## 5. GIFs para o README e o post

Nenhum foi gravado. Cenas sugeridas (uma por GIF, ~8 s, câmera de cima, lado a lado):

1. **Plataforma de 18 studs (cenário 4).** O NPC clássico fica parado; o da SmartPath salta.
2. **Labirinto com gatilho invisível (cenário 5).** Idem, com a rota da SmartPath desenhada (`Debug = true` já vem ligado no demo).
3. **Caverna (cenários 9 a 11).** O clássico sobe pelo teto; a SmartPath entra, anda dentro e sai.
4. **Sala com porta estreita (cenário 2).** O clássico não sai do lugar; a SmartPath chega, com o disco do raio laranja (reduzido).
5. **20 NPCs (cenário 8).** Os dois lados, com o HUD mostrando o FPS.

Grave com o gravador do Studio (Ctrl+Shift+F12 no editor) ou uma ferramenta de captura de tela, converta para GIF e salve em `docs/media/`.

## 6. Post no DevForum

Categoria **Community Resources**. O rascunho está em [DEVFORUM_POST.md](DEVFORUM_POST.md): troque os `[GIF]` e os links antes de postar.
