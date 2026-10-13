# mbrcli — Interpretador de MBR em Zig

Projeto prático de Sistemas Operacionais. O `mbrcli` lê o setor inicial de uma imagem binária de disco e mostra o identificador do disco, as quatro entradas da tabela MBR, os cálculos em setores/bytes e avisos de consistência.

## Requisitos

- Zig **0.16.0**.
- Nenhuma biblioteca externa.
- Uma imagem de disco de teste que tenha pelo menos 512 bytes. Para a validação do limite das partições, use uma imagem completa, não apenas um setor MBR isolado.

## Compilar

```sh
zig version
# deve mostrar 0.16.0
zig build
```

O executável ficará disponível em `zig-out/bin/mbrcli` (ou `zig-out/bin/mbrcli.exe` no Windows).

## Executar

```sh
zig build run -- fixtures/valid-mbr.img
```

Ou execute diretamente o binário:

```sh
./zig-out/bin/mbrcli fixtures/valid-mbr.img
```

No Windows, use `zig-out\bin\mbrcli.exe fixtures\valid-mbr.img`.

O programa espera exatamente um argumento: o caminho da imagem. Arquivo inexistente, sem permissão ou menor que 512 bytes gera uma mensagem de erro e código de saída diferente de zero.

## Testes

```sh
zig build test
```

Os testes são unitários e montam setores MBR em memória; não exigem disco físico, privilégios administrativos ou imagem específica. As declarações `test` ficam nos módulos puros (`src/mbr.zig` e `src/validation.zig`), e `build.zig` cria os executores de teste separados. Cobrem conversão little-endian, MBR válido vazio, uma e quatro entradas, assinatura inválida, setor truncado, flag de boot inesperada, entrada preenchida com zero setores, LBA 0, sobreposição, partição além da imagem e tratamento de tipos especiais.

## Exemplos de imagens

- `fixtures/valid-mbr.img`: imagem pequena com uma partição Linux válida.
- `fixtures/invalid-signature.img`: imagem com assinatura MBR incorreta.
- `fixtures/overlapping.img`: imagem com duas entradas de partição cujos intervalos se sobrepõem.
- `fixtures/out-of-bounds.img`: imagem em que a partição declarada termina após o fim do arquivo.

As imagens são fixtures sintéticas criadas para este exercício.

## Exemplos de saída

Saída resumida para `zig build run -- fixtures/valid-mbr.img`:

```text
MBR Inspector
Arquivo: fixtures/valid-mbr.img
Tamanho da imagem: 4096 bytes
Assinatura: válida (55 AA)
Identificador do disco: 0xA1B2C3D4

Partição 1
  Inicializável: sim (flag 0x80)
  Tipo: 0x83 (Linux)
  LBA inicial: 1
  Setores: 4
  Offset inicial: 512 bytes
  Tamanho: 2048 bytes (0.0020 MiB)
  LBA final inclusivo: 4
Partição 2: vazia
Partição 3: vazia
Partição 4: vazia

Verificações de consistência
Nenhum aviso encontrado.
```

Para `zig build run -- fixtures/invalid-signature.img`, o relatório mostra `Assinatura: INVÁLIDA` e acrescenta o aviso `assinatura MBR ausente ou incorreta`. As demais fixtures demonstram os avisos de sobreposição, limite além do arquivo e zero setores.

## Decisões de implementação

- O programa valida previamente o caminho para aceitar somente arquivos regulares, abre em modo somente leitura e busca apenas os primeiros 512 bytes; a imagem inteira não é carregada em memória.
- A decodificação usa offsets e tamanhos especificados pelo formato, sem converter os 16 bytes diretamente em uma `struct` Zig. Isso evita dependência de padding, alinhamento e endianness da máquina.
- Os inteiros LBA são decodificados manualmente como little-endian de 32 bits. Os cálculos de offsets, tamanho e LBA final usam `u64` para evitar overflow com os valores máximos dos campos de origem.
- Uma entrada só é vazia se seus 16 bytes forem todos zero. Uma entrada preenchida que informa zero setores gera aviso separado.
- Os tipos estendidos (`0x05`, `0x0F`, `0x85`) e o MBR protetor GPT (`0xEE`) são identificados e excluídos da comparação de sobreposição como partições comuns. Este programa não interpreta EBRs nem a tabela GPT.
- Assinatura incorreta e inconsistências estruturais são relatadas como avisos para que o relatório ainda possa ajudar a inspecionar bytes de entrada malformados. O código não modifica o arquivo analisado.
- I/O usa as APIs `std.Io` da versão 0.16.0.

## Checklist de requisitos

- [x] Abre arquivo em modo somente leitura e lê no máximo os 512 bytes iniciais.
- [x] Trata arquivo inexistente, erro de acesso e arquivo menor que 512 bytes.
- [x] Valida assinatura `55 AA` e mostra identificador de disco little-endian.
- [x] Interpreta as quatro entradas da tabela primária.
- [x] Lista entradas vazias e calcula offset, tamanho, MiB e LBA final inclusivo.
- [x] Identifica os tipos de partição requeridos pelo enunciado.
- [x] Verifica flags, zero setores, LBA 0, fim da imagem e sobreposições.
- [x] Inclui testes automatizados e fixtures sintéticas.
- [x] Não chama `fdisk`, `parted`, `lsblk` nem bibliotecas de decodificação MBR.

## Colaboração sugerida

Crie Issues para leitura/CLI, decodificação, validações, testes e documentação. Desenvolva em branches e abra Pull Requests pequenos, incluindo os testes executados. Cada integrante deve registrar suas responsabilidades reais e revisar código de outra pessoa; não invente contribuições no README.

## Limitações conhecidas

O código reporta o código histórico do tipo MBR, que não comprova qual sistema de arquivos está de fato presente. Não monta partições, não examina sistemas de arquivos, não interpreta partições lógicas encadeadas por EBR e não decodifica GPT.

## Conceitos para a apresentação

- **Partição versus sistema de arquivos:** a partição define uma região do dispositivo; um sistema de arquivos é uma estrutura de dados que pode existir dentro dela. O código do tipo MBR não confirma qual sistema de arquivos está realmente presente.
- **Quatro entradas primárias:** a tabela MBR ocupa 64 bytes do setor, divididos em quatro entradas de 16 bytes. O particionamento estendido permite descrever partições lógicas por meio de EBRs, que este projeto não percorre.
- **Little-endian:** o byte menos significativo vem primeiro. Assim, `00 08 00 00` representa `0x00000800`, ou `2048`.
- **LBA para bytes:** multiplica-se o LBA inicial por 512. Por exemplo, LBA `2048` corresponde ao offset `1.048.576` bytes.
- **Por que não mapear diretamente para uma `struct`:** padding, alinhamento, endianness da máquina e layout de memória não devem determinar como os bytes externos são lidos. O parser usa os offsets definidos pelo formato e converte os inteiros explicitamente.
- **MBR protetor de GPT:** uma entrada do tipo `0xEE` sinaliza um disco GPT para ferramentas antigas que só conhecem MBR. Este programa apenas identifica essa entrada; não interpreta a tabela GPT.
- **Validação de entrada não confiável:** dados malformados podem causar cálculos incorretos, intervalos fora da imagem, sobreposições ou falsos relatórios. Por isso são usados limites explícitos, aritmética `u64` e diagnósticos.
- **Contribuição em equipe:** Issues registram o trabalho planejado; branches isolam as mudanças; Pull Requests mostram o diff, testes e revisão. O histórico deve refletir o trabalho real de cada pessoa.
