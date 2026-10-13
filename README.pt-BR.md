# CS.Coder Block Folding (beta)

> [!WARNING]
> **VERSÃO BETA.** O CS.Coder Block Folding está em beta: ainda está em teste e pode ter defeitos.
> Ele não altera os seus arquivos-fonte, mas trabalha dentro do editor de código: salve o
> seu trabalho com frequência enquanto testa.
> Se encontrar algum problema, avise abrindo uma
> [issue](https://github.com/cscoder69/delphi-block-folding/issues).

[English](README.md) | **Português (Brasil)**

**Versão:** 0.26.10.12a (beta) · **Licença:** [MIT](LICENSE.txt), gratuito e de código
aberto ([resumo em português](LICENCA.txt)) · **Delphi:** 11, 12 e 13 ·
[**Baixar**](https://github.com/cscoder69/delphi-block-folding/releases)

O CS.Coder Block Folding é uma extensão para o editor de código do Delphi que dobra
blocos de comandos. O Delphi dobra rotinas, classes e regiões; o Block Folding complementa
isso com os blocos de dentro da rotina, para ler um método longo um nível de cada vez. Ele
não altera o seu fonte.

![Editor de código do Delphi com blocos if, else, while e case dobrados](docs/screenshots/folded-blocks.png)

*Os blocos dobrados mostram uma caixinha depois da primeira linha. A unit da imagem é o
exemplo que vem no repositório.*

## Resumo

- **Blocos de comandos.** `if` com o `else`, `for`, `while`, `with`, `try`, `case`,
  `repeat`, `asm` e `begin..end` isolado.
- **Teclado.** **Ctrl+Alt+B** dobra o bloco em volta do cursor e, na primeira linha de um
  bloco dobrado, abre. **Ctrl+Alt+Shift+B** abre todas as dobras da unit.
- **Mouse.** Sinais `−` e `+` ao lado do código dobram e abrem com um clique.
- **Você escolhe.** Cada tipo de bloco, os atalhos e o texto mostrado na linha dobrada
  podem ser mudados nas configurações.
- **Seu fonte fica como está.** Nenhum `{$REGION}` é inserido e nada é gravado no arquivo.
  As dobras valem enquanto a unit está aberta.

## Instalação

Funciona no Delphi 11 (IDE de 32 bits) e no Delphi 12 e 13 (IDE de 32 e de 64 bits). Não
precisa de compilador nem de administrador.

1. **Baixe** `CSCoderBlockFolding-<versão>.zip` na
   [página de Releases](https://github.com/cscoder69/delphi-block-folding/releases), em
   **Assets**. Não escolha "Source code": esse não tem o instalador.
2. **Extraia** o zip inteiro em uma pasta à sua escolha.
3. **Feche o Delphi.**
4. **Execute `Install.bat`.** Ele instala para o usuário atual do Windows em todos os
   Delphi compatíveis que encontrar.
5. **Abra o Delphi.** Os comandos ficam no menu principal, em **CS.Coder > Block Folding**.

**Atualizar:** execute o `Install.bat` do zip mais novo, com o Delphi fechado. Suas
configurações são mantidas.

**Desinstalar:** `Uninstall.bat` remove a extensão e mantém as configurações.
`Uninstall.bat /data` apaga também as configurações e o log de diagnóstico.

## Novidades

**0.26.10.12a** é a primeira versão pública. As notas de todas as versões estão na
[página de Releases](https://github.com/cscoder69/delphi-block-folding/releases).

## Bom saber

- Os sinais do mouse aparecem quando a dobra de código da própria IDE está desligada.
- Corpo de rotina, classes e regiões continuam sendo dobrados pelo próprio Delphi. Um
  bloco que contém um `{$REGION}` não é dobrado pelo Block Folding.
- A tela Sobre acompanha o idioma do Windows. O menu e a janela de configurações estão em
  português nesta versão.
- As configurações ficam no registro do Windows, um conjunto por versão do Delphi. Um log
  do que a extensão fez, para suporte, fica só no seu computador, em
  `%LOCALAPPDATA%\CSCoder\BlockFolding`. A rede não é usada.

A documentação completa está na
[página do produto](https://www.cscoder.com.br/projetos/block-folding-delphi/).

## Compilar a partir do código

`build-plugin.ps1 -Version 11|12|13 [-Ide64]` compila o pacote com os compiladores de
linha de comando do Delphi. Informe as pastas do seu Delphi no início do script. Um
`.dpk`, em `src/plugin/`, serve às três versões do Delphi.

## Outras ferramentas CS.Coder

- [CS.Coder Hub de Projetos](https://github.com/cscoder69/delphi-project-hub): atalhos de
  projetos organizados em categorias e grupos, na Welcome Page do Delphi.
- [CS.Coder Unit Styler](https://github.com/cscoder69/delphi-unit-styler): organiza as
  cláusulas `uses` das units do seu projeto.

## Suporte

Abra uma [issue](https://github.com/cscoder69/delphi-block-folding/issues) para problemas e
sugestões. Pull requests são bem-vindos. Contato: contato@cscoder.com.br

## Licença

Distribuído sob a [Licença MIT](LICENSE.txt). Copyright (c) 2026 CS.Coder.

"Delphi" e "RAD Studio" são marcas da Embarcadero Technologies, Inc. O CS.Coder Block
Folding é um projeto independente. Não é afiliado, mantido nem endossado pela Embarcadero.
