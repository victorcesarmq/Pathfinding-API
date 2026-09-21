"""Gera dist/SmartPath.bundle.lua: todos os módulos de src/SmartPath num único arquivo.

Uso (na raiz do repositório):  python tools/bundle.py

Os módulos entram sem alteração de lógica. Cada um vira uma função que recebe o seu `script` e o seu
`require`, então `require(script.Parent.Util)` continua funcionando dentro do arquivo. As únicas mudanças
no texto são: tirar `--!strict` (o arquivo todo é `--!nocheck`) e trocar `export type` por `type`
(`export type` só vale no topo de um módulo, e aqui cada módulo está dentro de uma função).

O gerador confere que todo `require` aponta para um módulo que existe e que não há dependência circular,
e escreve os módulos na ordem em que dependem uns dos outros.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src", "SmartPath")
OUT = os.path.join(ROOT, "dist", "SmartPath.bundle.lua")

ENTRY = "SmartPath"  # init.luau
SKIPPED = {"DECISIONS.luau"}  # espelho em texto do DECISIONS.md; nada o usa

REQUIRE = re.compile(r"\brequire\(\s*script(?:\.Parent)?\.(\w+)\s*\)")
ANY_REQUIRE = re.compile(r"\brequire\(")


def read_modules() -> dict[str, str]:
    modules: dict[str, str] = {}
    for filename in sorted(os.listdir(SRC)):
        if not filename.endswith(".luau") or filename in SKIPPED:
            continue
        name = ENTRY if filename == "init.luau" else filename[: -len(".luau")]
        with open(os.path.join(SRC, filename), encoding="utf-8") as f:
            modules[name] = f.read().replace("\r\n", "\n")
    return modules


def code_only(source: str) -> str:
    """O texto sem os comentários de linha, para não achar `require` dentro de comentário."""
    return "\n".join(re.sub(r"--.*$", "", line) for line in source.split("\n"))


def dependencies(modules: dict[str, str]) -> dict[str, list[str]]:
    deps: dict[str, list[str]] = {}
    for name, source in modules.items():
        code = code_only(source)
        found = REQUIRE.findall(code)
        if len(found) != len(ANY_REQUIRE.findall(code)):
            sys.exit(f"{name}: há um require que não é da forma require(script.Parent.X) nem require(script.X)")
        for dep in found:
            if dep not in modules:
                sys.exit(f"{name}: requer '{dep}', que não existe em src/SmartPath")
        deps[name] = sorted(set(found))
    return deps


def order(deps: dict[str, list[str]]) -> list[str]:
    result: list[str] = []
    state: dict[str, int] = {}  # 1 = visitando, 2 = pronto

    def visit(name: str, trail: list[str]) -> None:
        if state.get(name) == 2:
            return
        if state.get(name) == 1:
            sys.exit("dependência circular: " + " -> ".join(trail + [name]))
        state[name] = 1
        for dep in deps[name]:
            visit(dep, trail + [name])
        state[name] = 2
        result.append(name)

    for name in sorted(deps):
        visit(name, [])
    return result


def transform(source: str) -> str:
    lines = source.split("\n")
    if lines and lines[0].strip() == "--!strict":
        lines = lines[1:]
    text = "\n".join(lines)
    text = re.sub(r"(?m)^export type ", "type ", text)
    return text.strip("\n")


HEADER = """--!nocheck
--!nolint
--[[
	SmartPath @@VERSION@@ — bundle em um único arquivo.

	Gerado por tools/bundle.py a partir de src/SmartPath. Não edite aqui: edite os módulos e gere de novo.

	Como usar:
	  1. Crie um ModuleScript (o nome que quiser, por exemplo "SmartPath") em ReplicatedStorage.
	  2. Cole este arquivo inteiro nele.
	  3. local SmartPath = require(game.ReplicatedStorage.SmartPath)

	Módulos incluídos (@@COUNT@@): @@NAMES@@.
	Cada um está dentro de uma função e só é executado na primeira vez que alguém o requer.
]]

local realRequire = require

local sources: {[string]: (any, any) -> any} = {}
local cache: {[string]: { value: any }} = {}
local loading: {[string]: boolean} = {}
local handles: {[string]: any} = {}
local bundled: {[any]: string} = {}

-- Faz o papel do `script` de cada módulo: `script.Parent.Util` e, no módulo principal, `script.Util`.
local root: any = setmetatable({ Name = "@@ENTRY@@" }, {
	__index = function(_, key)
		return handles[key]
	end,
})
bundled[root] = "@@ENTRY@@"

local function load(name: string): any
	local done = cache[name]
	if done then
		return done.value
	end
	if loading[name] then
		error("SmartPath (bundle): dependência circular em " .. name, 3)
	end
	loading[name] = true
	local handle = if name == "@@ENTRY@@" then root else handles[name]
	local value = sources[name](handle, function(target: any)
		local targetName = bundled[target]
		if targetName then
			return load(targetName)
		end
		return realRequire(target)
	end)
	loading[name] = nil
	cache[name] = { value = value }
	return value
end
"""


def build() -> str:
    modules = read_modules()
    if ENTRY not in modules:
        sys.exit("src/SmartPath/init.luau não encontrado")
    deps = dependencies(modules)
    sequence = order(deps)

    version = "1.0.0"
    match = re.search(r'Version\s*=\s*"([^"]+)"', modules[ENTRY])
    if match:
        version = match.group(1)

    parts = [
        HEADER.replace("@@VERSION@@", version)
        .replace("@@COUNT@@", str(len(modules)))
        .replace("@@NAMES@@", ", ".join(sequence))
        .replace("@@ENTRY@@", ENTRY),
    ]
    for name in sequence:
        if name != ENTRY:
            parts.append(f'handles["{name}"] = {{ Name = "{name}", Parent = root }}\nbundled[handles["{name}"]] = "{name}"')
    parts.append("")

    for name in sequence:
        origin = "init.luau" if name == ENTRY else f"{name}.luau"
        parts.append(f"-- ============================== {origin} ==============================")
        parts.append(f'sources["{name}"] = function(script: any, require: any): any')
        parts.append(transform(modules[name]))
        parts.append("end")
        parts.append("")

    parts.append(f'return load("{ENTRY}")')
    parts.append("")
    return "\n".join(parts)


def main() -> None:
    text = build()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(f"ok: {os.path.relpath(OUT, ROOT)} ({len(text.splitlines())} linhas, {len(text) // 1024} KB)")


if __name__ == "__main__":
    main()
