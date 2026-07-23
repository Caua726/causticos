# Caustic Standard Image Format (CSIF) — Especificação

> **Status:** especificação de design (v1 do papel). Formato PRÓPRIO do causticos, irmão do CSE.
> **Filosofia:** explícito (sem mágica/implícito), container = mecanismo / codec = política,
> op-set fechado por codec (sem ioctl), memória limitada (tiling), DRY (toolkit compartilhado).
> Container codec-agnóstico: um `codec_id` seleciona o decoder de um registry versionado.
> Gerada a partir de pesquisa dos formatos estado-da-arte (JPEG XL, AVIF, HEIF, JPEG 2000, OpenEXR,
> WebP, PNG/APNG, KTX2/Basis, DNG/RAW, C2PA, JBIG2, vetor) — ver `docs/CSIF_RATIONALE.md` para o
> veredito do que faltava no v1 e o que entrou.

## Índice

0. [0. Filosofia & princípios de design](#0-filosofia--princpios-de-design)
1. [1. Container & chunks (byte-exact)](#1-container--chunks-byteexact)
2. [2. Pipeline de cor & HDR (CICP/ICC)](#2-pipeline-de-cor--hdr-cicpicc)
3. [3. Entropy coder (rANS) — bit-exact](#3-entropy-coder-rans--bitexact)
4. [4. Toolkit compartilhado (color/transform/predict)](#4-toolkit-compartilhado-colortransformpredict)
5. [5. Codecs lossless (RAW, QOI, MODULAR)](#5-codecs-lossless-raw-qoi-modular)
6. [6. Codec DCT lossy (classe JPEG)](#6-codec-dct-lossy-classe-jpeg)
7. [7. Codec BLOCK lossy moderno (classe AVIF/VarDCT)](#7-codec-block-lossy-moderno-classe-avifvardct)
8. [8. Codec NEURAL (aprendido) + runtime](#8-codec-neural-aprendido--runtime)
9. [9. Progressivo, ROI, animação, aux, thumbnails](#9-progressivo-roi-animao-aux-thumbnails)
10. [10. Segurança, resiliência, conformance, test vectors](#10-segurana-resilincia-conformance-test-vectors)
11. [11. Texturas GPU & transcoding (KTX2/Basis-class)](#11-texturas-gpu--transcoding-ktx2basisclass)
12. [12. Modos de captura & especiais (RAW, bilevel, vetor)](#12-modos-de-captura--especiais-raw-bilevel-vetor)
13. [13. Proveniência (C2PA), métricas & tuning](#13-provenincia-c2pa-mtricas--tuning)

---

I have a precise picture of CSE conventions and the project's philosophy vocabulary. Now I'll write Section 0.

## 0. Filosofia & princípios de design

> **Status:** normativa. Esta seção fixa os princípios, os objetivos, a relação de família com o CSE, a política de versionamento/forward-compat, a visão geral dos perfis de conformidade e as convenções de unidades (endianness, alinhamento, tipos inteiros) usadas por **todo** o resto da especificação. Onde uma seção posterior parecer conflitar com esta, **esta seção vence** — ela é o contrato.

---

### 0.1 O que é o CSIF

O **CSIF** (*Caustic Standard Image Format*) é o formato de imagem **nativo** do causticos: o irmão do CSE (*Caustic Standard Executable*) no domínio de pixels. Assim como o CSE é "o ELF, mas nosso", o CSIF é "o JPEG XL/AVIF/HEIF/OpenEXR, mas nosso" — projetado do zero para ser **state-of-the-art** (classe JPEG XL / AVIF) e, ao mesmo tempo, **estritamente fiel à filosofia Caustic**.

O CSIF persegue dois objetivos que a maioria dos formatos trata como mutuamente exclusivos:

1. **Mundialmente competitivo (world-class).** Compressão sem perdas mais forte que PNG (predição auto-corretiva + modelagem de contexto + LZ + rANS), perceptual com perdas classe JPEG XL/AVIF (DCT de bloco variável + quantização adaptativa + filtros in-loop), wavelet escalável (resolução + qualidade) classe JPEG 2000, HDR/float/wide-gamut/canais nomeados classe OpenEXR, contêiner codec-agnóstico com imagens derivadas e auxiliares classe HEIF, texturas de bloco GPU classe KTX2/Basis, RAW de captura classe DNG, bilevel/document classe JBIG2/G4, indexado/animação classe PNG/APNG/GIF, vetor híbrido para ícones, e proveniência criptográfica classe C2PA. Nenhuma capacidade dessas é "futuro vago" — cada uma é um slot de interface honesto, real ou sequenciado para implementação posterior (§0.6, §0.9).

2. **100% Caustic.** Tudo declarado, nada mágico; mecanismo separado de política; conjunto fechado e honesto de operações por tipo; sem alocação escondida e memória limitada; DRY via um toolkit compartilhado; uma família de formatos com as mesmas convenções do CSE. Onde uma feature SOTA exigiria comportamento implícito/heurístico, o CSIF a **redesenha** para ser explícita (ver §0.3) em vez de copiá-la.

O nome de tipo do contêiner é **CSIF**; a extensão canônica é **`.csif`**; o magic é `"CSIF"` (ver §0.10 e a seção de contêiner). Daqui em diante, "o formato" significa o CSIF v1.

---

### 0.2 A filosofia Caustic aplicada ao formato

A filosofia do causticos — *"tudo é uma chave; o kernel é mecanismo, o userspace é política; conjunto fechado e honesto de operações por tipo; sem mágica; falha alto"* — não é uma analogia distante para um formato de imagem: ela mapeia **um para um**. As sete regras abaixo são **normativas**. Cada decisão de design em qualquer seção desta especificação DEVE ser justificável por pelo menos uma delas, e NÃO PODE violar nenhuma.

#### Regra 1 — Explícito, sem mágica, sem implícito ("toda operação é visível")

Cada campo é declarado. Não há heurística para adivinhar formato, colorimetria, gamma, primárias, matriz, faixa (range), endianness, alinhamento ou layout de amostra. **O arquivo é 100% auto-descritivo:** um leitor sabe tudo o que precisa a partir dos cabeçalhos, sem nenhum conhecimento fora-de-banda.

Consequências normativas (todas reforçadas em seções posteriores):

- **Sem defaults que mudam comportamento.** A *ausência* de uma estrutura nunca é interpretada como um valor implícito. Se uma propriedade é necessária para decodificar ou para renderizar corretamente, ela é declarada — não "se ausente, assuma sRGB", não "se ausente, assuma 8-bit", não "se ausente, assuma opaco". O code-point CICP `2 = Unspecified` é **proibido** em todos os quatro campos de cor (ver a seção de cor). Faixas e *fill* de paletas, premultiplicação de alpha, ordem de varredura, ordem de bytes — tudo é um campo, nunca uma convenção.
- **Sem canais laterais.** Nenhuma informação carregada "no jeito que os bytes estão arranjados" (ex.: tamanho de paleta inferido do número de bytes, modo de transparência inferido do comprimento de um array, blocos de transformada inferidos do conteúdo). Onde um formato de referência infere, o CSIF declara.
- **Endianness e alinhamento sempre declarados.** O CSIF fixa little-endian (§0.10) — mas o fato é **escrito** no cabeçalho, não pressuposto. Proíbe-se a abordagem do TIFF (flag de byte-order por arquivo que troca o parser inteiro) por ser exatamente a mágica/comportamento-implícito que a filosofia rejeita, e uma classe conhecida de bug de parser-differential.
- **Parsing dirigido por offsets, nunca por varredura de marcador.** Cada chunk traz comprimento explícito; o leitor avança por `(cabeçalho + length + crc)` e nunca varre o stream procurando bytes de sincronismo (ao contrário do JPEG baseline). Isso limita o tempo de parse e elimina ataques de marker-injection/parser-differential.
- **Codificação canônica.** Dois streams de bytes válidos NÃO PODEM parsear para duas estruturas diferentes. Há uma única serialização por estrutura (ordem de campos fixa, codificação inteira fixa). Isso sustenta vetores-de-conformança golden (uma estrutura por stream de bytes) e mata bugs de parser-differential.

#### Regra 2 — Conjunto de operações fechado e honesto por tipo (como "tudo é uma chave", sem `ioctl`)

Cada *kind* de coisa endereçável no CSIF expõe um conjunto **fechado, completo e honesto** de operações, espelhando a vtable de `KObject` do kernel ("um surface tem `mmap`+`present`; um canal tem `read`/`write`"). Concretamente:

- **Codecs.** Cada codec do registro expõe exatamente a interface `{decode, encode}` (ampliada de forma declarada quando o *kind* genuinamente tem mais: p.ex. o transcodificador JPEG expõe `{decode, encode, reconstruct_source}`; um codec GPU transcodável expõe `decode(target_codec_id)`; um codec vetorial recebe `target_w/target_h/dpi` no `decode`). **Não há `ioctl`, não há escape hatch, não há canal lateral que contorne o contêiner.** Um `codec_id` desconhecido falha **alto e explícito** (§0.3, §0.6), nunca é "adivinhado".
- **Toolkit.** Cada módulo do toolkit compartilhado (entropy, color, transform, predict, lz, perceptual, raster2d, geom) expõe um conjunto fechado de funções puras (ex.: o substrato de entropia expõe exatamente `{init, decode_sym, encode_sym, flush}`). Nada de comportamento aprendido/oculto no decode.
- **Derivações de contêiner.** Imagens derivadas (identity/grid/overlay) são despachadas por um `deriv_id` de um registro **fechado** com uma interface uniforme `{assemble}` — o espelho, no nível do contêiner, do registro de codecs.
- **Métricas, watermarks, esquemas de soft-binding** etc. seguem o mesmo padrão: um registro fechado, indexado por id, com uma interface uniforme.

A *uniformidade do selo* (a "costura" container↔codec, container↔derivação, codec↔toolkit) é deliberada e idêntica em todo o sistema — é a vtable de `KObject` do kernel reaparecendo em cada camada.

#### Regra 3 — Mecanismo vs. política em um arquivo

O **contêiner é mecanismo**: estrutura (chunks TLV, diretório, tabelas de índice/offset) + despacho por `codec_id`/`deriv_id`. **Os codecs são política**: *como* comprimir. **O contêiner NUNCA embute um codec.** É exatamente isto que torna "todos os algoritmos funcionam" arquiteturalmente verdadeiro: adicionar um codec é uma entrada de registro, não uma mudança no contêiner.

Generalizando para o resto da especificação:

- Como o encoder escolheu blocos, quantização, parse LZ, mapas de saliência, demosaico, fator de qualidade etc. é **política do encoder** e **nunca** afeta o decode. O decode lê apenas campos declarados — é puramente mecânico e determinístico.
- O contêiner carrega; o codec/renderer interpreta. O contêiner valida byte-ranges, aciclidade, reconciliação de geometria e limites (Regra 5) **antes** de qualquer codec rodar, mas não inspeciona o interior dos bytes de codec.
- "Política do leitor" (paralelismo, escolha de tile a decodificar, escolha de thumbnail por tamanho, escolha de alvo GPU, mapa de confiança de assinatura) é separada do mecanismo declarado; o arquivo descreve a estrutura, o leitor escolhe a travessia.

#### Regra 4 — Sem workarounds, sem impls ocas, completo & correto

Codecs reais ou **slots de interface reais honestamente sequenciados** — **nunca** um decodificador falso que finge funcionar. O design é **fechado antes de construir** (sem YAGNI/MVP que deixe buracos de design): cada feature é especificada por inteiro agora, mesmo que a implementação chegue depois como um slot honesto (§0.6, §0.9). Um decodificador conformante não pode "passar" produzindo pixels diferentes de outro: o decode com perdas é **bit-exato** contra inversos fixed-point especificados; o decode sem perdas é bit-exato contra os pixels de referência (ver a seção de conformança). A única liberdade de ponto-flutuante permitida é na *busca* do encoder, jamais no decode.

#### Regra 5 — Sem alocação escondida; buffers explícitos; memória limitada

Nada de alocação implícita; o toolkit opera em buffers fornecidos pelo chamador com scratch limitado (estilo stdlib freestanding/non-allocating do causticos). **Toda dimensão e teto de recurso é declarado *antes* de qualquer alocação**, e calculado em aritmética alargada (u64/u128 intermediário) contra um teto declarado, de modo que overflow de `width*height*channels*bytes` é impossível por construção (a classe de bug do WebP CVE-2023-4863 / BLASTPASS). Em particular:

- **Tiling ⇒ memória limitada + decode parcial.** Cada tile/level/unidade é independentemente decodificável a partir de um índice de byte-ranges explícito; o working set é uma função de campos declarados (tamanho de tile, tamanho de level), computável adiantado. O decode de qualquer unidade requer memória limitada por aquela unidade + scratch declarado do codec — nunca um buffer da imagem inteira.
- **Estruturas de metadados/feature também são limitadas.** Há tetos declarados para tudo que o mundo-real esquece de limitar: máximo de pixels, máximo de pixels por tile, máximo de bytes a alocar, máximo de chunk, máximo de canais auxiliares, máximo de frames de referência, profundidade máxima de árvore-MA, máximo de splines/patches, profundidade máxima de derivação, fan-in máximo, profundidade máxima de snapshot de animação. Recursão de derivação é **acíclica** com profundidade e fan-in limitados (mata "decompression bomb por recursão").
- **Falha alta, limitada, com erro preciso.** Qualquer violação (range pendurado/sobreposto, dimensão fora do teto, chunk crítico desconhecido, derivação cíclica, geometria que não reconcilia, CRC errado, perfil/level não suportado, dicionário externo ausente, offset fora da janela LZ) é um erro numerado, reportado com o campo/offset ofensor — **nunca** clamp silencioso, nunca garbage silencioso, nunca hang. Isto espelha o `cse.cst` rejeitando `mem_size < file_size` e `file_off+file_size > cst_size` com códigos negativos, e a postura B2 do kernel ("falha alto, sem hang").

#### Regra 6 — DRY: um toolkit compartilhado reusado por todos os codecs

Há **um** substrato compartilhado, e nada é reimplementado por codec:

- `entropy` — o substrato de entropia (rANS estático intercalado por padrão, + modo CDF adaptativo, + prefix-code, + raw passthrough), com modelagem de contexto, tokenização inteira híbrida, mapeamento signed/zigzag/zero-run, e um codificador binário por intervalo (classe MQ) como primitiva irmã. Despachado por `entropy_method_id` (a mesma costura de vtable que o registro de codecs).
- `color` — RGB↔YCbCr/YCgCo-R, a família RCT reversível, transferências (sRGB/PQ/HLG/linear/gamma paramétrica), o transform classe-XYB para métricas perceptuais.
- `transform` — DCT (8×8 e tamanhos variáveis), DWT (5/3 reversível, 9/7 irreversível), Squeeze (sub-banda reversível), WHT/identity, paleta/delta-paleta.
- `predict` — filtros PNG (None/Sub/Up/Average/Paeth), gradiente, o preditor ponderado auto-corretivo, a árvore-MA.
- `lz` — match-finder + tokens (literal/length/offset), rep-offsets, remap 2D de distância, LDM.
- `perceptual` — campo de quantização adaptativa, mapas de mascaramento/saliência, o selo de RDO (`rdo_cost`), síntese de grão de filme.
- `raster2d` / `geom` — flatten de Bézier, scan-conversion com AA analítico, avaliação de gradiente, expansão de stroke, affine fixed-point (para o codec vetorial; também linkável pelo compositor do WM).
- `hash` — CRC-32 (IEEE e Castagnoli), hash forte (classe BLAKE3), e o pipeline de assinatura/verificação.

Sub-imagens são um conceito de primeira classe (um descritor `SubImage` declarado): alpha, a imagem DC/LF, o campo de quant adaptativa, mapas de correlação de cor e canais extras são **todos** sub-streams Modular declarados pelo mesmo motor — não há codepath one-off por feature.

#### Regra 7 — Família de formatos próprios do causticos (mesmas convenções do CSE)

O CSIF compartilha as convenções estruturais do CSE (e do resto da família): `magic + version + flags` no cabeçalho; estrutura TLV de chunks/segmentos com offsets e comprimentos explícitos; tabela/diretório de comprimento fixo; forward-compat via chunks puláveis (skippable). A disciplina de "header de 32 bytes + tabela de stride fixo, nunca caçar bytes de sync" do CSE é replicada (§0.10). Ver §0.4 para o detalhamento da relação CSE↔CSIF.

#### Regra 8 — Estender o toolchain quando necessário, em vez de hackear

Se uma capacidade exige suporte do toolchain (uma nova primitiva no toolkit, um novo tipo no contêiner, um novo tipo rational/fixed-point para matemática exata de captura), **estende-se o toolchain** — não se faz um band-aid no codec nem se finge a impl. Fundação (toolkit, contêiner) antes de feature; design fechado antes de implementar em qualquer objeto fundador.

---

### 0.3 Redesenhos Caustic de features SOTA "mágicas"

Várias capacidades de classe mundial, **como concebidas nos formatos de referência, violam a Regra 1** (implícitas/heurísticas). O CSIF as adota pelo *benefício*, mas as **redesenha para serem explícitas**. Esta tabela é normativa: implementações DEVEM seguir a coluna "forma Caustic", não a forma original.

| Feature SOTA | Forma original (mágica) | Forma Caustic (explícita) — normativa |
|---|---|---|
| Sinalização de cor | CICP `2 = Unspecified` permitido; sRGB assumido na ausência | `Unspecified` **proibido** nos quatro campos; cor 100% determinada por cabeçalho (CICP) (+ICC opcional com precedência **declarada**); decodificador falha alto em cor sub-especificada |
| Disposição de chunk (PNG) | crítico/ancilar/safe-to-copy escondidos no *case* das letras ASCII do tipo | um campo `flags:u32` por chunk com bits nomeados (`CRITICAL`, `PUBLIC`, `SAFE_TO_COPY`); o tipo de 4 bytes é um id opaco, *case* não carrega significado |
| ROI / Maxshift (JPEG 2000) | região *inferida* pelo decodificador a partir das magnitudes dos coeficientes | região **declarada** (rects/máscara + shift + prioridade) num chunk explícito; nenhuma inferência |
| Orientação (EXIF vs nativa) | precedência implícita ⇒ bug de dupla-rotação | orientação **nativa** é autoritativa, declarada; `Orientation` do EXIF é informativo e **deve ser ignorado** para render |
| Síntese de grão / ruído (AV1/JXL) | "alguma aleatoriedade" | PRNG **nomeado e totalmente especificado** + seed declarado + recorrência AR fixed-point ⇒ bit-reproduzível; opt-in e skippable |
| Splines / rasterização (JXL/SVG) | rasterização *implementation-defined* ⇒ readers discordam | rasterizador **mandado pela spec** (tolerância de flatten, modo de AA, espaço de interpolação de gradiente, fill-rule — todos campos); decode é função determinística das entradas |
| Transcode JPEG byte-exato | reconstrução escondida no codec | op declarada e separada `reconstruct_source` no conjunto fechado do codec; metadados estruturais como sub-stream totalmente especificado |
| `iloc` (ISOBMFF) com payload em qualquer lugar | offsets podem pendurar/sobrepor/apontar para fora | bytes de cada item **devem** residir dentro de um chunk IDAT-class declarado neste arquivo; loader valida `offset+length ⊆ chunk` e rejeita ranges pendurados/sobrepostos |
| Tamanho de tile de grid (HEIF) | inferido do primeiro tile | tamanho de tile é um campo explícito; dimensões de saída validadas contra os inputs montados |
| Ordem de transforms (`irot`/`imir`) | ambígua ⇒ bug de interop | ordem de aplicação **declarada na spec** + arquivo obrigado a armazenar em ordem canônica |
| Tamanho de paleta/packing (GIF/PNG) | tamanho implícito por log2/comprimento de array; índice transparente "mágico" | `entry_count`, `index_bits`, `pack_order` declarados; transparência é o canal alpha da cor indexada, sem índice mágico |
| Escolha de codec (encoder esperto) | heurística troca a representação silenciosamente | só a *decisão* é gravada (`codec_id` + params); não existe `codec_id = auto`; `content_class` opcional é metadado **advisory** que nunca muda o decode |
| Recompressão lossy genérica | qualidade `q=80` opaca e não-portável | qualidade é um par `(metric_id, target_value)` declarado, com `achieved_value` gravado |

Princípio geral: **onde um formato de referência adivinha, o CSIF declara.** O benefício de compressão/funcionalidade é preservado; a adivinhação é movida para o lado do encoder (política) e seu *resultado* é gravado como dado explícito que o decodificador lê mecanicamente.

---

### 0.4 Relação de família com o CSE

CSIF e CSE são **irmãos**: o mesmo desenho de família aplicado a dois domínios (executável vs. imagem). Compartilham as convenções; divergem onde os domínios genuinamente diferem.

**O que o CSIF herda do CSE (Regra 7):**

- **Cabeçalho `magic + version + flags`**, little-endian, em offsets fixos e documentados — exatamente o estilo do header de 32 bytes do CSE (`"CST_" + version + arch + flags`). O CSIF usa `"CSIF"` como magic; o cabeçalho declara `version:u16`, um byte de flags e o valor de endianness (§0.10).
- **Estrutura TLV com offsets/comprimentos explícitos** e um **diretório de stride fixo** (o análogo da tabela de segmentos do CSE com `vaddr/file_off/file_size/mem_size/perms` — nada inferido). O parsing é dirigido por offset, jamais por varredura de sync.
- **Validação "falha alto" no load.** O `cse.cst` rejeita `mem_size < file_size` e `file_off+file_size > cst_size`; o loader CSIF generaliza isto: todo byte-range de item ⊆ seu chunk, ids únicos, derivação acíclica/limitada, geometria que reconcilia, tetos pré-alocação (Regra 5).
- **Forward-compat por unidades puláveis.** O CSE versiona e congela; o CSIF versiona e usa o bit *skippable* por chunk (§0.5).
- **Disciplina de reprodutibilidade.** O causticos já valoriza imagens byte-idênticas (self-host byte-idêntico); a serialização canônica do CSIF (§0.2, Regra 1) e os vetores golden congelados no self-host (§0.6) carregam a mesma disciplina.

**Onde divergem (porque os domínios diferem):**

| Eixo | CSE (executável) | CSIF (imagem) |
|---|---|---|
| Unidade endereçável | segmento (vaddr/perms) | chunk + item + tile/level/frame/canal |
| Despacho de política | nenhum (loader fixo) | por `codec_id` (registro de codecs) e `deriv_id` (registro de derivações) |
| Tamanhos | u32 (offsets/sizes de segmento) | **u64 desde o início** (sem dualidade 32/64; sem escape clumsy estilo ISOBMFF `largesize`) |
| Integridade | nenhuma (v2) | CRC-32 por chunk + hash forte de arquivo inteiro (§0.10) |
| Versionamento | um `version` global, congelado no self-host | `version` global **mais** `codec_version` independente por codec (§0.5) |
| Tolerância a desconhecido | n/a | chunk crítico desconhecido = falha; ancilar desconhecido = pula (§0.5) |

CSE e CSIF **não** compartilham bytes: um `.cse` é um executável, um `.csif` é uma imagem; um não é polyglot do outro. O que compartilham é a *gramática de família* e o *ethos*. (Um `.csif` pode ser **carregado por** um programa `.cse`, mas isso é uso, não aninhamento de formato.)

---

### 0.5 Política de versionamento & forward-compatibility

O CSIF versiona em **três níveis independentes e explícitos**. Nada é implícito; um leitor sabe, a partir dos cabeçalhos, exatamente o que precisa entender.

**(1) Versão do contêiner — `version:u16` no cabeçalho.**
Governa a *gramática* do contêiner (estrutura de cabeçalho, diretório de chunks, regras de validação). Esta especificação define **`version = 1`**. A v1 é **congelada no self-host**, como a ABI de syscalls e o CSE. Um bump de `version` só ocorre para mudanças incompatíveis na *gramática*; novas features dentro da v1 chegam por **novos tipos de chunk** e **novos `codec_id`/`deriv_id`**, nunca sobrecarregando um chunk existente nem mudando comportamento silenciosamente.

**(2) Bit *skippable* por chunk — `flags` do chunk.**
Cada chunk declara `CRITICAL`, `PUBLIC`, `SAFE_TO_COPY` como bits explícitos (o redesenho Caustic do *case* ASCII do PNG, §0.3). A regra de forward-compat é **simétrica e explícita**:

- **Chunk desconhecido com `CRITICAL` setado ⇒ falha alta** (`E_CSIF_UNKNOWN_CRITICAL`), reportando o tipo + offset. Um leitor jamais renderiza ignorando algo que carrega pixels/estrutura.
- **Chunk desconhecido sem `CRITICAL` ⇒ pula** por `(offset + length)`, com `length` validado contra `max_chunk_size` antes do seek (sem overflow de seek). Isto cobre metadados/features opcionais (HDR volume, grão, proveniência, etc.) — um leitor antigo decodifica a imagem-base honesta e ignora a extensão.
- **`SAFE_TO_COPY`** diz a um editor se pode preservar um chunk desconhecido após editar pixels.
- *Conteúdo load-bearing nunca é skippable.* Em particular, para o codec Modular sem perdas, um *transform* desconhecido **não** pode ser pulado (pular quebra a reconstrução): o arquivo declara um `min_decoder_level` e o decodificador recusa **alto** em vez de mis-decodificar.

**(3) `codec_version` por codec — no descritor do codec.**
O blob de params de cada codec é um blob **fechado, próprio do codec e versionado**, cujo layout é definido pelo par `(codec_id, codec_version)`. O contêiner trata-o como bytes opacos e despacha por `codec_id` (mecanismo puro, Regra 3). Isto permite forward-compat **por codec, independentemente**: um codec pode evoluir seu bitstream sob um novo `codec_version` sem tocar no contêiner nem em outros codecs. **Um `codec_id` desconhecido falha alto** — nunca é adivinhado, nunca tem alias silencioso (espelha `dev_open(kbd, 1)` retornando `E_NOENT` em vez de aliasar o teclado 0).

**Declaração de capacidade.** O arquivo declara, no cabeçalho/`ICAP`, o conjunto de `codec_id` e o `deriv_id` que usa, e o **profile + level** que requer (§0.6). Um leitor verifica *antes* de decodificar se implementa aquele profile naquele level; se não, recusa de forma limpa (`E_CSIF_PROFILE`/`E_CSIF_LEVEL`) em vez de tentar um decode parcial perigoso. A declaração é **advisory-plus-validated**: o leitor ainda valida cada chunk que de fato encontra (não confia cegamente na declaração).

**Espaço de extensão governado.** Há um bit `PUBLIC` explícito (privado/vendor vs. público registrado) e faixas reservadas de `chunk_type` e `codec_id` para uso experimental/vendor — extensão é por flag declarado + faixa reservada, nunca por sobrecarregar um tipo público. O registro público de chunks e o registro de codecs são **fechados e completos** para a v1 (espelhando os conjuntos de operações fechados do kernel).

---

### 0.6 Visão geral dos perfis de conformidade

A conformança do CSIF é definida em **números**, não em "parece igual" (Regra 4). Há **perfis** (quais codecs/features um decodificador deve implementar), **levels** (tetos numéricos de pior-caso), e dois contratos de conformidade distintos e explicitamente separados (decodificador vs. encoder). Esta subseção dá a *visão geral*; a seção dedicada de conformança fixa os valores byte-exatos, os códigos de erro e o corpus.

**Perfis (subconjuntos do registro de codecs/features) — visão geral.** Cada perfil é uma enumeração fechada (mecanismo/política intacto: o contêiner ainda despacha por `codec_id`; o perfil apenas declara *quais* `codec_id` estão em-escopo). Todos os perfis são definidos **agora**, mesmo que codecs avançados embarquem como slots honestos depois (Regra 4):

- **BASELINE** — `{RAW, QOI, MODULAR, DCT}`; inteiros 8/16-bit; sem canais auxiliares; sem animação. O piso interoperável que um decodificador mínimo (ex.: o visualizador de imagem do WM) deve implementar.
- **STANDARD** — BASELINE + cor completa (CICP/ICC, HDR volume), tiling indexado/derivado, INDEXED, BILEVEL, animação, canais auxiliares (alpha/depth/gainmap).
- **FULL** — STANDARD + BLOCK (VarDCT), wavelet (DWT escalável), float/HDR (f16/f32, EXR-class), VECTOR, transcode JPEG, e os codecs GPU-block + transcodável.
- **NEURAL** — FULL + o codec NEURAL (learned). Slot honesto: real, ou ausente; jamais um stub que finge.

O arquivo declara seu `profile:u8` e `level:u8` requeridos. Os tetos `ILIM` do arquivo DEVEM ser ≤ os tetos normativos do level declarado.

**Levels (L1…Ln) — visão geral.** Cada level limita `max_pixels`, `max_tile_pixels`, `max_chunks`, `max_aux_channels`, `max_alloc_bytes`, `max_reference_frames`, profundidade/fan-in de derivação etc. (modelo H.264/HEVC/AV1). Um decodificador anuncia exatamente o que suporta e **recusa streams fora-de-level antes de alocar** (Regra 5).

**Contrato (1) — conformança do *decodificador* = bit-exatidão.**
Porque o CSIF manda um inverso fixed-point exato para *todo* codec com perdas (a aritmética do IDCT/dequant/IDWT é congelada na spec — sem "qualquer IDCT razoável"), o decode é **determinístico**. Codecs sem perdas (RAW/QOI/MODULAR/BILEVEL/INDEXED/RAW_LOSSLESS) reconstroem bit-a-bit (erro absoluto máximo = 0, inclusive padrões de bits float NaN/Inf/zero-sinalizado para os caminhos float sem perdas). Codecs com perdas reproduzem o pixel-dump de referência exatamente. Um decodificador oco não passa: ele *tem* que acertar os pixels exatos.

**Contrato (2) — conformança do *encoder* (opcional) = banda de métrica.**
A qualidade alcançada gravada em `IQMT` deve cair dentro de `[target − eps, target + eps]` medida contra a fonte, com `eps` declarado por métrica. A *política* de como o encoder buscou os bits não é fixada; só o *resultado* declarado é verificado.

**Corpus golden + harness.** A especificação embarca um corpus de conformança no repositório, **congelado no self-host** (como a ABI): (a) vetores de round-trip bit-exato para codecs sem perdas; (b) pixel-dumps de referência para codecs com perdas; (c) um **corpus de corrupção** (arquivos truncados, CRC ruim, dimensões com overflow, chunk crítico desconhecido, arquivo fora-de-level, EXIF malformado, dicionário externo ausente, derivação cíclica) cada um com o **código de erro exato esperado**, provando que decodificadores falham de forma segura e previsível. O harness segue o mesmo padrão `verify.sh` que o OS já usa.

---

### 0.7 Códigos de erro & postura "falha alto"

Toda condição de erro é um **código numerado** reportado com o campo/offset ofensor (estilo dos retornos enumerados do `cse.cst` `0-13…0-16`), nunca um clamp silencioso, garbage silencioso, fallback silencioso ou hang. Esta é a postura "falha alto, limitada, prod-ready" do projeto aplicada ao formato. A lista canônica de códigos vive na seção de conformança; o *contrato* é fixado aqui:

- **Negativo = erro** (convenção de família, como os errnos negativos do causticos).
- Cada código nomeia **o que** falhou e **onde** (chunk type + offset, ou `(level, tile)`, ou o campo CICP ofensor, ou `offset=X > window=Y`).
- "Sem proveniência" / "proveniência presente mas não confiável" / "adulterado" / "válido" são estados **distintos e declarados** — nunca um booleano mágico de pass/fail (modelo de resultado de verificação, na seção de proveniência).
- "Decodificado K de N passes" é um *status honesto* para arquivos truncados — não uma imagem silenciosamente degradada fingindo estar completa.

---

### 0.8 Unidades & convenções (válidas em TODA a especificação)

As convenções a seguir são **normativas e globais**. Onde uma seção posterior declarar um campo, ele segue estas regras salvo se a própria seção declarar explicitamente uma exceção (e exceções são, elas mesmas, declaradas — Regra 1).

#### 0.8.1 Endianness

- **Todos** os campos do contêiner e dos bitstreams de codec são **little-endian**, fixados para casar com o CSE e o x86_64.
- O valor de endianness é **escrito no cabeçalho** (um campo, com o valor "little-endian"), não pressuposto. **Não há flag de byte-order por arquivo** que troque o parser (a armadilha do TIFF é proibida — §0.2, Regra 1).
- A endianness das amostras multi-byte de pixel (10/12/16-bit; f16/f32) é declarada explicitamente no cabeçalho de imagem junto com a ordem de bit-packing — zero ambiguidade ao ler amostras cruas.

#### 0.8.2 Tipos inteiros & nomenclatura

A especificação usa estes nomes de tipo de campo em todo lugar:

| Nome | Significado |
|---|---|
| `u8` | inteiro sem sinal 8-bit |
| `u16` | inteiro sem sinal 16-bit, little-endian |
| `u32` | inteiro sem sinal 32-bit, little-endian |
| `u64` | inteiro sem sinal 64-bit, little-endian |
| `i8/i16/i32/i64` | inteiros com sinal, complemento-de-dois, little-endian |
| `f16/f32` | IEEE 754 binary16 / binary32, little-endian |
| `rational` | um par `{num:i64, den:i64}` (matemática exata; ver §0.8.4) |
| `fixed Q m.n` | inteiro de ponto-fixo com `m` bits inteiros e `n` fracionários; `m`,`n` declarados no campo que o usa |

**Larguras de offset/comprimento.** Todo offset e todo comprimento no contêiner é **u64 desde o início** (sem dualidade 32/64, sem escape `largesize`). Isto difere deliberadamente do CSE (que usa u32 para segmentos): imagens podem ser gigapixel; offsets de 64 bits são a norma e o limite real é o teto `ILIM` declarado, não a largura do campo.

**Aritmética de validação alargada.** Qualquer produto de tamanho (ex.: `width*height*channels*bytes_per_sample`) DEVE ser computado em aritmética intermediária mais larga que o resultado declarado (u64, ou u128 quando necessário) e checado contra o teto `ILIM` declarado **antes** de qualquer alocação (Regra 5).

> **Gotcha de implementação (Caustic).** Structs do compilador Caustic com largura de campo mista (`u8`/`u16`/`u32`/`u64` adjacentes) podem aliasar campos vizinhos; portanto **structs *em memória* na implementação do leitor/escritor DEVEM usar `i64` para todos os campos escalares**. Isto é uma regra da *implementação Caustic*, **não** do *layout serializado em disco* — o layout em disco usa as larguras exatas declaradas acima e é byte-exato. (Ver as notas de gotchas da linguagem.)

#### 0.8.3 Alinhamento

- O alinhamento de payload de chunk é **fixo e declarado** no cabeçalho/diretório (não há padding surpresa).
- Regiões de level/tile que se destinam a upload direto para GPU ou a `mmap` declaram um alinhamento amigável a página/DMA explícito (ver a seção GPU), conectando à disciplina de scanout write-combining (PAT por-CPU) que o kernel já usa. O fato de uma região ser diretamente "uploadável" é um bit de capacidade declarado, nunca probado.
- O leitor calcula `(offset, size)` de qualquer unidade a partir do índice declarado e nunca infere padding.

#### 0.8.4 Matemática exata: `rational` e fixed-point

Onde a correção exige valores exatos não-inteiros — matrizes de calibração de cor de câmera, balanços, exposição, timing de animação, pontos de controle de spline, multiplicadores de gradiente, parâmetros de gain-map HDR — a especificação usa **`rational` (`num:i64, den:i64`)** ou **fixed-point Q m.n declarado**, **nunca** float "por mágica". Razões:

- Reprodutibilidade bit-exata entre máquinas (Regra 4) sem deriva de FP.
- Evita a ambiguidade de unidade (ex.: timing de animação é `rational` de ticks/segundo, **não** centésimos-de-segundo implícitos do GIF).
- Casa com o gotcha Caustic de struct (rationals são pares `i64`, §0.8.2).

Toda a aritmética nos *loops de coding* (entropia, transformadas, quantização) é **inteira/fixed-point** — **zero ponto-flutuante no loop de coding** — para que o bitstream seja bit-exato em qualquer CPU. Float só aparece como *tipo de amostra* (f16/f32, dados de pixel HDR) e na *busca* do encoder.

#### 0.8.5 Sistema de coordenadas, ordem de varredura e geometria

- A origem do canvas, a direção de varredura (top-down/bottom-up/tiled-random) e a ordem de packing de amostras são **campos declarados** (enums), nunca implícitos.
- Janela de dados vs. janela de exibição (data window / display window), pixel aspect ratio e orientação nativa são campos explícitos; pixels fora da data window são **explicitamente indefinidos** (declarado), não "zero por sorte".
- Toda dimensão de saída de uma imagem derivada/level/tile é declarada e **validada** contra a geometria computada de seus inputs; incompatibilidade = rejeição (não "best effort").

#### 0.8.6 Cor & amostras (resumo das regras globais; detalhes na seção de cor)

- Cor é **100% declarada**: CICP (`primaries`, `transfer`, `matrix`, `full_range`) obrigatório, `Unspecified` proibido, ICC opcional com **precedência declarada**; sem default sRGB implícito.
- Formato de amostra é um enum declarado `{U8, U16, U32, F16, F32}` (e por-canal quando aplicável); profundidade, signedness, packing e endianness sempre declarados.
- Semântica de alpha (presente/ausente, straight vs. premultiplied vs. premultiplied-linear, profundidade própria, linear vs. coded) é **declarada**, nunca farejada — fechando a armadilha #1 de corrupção silenciosa (fringing).
- Caminhos float sem perdas preservam exatamente o padrão de bits (NaN/Inf/zero-sinalizado); caminhos com perdas declaram seu tratamento de valores não-finitos.

---

### 0.9 Sequenciamento honesto da implementação (sem impls falsas)

Em fidelidade à Regra 4, a especificação é **fechada por inteiro agora**, mas a implementação é sequenciada honestamente:

- **Primeiro:** contêiner + toolkit compartilhado + codecs `0=RAW`, `1=QOI`, `2=MODULAR`, `3=DCT` (perfil BASELINE), com cor completa, integridade (CRC + hash), tiling/índice, e o corpus de conformança.
- **Depois, como slots de interface reais:** `4=BLOCK` (VarDCT), o codec wavelet (DWT escalável), `6` e seguintes (transcode JPEG, RAW de captura, GPU-block, transcodável, BILEVEL, INDEXED, VECTOR), e por fim `5=NEURAL`.

Cada slot ainda-não-implementado é um *slot de interface honesto* (a interface `{decode, encode}` existe e está especificada; o `codec_id` é declarado e validado; um arquivo que o use e um decodificador que não o implemente produz um erro de capacidade **alto e preciso** — §0.5, §0.6). **Nunca** existe um decodificador falso que aceita o `codec_id` e retorna pixels inventados. O design **não** é adiado; só a *construção* de slots avançados é, e mesmo assim provada por vetores golden antes de ser declarada pronta.

---

### 0.10 Forma do contêiner (referência normativa de família; detalhes na seção de contêiner)

Esta subseção fixa apenas os invariantes de família que o resto da especificação assume. O layout byte-exato completo (todos os campos, todos os tipos de chunk) está na seção dedicada de contêiner.

```
[ cabeçalho CSIF (offsets fixos) ]
[ diretório de chunks: registros de stride fixo ]
[ payloads de chunk ]
```

**Cabeçalho (offsets fixos, little-endian)** — espelha o header de 32B do CSE (`"CST_" + version + arch + flags`), forma de família (Regra 7):

- `magic` = `"CSIF"` (4 bytes). Inclui uma sonda de transmissão documentada (padrão CRLF/EOF, como a assinatura de 8 bytes do PNG) para que dano em trânsito seja detectado já no byte 0 — **explicitamente parte do magic**, não folclore.
- `version:u16` = `1`.
- byte de `flags` + byte de `endianness` (valor declarado "little-endian", §0.8.1).
- `checksum_algo:u8` (0=CRC32-IEEE, 1=CRC32C/Castagnoli, 2=none-para-RAW-passthrough) + algoritmo de hash forte declarado.
- `profile:u8`, `level:u8` (capacidade requerida, §0.5/§0.6).
- `chunk_count:u32`, `chunk_directory_offset:u64`, e o offset explícito do índice principal (`ITOC`).

**Diretório de chunks** — registros de stride fixo `{ chunk_type:u32 (id opaco), chunk_offset:u64, chunk_length:u64, flags:u32 (CRITICAL/PUBLIC/SAFE_TO_COPY/…) }`, seguidos pelos payloads. Estrutura **plana e validável** (não uma árvore recursiva de boxes — mais simples de verificar, sem aninhamento ilimitado). Todo comprimento é u64 (sem dualidade 32/64).

**Integridade** — cada chunk termina com `crc32` sobre `type + flags + payload` (cobertura estendida vs. PNG, pois os flags são load-bearing). O chunk terminal `IEND` é obrigatório e carrega um checksum forte do arquivo inteiro; sua ausência ⇒ arquivo truncado ⇒ erro alto. Modo de checksum é declarado no cabeçalho (nunca presumido).

**Invariantes do loader (Regra 5), checados antes de qualquer codec rodar:** (1) todo byte-range de item ⊆ seu chunk IDAT-class declarado; (2) ids únicos e densamente validáveis; (3) grafo `DERIVED_FROM` acíclico, com profundidade e fan-in máximos declarados; (4) geometria de saída de cada item derivado = geometria computada de seus inputs; (5) item primário presente, decodificável, com fecho de dependência presente; (6) dimensões/total-de-pixels máximas que o leitor irá alocar estão declaradas, para pré-rejeição/pré-dimensionamento sem alocação escondida. Qualquer violação é um erro numerado (§0.7).

---

### 0.11 Resumo (o contrato em uma frase)

> O CSIF é o formato de imagem nativo do causticos: um **contêiner-mecanismo** codec-agnóstico (chunks TLV, diretório plano, índices de byte-range explícitos, validação "falha-alto") sobre um **toolkit compartilhado** (DRY) consumido por um **registro fechado de codecs-política**, em que **cada campo é declarado, nada é mágico, a memória é limitada, e onde um formato de referência adivinharia, o CSIF declara** — competitivo com JPEG XL/AVIF/HEIF/OpenEXR/KTX2/DNG/C2PA, e 100% Caustic, da mesma família que o CSE.

---

I now have the exact CSE family conventions: 32-bit/v3 48-bit headers, `"CST_"`-style 4-byte magic, fixed little-endian, explicit offset+size tables with `foff+fsz > size` rejection, numbered negative error codes (`0-13`..`0-16`), `MAX_SEGS=16` bounded counts. I have everything needed to write a byte-exact container spec that is a true sibling of CSE.

This is the complete specification text for my section.

---

## 1. Container & chunks (byte-exact)

> **Scope of this section.** This section defines the CSIF **container**: the byte-exact file layout, the signature/header, the chunk (TLV) framing, the integrity/criticality model, the full mandatory + optional chunk catalog with every field's name, size, type, valid range, and ordering rule, and the tiling / index structures the rest of the spec builds on. The container is **pure mechanism**: it carries structure and dispatches opaque payloads by `codec_id` / `deriv_id` / `entropy_method_id`; it never interprets a codec's bytes, never bakes in a codec, never applies a colour transform, never runs a filter. Every codec-internal bitstream, every entropy stream, and every colour-management decision is defined in later sections and is *opaque* to everything described here. This is the Caustic mechanism/policy seam, identical in spirit to the kernel's KObject vtable: the container exposes a uniform `{decode, encode}` (and `{assemble}` for derivations, `{compute}` for metrics) seam and dispatches by a declared integer id.

### 1.0 Conventions, invariants, and types

These hold for **every** byte described in this section and bind every chunk payload defined here. They are stated once and never restated per field.

**C-1 — Endianness (declared, fixed, never a per-file flag).**
All multi-byte integer and fixed-point fields in the container header, the chunk directory, every chunk header, and every container-defined chunk payload are **little-endian**, matching CSE (`"CST_"`, x86_64) and the project's CSE-family rule. There is **no per-file byte-order flag** (TIFF's `II`/`MM` is explicitly rejected as a parser-differential hazard). The chosen endianness is nonetheless **declared** as a literal field in the header (`container_endian`, §1.2) so the file is self-describing even though the value is fixed for v1. Multi-byte *pixel sample* endianness is a separate, also-declared field in `IHDR` (§1.6) — the container endianness does not implicitly govern sample bytes.

**C-2 — Integer & fixed-point types.** The following type names are used throughout:

| Name | Width | Meaning |
|---|---|---|
| `u8` / `u16` / `u32` / `u64` | 1 / 2 / 4 / 8 B | unsigned little-endian |
| `i8` / `i16` / `i32` / `i64` | 1 / 2 / 4 / 8 B | two's-complement little-endian |
| `f16` / `f32` / `f64` | 2 / 4 / 8 B | IEEE-754 binary16 / binary32 / binary64, little-endian byte order |
| `q16_16` | 4 B | signed 16.16 fixed point (`i32`, value = raw / 65536) |
| `q2_30` | 4 B | signed 2.30 fixed point (`i32`, value = raw / 2³⁰); used for chromaticities/matrices |
| `rational32` | 8 B | `{ num: i32, den: u32 }`; `den == 0` is **invalid** (loud error) |
| `rational64` | 16 B | `{ num: i64, den: u64 }`; `den == 0` is **invalid** |
| `urn4` | 4 B | an opaque 4-byte chunk/record tag; treated as a 32-bit identifier — **letter case carries NO meaning** (the explicit replacement for PNG's case-bit magic, §1.4) |
| `len_str` | var | `{ len: u16, bytes: u8[len] }`, UTF-8, **not** NUL-terminated; `len` counts bytes |
| `pstr32` | var | `{ len: u32, bytes: u8[len] }` for large opaque blobs |

> **Caustic note on `rational32/64`.** Capture math, colour chromaticities, and timing use exact rationals (`num/den`) rather than floats wherever an exact value is meaningful, both for reproducibility and to sidestep the language's mixed-width-struct miscompile (all rational fields are `i32/u32` or `i64/u64` pairs, never mixed with narrower fields inside the same struct — see C-9).

**C-3 — Alignment.** The file header is at offset 0. The **chunk directory** (§1.3) and **every chunk payload** begin at an offset that is a multiple of **8 bytes** from file start. Where a payload's natural size is not a multiple of 8, the writer inserts `pad_len ∈ [0,7]` zero bytes **after** the payload's CRC and **before** the next directory-addressed structure; padding is never inside the CRC coverage and is never inside a declared length. (The directory's explicit offsets make alignment self-describing; a reader never infers padding.)

**C-4 — Offset/length validation (overflow-proof, the CSE discipline generalised).** Every `(offset, length)` pair that addresses bytes — the chunk directory entries, every item's byte range in `ITBL` (§1.16), every tile/level/stream entry in `TIDX`/`IMIP`/`EOFF`/`QLYR` — is validated **before any allocation or read**:

1. `offset ≥ end_of_header`,
2. `length ≥ 0` (unsigned, so trivially),
3. the sum `offset + length` is computed in **u128 widened arithmetic** and must satisfy `offset + length ≤ file_size`,
4. for ranges that must lie inside a parent region (e.g. an item's bytes inside its `IDAT`), the same widened check is applied against the parent's `[offset, offset+length)`.

Any failure is a **hard, numbered error** (§1.5) reported with the offending field name, chunk type, and offset — never a clamp, never a best-effort. This is exactly `cse.cst`'s `foff + fsz > cst_size → return 0-14` rule, generalised to every addressed range.

**C-5 — Bounded structure (declared ceilings before allocation).** The `ILIM` chunk (§1.9) is **mandatory** and declares, in the file, every ceiling a reader needs to size its worst case before touching `IDAT`: `max_width`, `max_height`, `max_pixels`, `max_tile_pixels`, `max_alloc_bytes`, `max_components`, `max_aux_channels`, `max_chunk_size`, `max_items`, `max_tiles`, `max_mip_levels`, `max_frames`, `max_reference_slots`, `max_derivation_depth`, `max_derivation_fanin`, `max_entropy_streams`, `max_ma_tree_nodes`, `max_palette_entries`, `max_patches`, `max_splines`, `max_spline_points`, `max_metadata_bytes`, `max_manifests`. The reader rejects any chunk/structure whose declared sizes exceed the corresponding ceiling, and rejects an `ILIM` whose ceilings exceed the file's declared **profile/level** caps (§1.2). Pixel buffer size is computed as `width × height × component_count × ceil(bit_depth/8)` (and × sample-count for deep, §1.6) in u128 and checked against `max_alloc_bytes`. No structure in CSIF is unbounded; counts are `u32`/`u16` with declared maxima.

**C-6 — Canonical encoding.** For any given image there is **exactly one** valid byte serialisation under a fixed writer policy (fixed field order, fixed integer widths, no optional whitespace, padding fully determined by C-3, directory entries sorted by ascending `chunk_offset`). Two valid byte sequences never parse to different logical structures (kills parser-differential attacks; required by the conformance corpus, §1.20).

**C-7 — Forward compatibility (skippable bit, the CSE-family convention).** Every chunk carries an explicit `flags` field (§1.4) with a `CRITICAL` bit. A reader encountering a chunk **type id it does not recognise**:
- if the chunk's `CRITICAL` bit is set → **hard error** `E_CSIF_UNKNOWN_CRITICAL`;
- otherwise → **skip** it by advancing past its declared `chunk_length` (validated by C-4) and record it as "present, type X, skipped". Skipping is the only forward-compat mechanism for *ancillary* data; **load-bearing pixel data is always `CRITICAL`** and can never be silently ignored.

**C-8 — Loud failure, never silent.** Underspecification, ambiguity, an out-of-range enum, a `den == 0`, a CRC mismatch on a critical chunk, a colour value of "Unspecified" (§ colour, forbidden), or any C-4 violation, is a hard error with a numbered code and the offending field. There is no implicit default, no heuristic fallback, no "best effort partial render that looks broken."

**C-9 — Struct field-width rule (language gotcha).** Every struct layout in this section that is materialised as a Caustic struct uses **`i64`/`u64`/`u32`/`i32` scalar fields only within one struct**, never mixing a `u8`/`u16` beside a wider field in a way that can alias (the documented Caustic mixed-width-struct miscompile). On-disk byte layouts pack tightly per the field tables below; the *reader* assembles values via explicit byte reads (like `elf.read_u16_le`), so on-disk packing and in-memory struct width are decoupled.

---

### 1.1 File layout (top level)

```
+-----------------------------------------------------------+
| File header                          (64 bytes @ 0)       |   §1.2
+-----------------------------------------------------------+
| Chunk directory     (chunk_count × 32-byte records)       |   §1.3
+-----------------------------------------------------------+
| Chunk payloads      (each: [chunk header][payload][crc])  |   §1.4, §1.6..§1.19
|   addressed only through the directory's offsets           |
+-----------------------------------------------------------+
| (optional 0..7 trailing pad bytes to 8-byte file size)    |
+-----------------------------------------------------------+
```

The file is a **flat** structure (no recursive box nesting): a fixed header, a fixed-width directory, then directory-addressed payloads. This is deliberately *simpler to validate* than ISOBMFF's recursive tree and mirrors CSE's `[header][segment table][segment bytes]`. Multi-image and composition are expressed by the **item table** (`ITBL`, §1.16) over flat payloads, not by nesting.

There are two **layout profiles**, declared by `layout` in the header (§1.2):

- **`LAYOUT_RANDOM` (0)** — the chunk directory and **all** structural/metadata chunks (everything except `IDAT`-class payload chunks) precede the first `IDAT` byte. The directory is at a known offset right after the header. A reader mmaps the file, reads header + directory, validates all ranges, then seeks into `IDAT`. Optimised for local disk / mmap.
- **`LAYOUT_STREAMING` (1)** — payload chunks appear in progression order (§ progressive); the directory may be written **at the end** of the file, and the header's `directory_offset` points to it, while `directory_offset_tail` (a copy in the mandatory `IEND`, §1.19) lets a reader that has the file's tail find the directory by seeking backwards. Each chunk still carries its full self-delimiting header so a forward-only streaming reader can parse as bytes arrive.

The layout choice is **declared**, never sniffed (C-8).

---

### 1.2 File header (64 bytes @ 0, little-endian)

The header is a fixed 64-byte block. It mirrors CSE's `"CST_" + version + arch + flags` discipline and extends it with a transmission probe (PNG-signature lesson) and the self-describing directory pointer.

| Off | Size | Type | Field | Value / range |
|---|---|---|---|---|
| 0x00 | 4 | `u8[4]` | `magic` | `"CSIF"` = `43 53 49 46` |
| 0x04 | 6 | `u8[6]` | `transmission_probe` | fixed `0x89 0x0D 0x0A 0x1A 0x0A 0x00` — high-bit-set byte (detects 7-bit stripping), CR LF (detects newline mangling), `0x1A` (DOS EOF), LF, NUL. A reader **must** verify this exactly; mismatch ⇒ `E_CSIF_TRANSMISSION` at byte 0. |
| 0x0A | 2 | `u16` | `version` | container version. `1` for this spec. |
| 0x0C | 1 | `u8` | `container_endian` | `0` = little-endian (the only legal value in v1; **declared, not assumed**). |
| 0x0D | 1 | `u8` | `arch_hint` | informative target hint (`0` = none, `1` = x86_64); never changes parsing. |
| 0x0E | 1 | `u8` | `layout` | `0` = `LAYOUT_RANDOM`, `1` = `LAYOUT_STREAMING` (§1.1). Other = error. |
| 0x0F | 1 | `u8` | `checksum_algo` | per-chunk integrity algorithm (§1.4): `0` = none, `1` = CRC32-IEEE (poly `0xEDB88320`, init/final `0xFFFFFFFF`), `2` = CRC32C (Castagnoli). Declared once for the whole file. |
| 0x10 | 1 | `u8` | `profile` | conformance profile (closed enum, §1.21): `0` = BASELINE, `1` = FULL, `2` = GPU, `3` = PRO, `4` = CAPTURE. |
| 0x11 | 1 | `u8` | `level` | conformance level `1..N` capping decoder worst-case work (§1.21). |
| 0x12 | 2 | `u16` | `header_flags` | bit0 = `HAS_STRONG_HASH` (an `IHSH` chunk is present, §1.19); bit1 = `HAS_PROVENANCE` (a `PROV` chunk is present); bit2 = `HAS_ANIMATION` (`IANI` present); bit3 = `IS_MULTI_ITEM` (`ITBL` present with >1 item); bits 4..15 reserved, **must be 0**. |
| 0x14 | 4 | `u32` | `chunk_count` | number of entries in the chunk directory; `1 ≤ chunk_count ≤` (level cap). |
| 0x18 | 8 | `u64` | `directory_offset` | file offset of the chunk directory (§1.3). For `LAYOUT_RANDOM` typically `0x40`. Validated by C-4. |
| 0x20 | 8 | `u64` | `file_size` | total file length in bytes; must equal the actual file length (else `E_CSIF_TRUNCATED`). |
| 0x28 | 8 | `u64` | `primary_item_id` | the item id (in `ITBL`, §1.16) of the image a default reader renders. For a single-image file with no `ITBL`, this is `0` and the sole `IHDR`+`ICOD`+`IDAT` set is primary. **Explicit, never "the first item by convention."** |
| 0x30 | 8 | `u64` | `directory_offset_tail` | for `LAYOUT_STREAMING`, a back-pointer copy of the directory offset reachable from the file tail; `0` for `LAYOUT_RANDOM`. |
| 0x38 | 8 | `u64` | `header_crc` | checksum (per `checksum_algo`) over header bytes `0x00..0x37`. `checksum_algo == 0` ⇒ this field is `0` and not checked. |

Reader rule (mirrors `cse.cst::locate_cst` + header validation): verify `magic`, `transmission_probe`, `version == 1`, `container_endian == 0`, `layout ∈ {0,1}`, `checksum_algo ∈ {0,1,2}`, `profile`/`level` known, `header_flags` reserved bits zero, `file_size == actual`, then verify `header_crc`. Each failure is its own numbered error (§1.5).

---

### 1.3 Chunk directory (chunk_count × 32-byte records @ directory_offset)

A flat, fixed-width table — the CSIF analogue of CSE's segment table. It makes the whole file validatable in **one bounded pass** before any decode, and makes every chunk randomly addressable (no scan-for-marker, ever).

Each directory record (32 bytes):

| Off | Size | Type | Field | Meaning |
|---|---|---|---|---|
| +0x00 | 4 | `urn4` | `chunk_type` | the chunk's 4-byte type id (e.g. `"IHDR"`). Opaque 32-bit id; case carries no meaning (C-2, §1.4). |
| +0x04 | 4 | `u32` | `chunk_flags` | a **copy** of the chunk's `flags` (§1.4) so disposition (critical/skippable/public/safe-to-copy) is known from the directory alone, before seeking to the chunk. Must match the chunk's own `flags` exactly (else `E_CSIF_FLAG_MISMATCH`). |
| +0x08 | 8 | `u64` | `chunk_offset` | file offset of this chunk's **chunk header** (§1.4). 8-byte aligned (C-3). Validated by C-4. |
| +0x10 | 8 | `u64` | `chunk_length` | total bytes of `[chunk header (16) + payload + crc (0 or 4)]`. Validated by C-4 and against `ILIM.max_chunk_size`. |
| +0x18 | 4 | `u32` | `chunk_seq` | the chunk's ordinal in the **declared logical order** (§1.5 ordering grammar); used to enforce ordering even when physical offsets are reordered for streaming. Strictly increasing across the directory for `LAYOUT_RANDOM`; for streaming, monotonic per the progression order. |
| +0x1C | 4 | `u32` | `reserved` | must be `0`. |

The directory **must** be sorted by ascending `chunk_offset` for `LAYOUT_RANDOM` (canonical encoding, C-6). Directory entries collectively partition the payload region with no overlaps and no gaps other than C-3 padding; the reader validates non-overlap in the same bounded pass (overlapping ranges ⇒ `E_CSIF_OVERLAP`).

---

### 1.4 Chunk framing, integrity, and disposition flags (the TLV unit)

Every chunk is a self-delimiting TLV with explicit length-before-payload (PNG/RIFF/ISOBMFF lesson) and an explicit per-chunk CRC (PNG lesson), extended the Caustic way: the PNG case-bit "magic" is replaced by a real declared `flags` field.

**Chunk header (16 bytes), at `chunk_offset`:**

| Off | Size | Type | Field | Meaning |
|---|---|---|---|---|
| +0x00 | 4 | `urn4` | `type` | 4-byte type id; must equal the directory's `chunk_type`. |
| +0x04 | 4 | `u32` | `flags` | disposition bits (below). Must equal the directory's `chunk_flags`. |
| +0x08 | 8 | `u64` | `payload_length` | byte count of the payload that follows (excludes this 16-byte header and the trailing CRC). `chunk_length` (directory) = `16 + payload_length + (checksum_algo==0 ? 0 : 4)`. |

**Payload:** `payload_length` bytes (structure defined per chunk type, §1.6+).

**Trailing CRC (4 bytes, present iff `checksum_algo != 0`):** `u32` checksum over `type (4) ‖ flags (4) ‖ payload_length (8) ‖ payload` — i.e. the whole chunk header **and** payload (CSIF extends PNG's "type+data" coverage to include `flags` and `payload_length`, since both are load-bearing). Algorithm is the file-global `checksum_algo`. A reader recomputes and compares; behaviour on mismatch is governed by criticality (below).

**`flags` bit definitions (explicit, replacing PNG case bits):**

| Bit | Name | Meaning |
|---|---|---|
| 0 | `CRITICAL` | Set: a reader that does not understand `type`, or that finds a CRC mismatch, **must fail loudly** (`E_CSIF_UNKNOWN_CRITICAL` / `E_CSIF_CRC_CRITICAL`). Clear: ancillary — unknown type is skipped (C-7); CRC mismatch on an ancillary chunk is skip-with-warning. |
| 1 | `PUBLIC` | Set: `type` is in the closed public registry (§1.5). Clear: a private/vendor chunk in the reserved id range. (Explicit; not letter case.) |
| 2 | `SAFE_TO_COPY` | Set: an editor may preserve this chunk verbatim after editing pixels; the chunk does not depend on pixel content. Clear: editing pixels invalidates it (e.g. a per-tile checksum, a hard provenance binding) — an editor must drop or regenerate it. |
| 3 | `SINGLETON` | Set: at most one chunk of this `type` may appear in the file (or per item, for per-item chunks). |
| 4 | `PER_ITEM` | Set: this chunk is associated with a specific item (its `item_id` is the first `u64` of the payload); clear: file-global. |
| 5 | `IS_PAYLOAD` | Set: an `IDAT`-class codec/data payload chunk (counts toward bounded-memory accounting; may appear after the first `IDAT` in streaming layout). |
| 6 | `HAS_DEPENDENCY` | Set: the chunk's payload begins with a dependency descriptor referencing other chunks/items (used by composition/derivation/animation). |
| 7..31 | reserved | must be `0`. |

Disposition is thus **declared data**, validatable from the directory alone, and the unknown-chunk policy (abort vs skip vs copy-through) is an explicit rule rather than ASCII-case folklore. This is the single most important PNG redesign in CSIF.

---

### 1.5 Chunk type registry, ordering grammar, and error codes

**Closed public chunk registry (v1).** Every public chunk `type` is one of the following. Unknown public ids are an error; vendor/private chunks must clear `PUBLIC` and use a type whose first byte is in `0x80..0xFF` (the reserved private-id range), so they can never collide with a public type.

| `type` | Name | Crit | Cardinality | Section | Purpose |
|---|---|---|---|---|---|
| `IHDR` | Image header | ✔ | 1 / item | §1.6 | geometry, sample format, channel/colour-model axes |
| `ILIM` | Limits | ✔ | 1 (file) | §1.9 | declared resource ceilings |
| `CHNL` | Channel table | ✔* | 1 / item | §1.7 | per-channel sample type, role, name, subsample (required iff non-trivial channel set) |
| `ICOL` | Colour encoding | ✔ | 1 / item | (colour §) | CICP + sample-format colour spec; **container carries it, never interprets it** |
| `ICCP` | ICC profile | — | ≤1 / item | (colour §) | embedded ICC blob (opaque) |
| `IHDV` | HDR colour-volume | — | ≤1 / item | (colour §) | MDCV + MaxCLL/MaxFALL |
| `IGMP` | HDR gain-map recipe | — | ≤1 / item | (advanced §) | gain-map application parameters |
| `ICOD` | Codec descriptor | ✔ | 1 / coded item | §1.10 | `codec_id`, version, lossless flag, tiling, sub-images, opaque codec params |
| `IPAL` | Palette | ✔ (if used) | ≤1 / item or shared | §1.13 | explicit colour table for INDEXED |
| `IDAT` | Coded data | ✔ | ≥1 / coded item | §1.11 | opaque codec bitstream bytes (one or more, per-tile) |
| `TIDX` | Tile index | ✔ (if tiled) | 1 / coded item | §1.12 | per-tile offset/size/checksum |
| `IMIP` | Mip/level index | — | ≤1 / coded item | §1.14 | resolution-pyramid level table |
| `ITEX` | GPU texture descriptor | — | ≤1 / item | (gpu §) | tex kind, array/cube/3D, block layout |
| `EOFF` | Entropy stream offsets | ✔ (if entropy-streamed) | 1 / coded item | §1.15 | per-stream byte ranges (entropy §) |
| `IPRG` | Progression descriptor | — | ≤1 / coded item | (progressive §) | declared pass/level/quality order |
| `QLYR` | Quality layers index | — | ≤1 / coded item | (progressive §) | per-layer byte ranges + achieved metric |
| `IROI` | Region-of-interest | — | ≤1 / coded item | (jp2/metrics §) | declared regions + quality/shift |
| `ITBL` | Item table | ✔ (if multi-item) | 1 (file) | §1.16 | typed item directory (coded/derived/metadata) |
| `IREF` | Item reference graph | ✔ (if `ITBL`) | 1 (file) | §1.17 | typed directed relationships between items |
| `IDRV` | Derivation params | ✔ (per derived item) | 1 / derived item | §1.18 | grid/overlay/identity/transform recipe |
| `IAUX` | Auxiliary descriptor | ✔ (per aux item) | 1 / aux item | §1.16.3 | aux semantics (alpha/depth/gainmap/…) |
| `IANI` | Animation header | — | ≤1 (file) | §1.19 | timebase, loop, frame/ref-slot counts |
| `IFRM` | Frame control | — | 1 / frame | §1.19 | duration, blend, dispose, crop, refs |
| `IRAW` | Raw sensor descriptor | ✔ (if CFA) | 1 / item | (raw §) | CFA pattern, levels, calibration |
| `IDEV` | Develop program | — | ≤1 / item | (raw §) | ordered develop opcode list |
| `IQMT` | Quality/metric target | ✔ (if lossy) | 1 / coded item | (metrics §) | metric id + target + achieved |
| `IGRN` | Film-grain model | — | ≤1 / item | (metrics/avif §) | grain synthesis parameters |
| `IMET` | Metadata | — | ≥0 (file) | §1.8 | typed key→value table; EXIF/XMP/ICC blobs |
| `CDIC` | Compression dictionary | — | ≥0 (file) | (compressors §) | shared LZ/entropy dictionary |
| `THUM` | Thumbnail descriptor | — | ≥0 (file) | §1.19 | typed multi-entry thumbnail set |
| `PROV` | Provenance store | — | ≤1 (file) | (provenance §) | signed manifests |
| `IHSH` | Whole-file strong hash | — | ≤1 (file) | §1.19 | BLAKE3/SHA-256 over declared ranges |
| `IEND` | End marker | ✔ | 1 (file) | §1.19 | terminus + whole-file checksum + tail back-pointer |

\* `CHNL` is required (critical) whenever the channel set is anything other than the trivial single-`IHDR`-described case (e.g. any aux/named channel, any per-channel sample type, any subsampling); for a plain `RGB8` image with no extra channels, `IHDR` alone fully describes the channels and `CHNL` may be omitted, but if omitted the channel layout is exactly the one `IHDR.color_model` declares — there is no other implicit channel layout.

**Ordering grammar (declared and enforced; `validate_structure` step).** Logical order is given by `chunk_seq` (§1.3). The grammar:

1. `IEND` is the last chunk (highest `chunk_seq`). Absence ⇒ `E_CSIF_NO_IEND` (truncation).
2. `ILIM` precedes every other non-header chunk.
3. For each coded item: `IHDR` → (`CHNL`?) → `ICOL` → (`ICCP`/`IHDV`/`IGMP`/`IRAW`/`IDEV`?) → `ICOD` → (`IPAL`?) → (`IPRG`/`IQMT`?) → `IDAT`(s) → (`TIDX`/`IMIP`/`EOFF`/`QLYR`/`IROI`?). All colour/codec/metadata chunks for an item precede that item's first `IDAT`.
4. If `ITBL` is present, it precedes `IREF`, and both precede the per-item chunks they index.
5. `IANI` precedes all `IFRM`; `IFRM`s are in ascending frame order.
6. `IMET`/`THUM`/`CDIC`/`PROV` may appear anywhere after `ILIM` and before `IEND` (subject to their own `PER_ITEM`/ordering constraints), but in `LAYOUT_RANDOM` they precede the first `IDAT`.

Violations are reported by `validate_structure` with the offending chunk type + `chunk_seq` (e.g. `E_CSIF_ORDER`).

**Container error codes (numbered, mirroring `cse.cst`'s `0-13..0-16` style).** All negative `i32`:

| Code | Name | Condition |
|---|---|---|
| `0-1` | `E_CSIF_TOO_SMALL` | file smaller than the 64-byte header |
| `0-2` | `E_CSIF_MAGIC` | bad `magic` |
| `0-3` | `E_CSIF_TRANSMISSION` | bad `transmission_probe` |
| `0-4` | `E_CSIF_VERSION` | unsupported `version` |
| `0-5` | `E_CSIF_ENDIAN` | `container_endian != 0` |
| `0-6` | `E_CSIF_HEADER_CRC` | header CRC mismatch |
| `0-7` | `E_CSIF_TRUNCATED` | `file_size` ≠ actual, or range past EOF |
| `0-8` | `E_CSIF_DIR_RANGE` | directory offset/length out of bounds (C-4) |
| `0-9` | `E_CSIF_OVERLAP` | two chunk ranges overlap |
| `0-10` | `E_CSIF_FLAG_MISMATCH` | directory `chunk_flags` ≠ chunk `flags` |
| `0-11` | `E_CSIF_CRC_CRITICAL` | CRC mismatch on a `CRITICAL` chunk |
| `0-12` | `E_CSIF_UNKNOWN_CRITICAL` | unknown `type` with `CRITICAL` set |
| `0-13` | `E_CSIF_ORDER` | ordering-grammar violation |
| `0-14` | `E_CSIF_RANGE` | any item/tile/level/stream `(offset,length)` ⊄ parent (C-4) |
| `0-15` | `E_CSIF_DIMS` | dimension/pixel-product exceeds `ILIM`/level cap |
| `0-16` | `E_CSIF_LIMIT` | a declared count/size exceeds an `ILIM` ceiling |
| `0-17` | `E_CSIF_PROFILE` | required `profile` not implemented |
| `0-18` | `E_CSIF_LEVEL` | file `level` exceeds decoder capability |
| `0-19` | `E_CSIF_CYCLE` | derivation/reference graph has a cycle |
| `0-20` | `E_CSIF_GEOM` | derived item output geometry ≠ computed-from-inputs |
| `0-21` | `E_CSIF_NO_PRIMARY` | `primary_item_id` absent / not renderable |
| `0-22` | `E_CSIF_ENUM` | out-of-range enum or forbidden "Unspecified" colour value |
| `0-23` | `E_CSIF_DEN_ZERO` | a `rational` with `den == 0` |
| `0-24` | `E_CSIF_NO_IEND` | missing terminal `IEND` |
| `0-25` | `E_CSIF_UNKNOWN_CODEC` | `codec_id` not in registry / not implemented (loud, never guessed) |

---

### 1.6 IHDR — image header (per coded/raw item)

`IHDR` is the single mandatory front-matter for an item: a reader knows the entire pixel-model geometry before reading any data, with **no implicit defaults** (every axis is a declared enum/value). Payload:

| Off | Size | Type | Field | Range / meaning |
|---|---|---|---|---|
| +0x00 | 8 | `u64` | `item_id` | the owning item's id (matches `ITBL`; `0` for the implicit single item). Present because `IHDR` is effectively `PER_ITEM`. |
| +0x08 | 4 | `u32` | `width` | full-resolution width in pixels, `1..max_width`. |
| +0x0C | 4 | `u32` | `height` | full-resolution height in pixels, `1..max_height`. |
| +0x10 | 4 | `u32` | `depth` | volume depth (z) for 3D textures/deep, else `1`. |
| +0x14 | 1 | `u8` | `sample_format` | closed enum: `0`=UINT8, `1`=UINT10, `2`=UINT12, `3`=UINT16, `4`=UINT32, `5`=FLOAT16, `6`=FLOAT32. (Replaces v1's bare `bit_depth`; integer **and** float HDR are now expressible. Float is IEEE-754 per C-2.) |
| +0x15 | 1 | `u8` | `sample_endian` | endianness of multi-byte samples: `0`=little, `1`=big. **Declared, never inferred** (independent of container endianness, C-1). For UINT8 = `0` (irrelevant but stated). |
| +0x16 | 1 | `u8` | `bit_depth` | significant bits per sample (`8/10/12/16/32`), consistent with `sample_format` (e.g. UINT10 ⇒ 10). For float formats = the storage width (16/32). Validated against `sample_format`. |
| +0x17 | 1 | `u8` | `sample_layout` | `0`=FLAT (one sample/pixel/channel), `1`=DEEP (variable samples/pixel; per-tile sample-count tables, see §1.11 deep). **Explicit, never inferred from chunk presence.** |
| +0x18 | 1 | `u8` | `color_model` | closed enum: `0`=GRAY, `1`=GRAYA, `2`=RGB, `3`=RGBA, `4`=YCbCr, `5`=YCCK/CMYK, `6`=ICtCp, `7`=XYB, `8`=XYZ, `9`=INDEXED, `10`=CFA/SENSOR, `11`=MULTI (channel set fully given by `CHNL`). Must be consistent with `CHNL` and with `ICOL.matrix_coefficients` (e.g. RGB ⇒ matrix = Identity; YCbCr forbids matrix = Identity — colour §). |
| +0x19 | 1 | `u8` | `component_count` | number of pixel components actually stored, `1..max_components`. For `MULTI`/`INDEXED`/`CFA`, this is the count `CHNL`/`IPAL`/`IRAW` elaborate. |
| +0x1A | 1 | `u8` | `chroma_h_subsample` | horizontal chroma subsampling factor (1=4:4:4, 2=4:2:x). Explicit; never inferred from data size. |
| +0x1B | 1 | `u8` | `chroma_v_subsample` | vertical chroma subsampling factor. |
| +0x1C | 1 | `u8` | `chroma_sample_position` | co-sited/centred per H.273 (`0`=unspecified-FORBIDDEN, `1`=co-sited, `2`=centred…); `0` is rejected when chroma is subsampled. |
| +0x1D | 1 | `u8` | `alpha_mode` | closed enum: `0`=NONE, `1`=STRAIGHT (unassociated), `2`=PREMULTIPLIED (associated), `3`=PREMULTIPLIED_LINEAR. **The composite formula is selected by this declared value, never sniffed** (kills the #1 silent-corruption trap). For models without alpha = `0`. |
| +0x1E | 1 | `u8` | `orientation` | EXIF-style transform `0..7` (0=identity, 1=mirror-h, 2=rotate180, …, 7=…). **This is authoritative**; any EXIF Orientation in `IMET` is informational-only and MUST be ignored for rendering (declared precedence, kills double-rotation). |
| +0x1F | 1 | `u8` | `reserved0` | must be `0`. |
| +0x20 | 16 | `Rect` | `display_window` | the canvas rectangle `{x:i32, y:i32, w:u32, h:u32}` — the logical frame. |
| +0x30 | 16 | `Rect` | `data_window` | the rectangle for which pixels actually exist `{x,y,w,h}`; may be inside (crop) or outside (overscan) the display window. Pixels outside `data_window` are **explicitly UNDEFINED** (stated, not zero-by-luck). |
| +0x40 | 8 | `rational32`-pair | `pixel_aspect_ratio` | `{num:i32, den:u32}` of physical pixel width:height (`1:1` declared, never "1.0 assumed"). |
| +0x48 | 4 | `f32` | `intensity_target_nits` | reference white luminance in cd/m² for absolute/linear/PQ anchoring; `0` is the **declared** sentinel "use the transfer function's standard reference" (an explicit value, not an absent field). |

`Rect` is `{ x: i32, y: i32, w: u32, h: u32 }` (16 bytes). `data_window` and `display_window` together with `orientation` are the OpenEXR-class placement contract.

Reader validation of `IHDR`: `width/height/depth ≤ ILIM`; pixel-product (`width × height × component_count × ceil(bit_depth/8)` in u128, × max-samples-per-pixel cap for DEEP) ≤ `max_alloc_bytes`; `sample_format`/`bit_depth` consistent; `color_model`/`alpha_mode`/`chroma_*` in range; `data_window`/`display_window` rects sane (non-negative `w/h`, fit within `ILIM`). Any failure ⇒ `E_CSIF_DIMS`/`E_CSIF_ENUM`.

---

### 1.7 CHNL — channel table (arbitrary named/typed channels)

Promotes channels from a fixed enum to an explicit, self-describing, OpenEXR-class list. Required whenever the channel set is non-trivial (§1.5). Payload:

| Off | Size | Type | Field |
|---|---|---|---|
| +0x00 | 8 | `u64` | `item_id` |
| +0x08 | 4 | `u32` | `channel_count` (`1..max_components + max_aux_channels`) |
| +0x0C | 1 | `u8` | `pack_order` (`0`=channel-major within a tile, `1`=interleaved) — **declared, never inferred** |
| +0x0D | 3 | `u8[3]` | reserved (0) |
| +0x10 | `channel_count × 24` | `ChannelDesc[]` | the channel descriptors |

Each `ChannelDesc` (24 bytes):

| Off | Size | Type | Field | Meaning |
|---|---|---|---|---|
| +0x00 | 1 | `u8` | `sample_type` | per-channel `{UINT8…FLOAT32}` (same enum as `IHDR.sample_format`). A file can mix an f16 colour channel, an f32 depth, a u32 id. |
| +0x01 | 1 | `u8` | `role` | closed enum: `0`=COLOR_R, `1`=COLOR_G, `2`=COLOR_B, `3`=ALPHA, `4`=GRAY, `5`=CB, `6`=CR, `7`=DEPTH, `8`=DEPTH_BACK, `9`=DISPARITY, `10`=NORMAL_X, `11`=NORMAL_Y, `12`=NORMAL_Z, `13`=OBJECT_ID, `14`=MOTION_X, `15`=MOTION_Y, `16`=MASK, `17`=SPOT, `18`=CMYK_K, `19`=DATA, `20`=AUX. **Semantics from the role, not the name string** (Caustic fix to OpenEXR's stringly-typed convention). |
| +0x02 | 1 | `u8` | `is_color_managed` | `1` = the file's colour transform applies to this channel; `0` = leave linear/raw (depth/id/normal/data). **Explicit fact, not convention.** |
| +0x03 | 1 | `u8` | `is_premultiplied` | per-channel alpha-association (for ALPHA channels); for non-alpha = `0`. |
| +0x04 | 1 | `u8` | `x_subsample` | per-channel horizontal subsampling (1 = full res). |
| +0x05 | 1 | `u8` | `y_subsample` | per-channel vertical subsampling. |
| +0x06 | 2 | `u16` | `layer_id` | index into a layer-name table in `IMET` (`0xFFFF` = none); makes dotted-name layer grouping a declared structure, not a heuristic. |
| +0x08 | 2 | `u16` | `name_off` | byte offset, from the start of the `ChannelDesc[]` array's trailing name pool, of this channel's `len_str` name (`0xFFFF` = unnamed). |
| +0x0A | 2 | `u16` | `bit_depth` | significant bits for this channel. |
| +0x0C | 1 | `u8` | `is_signed` | `1` for signed integer channels (e.g. some data planes). |
| +0x0D | 1 | `u8` | `codec_id` | which codec codes this channel's plane when channels are coded separately (`0xFF` = coded together with the main stream). Reuses the codec registry (DRY). |
| +0x0E | 2 | `u16` | `default_value_lo` / | low 16 bits of the channel's declared default value (for channels narrower than the image, or for areas outside `data_window`). |
| +0x10 | 4 | `u32` | `default_value_hi` | high bits of the default value (interpreted per `sample_type`). |
| +0x14 | 4 | `u32` | `reserved` | must be 0. |

After the `ChannelDesc[]` array, a **name pool** of concatenated `len_str` entries referenced by `name_off`. The pool length is `payload_length − 0x10 − channel_count×24`.

This subsumes alpha/depth/spot/mask/id/normal/AOV: a reader knows every channel's type and meaning from the header, with no "channel 4 is always alpha" convention.

---

### 1.8 IMET — typed metadata (key→value table; EXIF/XMP/ICC as blobs)

A typed, length-bounded, forward-compatible metadata table. Always `CRITICAL=0` (skippable). The container treats EXIF/XMP/ICC strictly as **opaque blobs** kept out of the trusted decode path (their parsers never inform geometry/memory decisions). Payload:

| Off | Size | Type | Field |
|---|---|---|---|
| +0x00 | 8 | `u64` | `target_item_id` (`0xFFFF…FF` = file-global) |
| +0x08 | 4 | `u32` | `entry_count` |
| +0x0C | 4 | `u32` | reserved (0) |
| +0x10 | … | `MetaEntry[]` | the entries |

Each `MetaEntry`:

| Size | Type | Field | Meaning |
|---|---|---|---|
| var | `len_str` | `key` | UTF-8 key (e.g. `"layer.0.name"`, `"exif"`, `"xmp"`, `"icc"`). |
| 1 | `u8` | `value_type` | closed enum: `0`=I64, `1`=F64, `2`=F32_VEC, `3`=BOX2I, `4`=RATIONAL64, `5`=STRING (UTF-8), `6`=STRING_VEC, `7`=M44F, `8`=TIMECODE, `9`=BLOB_EXIF, `10`=BLOB_XMP, `11`=BLOB_ICC, `12`=BLOB_USER. (Closed; no free-form type strings — the Caustic fix to OpenEXR's stringly-typed attribute types.) |
| 1 | `u8` | `compress_algo` | `0`=none, `1`=DEFLATE-class shared toolkit, `2`=rANS-class shared toolkit (DRY; never an implicit zlib assumption). |
| 4 | `u32` | `value_length` | length of `value_bytes` (after decompression-meta; the on-disk byte count). Bounded by `ILIM.max_metadata_bytes`. |
| `value_length` | `u8[]` | `value_bytes` | the typed value; for BLOB_* it is opaque. |

An unknown `value_type` is **skippable by declared length** (forward-compat), but the type tag must still be in the closed enum range (else `E_CSIF_ENUM`). Charset is always UTF-8 (declared, no Latin-1 ambiguity).

---

### 1.9 ILIM — declared resource limits (mandatory, critical)

The container's first line of defence; read before any allocation. Payload is a fixed array of `u64` ceilings (all bounded, all declared):

| Off | Size | Field |
|---|---|---|
| +0x00 | 8 | `max_width` |
| +0x08 | 8 | `max_height` |
| +0x10 | 8 | `max_pixels` (`width×height` product cap) |
| +0x18 | 8 | `max_tile_pixels` |
| +0x20 | 8 | `max_alloc_bytes` (largest single buffer a reader may need) |
| +0x28 | 8 | `max_components` |
| +0x30 | 8 | `max_aux_channels` |
| +0x38 | 8 | `max_chunk_size` |
| +0x40 | 8 | `max_items` |
| +0x48 | 8 | `max_tiles` |
| +0x50 | 8 | `max_mip_levels` |
| +0x58 | 8 | `max_frames` |
| +0x60 | 8 | `max_reference_slots` |
| +0x68 | 8 | `max_derivation_depth` |
| +0x70 | 8 | `max_derivation_fanin` |
| +0x78 | 8 | `max_entropy_streams` |
| +0x80 | 8 | `max_ma_tree_nodes` |
| +0x88 | 8 | `max_palette_entries` |
| +0x90 | 8 | `max_patches` |
| +0x98 | 8 | `max_splines` |
| +0xA0 | 8 | `max_spline_points` |
| +0xA8 | 8 | `max_metadata_bytes` |
| +0xB0 | 8 | `max_manifests` |

Every ceiling must be ≤ the `profile`/`level` normative cap (§1.21), else `E_CSIF_LIMIT`. Every count/size in any other chunk is validated against the matching ceiling here.

---

### 1.10 ICOD — codec descriptor (the container↔codec seam)

`ICOD` is where the container hands off to a codec. It carries the dispatch id and tiling, and a **closed, versioned, codec-owned, opaque params blob** whose layout is defined by `(codec_id, codec_version)` — the container treats it as bytes (pure mechanism; the KObject-vtable analogy). Payload:

| Off | Size | Type | Field | Range / meaning |
|---|---|---|---|---|
| +0x00 | 8 | `u64` | `item_id` | owning coded item |
| +0x08 | 2 | `u16` | `codec_id` | closed registry: `0`=RAW, `1`=QOI, `2`=MODULAR, `3`=DCT, `4`=BLOCK(VarDCT), `5`=NEURAL, `6`=RAW_LOSSLESS(camera), `7`=JPEG_TRANSCODE, `8`=BILEVEL, `9`=INDEXED, `10..16`=BC1..BC7, `20..23`=ETC2/EAC, `30`=ASTC, `31`=UASTC_INTERMEDIATE, `32`=ETC1S_INTERMEDIATE, `33`=VECTOR, `64`=CMIX. Unknown ⇒ `E_CSIF_UNKNOWN_CODEC` (loud; never guessed). |
| +0x0A | 2 | `u16` | `codec_version` | gates the params-blob layout independently per codec. |
| +0x0C | 1 | `u8` | `is_lossless` | `1`/`0`. The container makes no assumption; it records the codec's declared fact. (For RAW/QOI/MODULAR-class lossless, decode must round-trip exactly; for float lossless, exact bit pattern incl. NaN/Inf/±0 — invariant stated in codec §.) |
| +0x0D | 1 | `u8` | `color_transform` | declared component transform stage decoupled from the codec: `0`=NONE, `1`=RCT(reversible), `2`=ICT(irreversible YCbCr), `3`=YCgCo-R. (Mirrors `is_lossless` honesty; reuses the shared colour toolkit.) |
| +0x0E | 1 | `u8` | `supercompress_id` | container-level supercompression applied **over** the codec payload (GPU/Zstd path): `0`=none, `1`=Zstd-class, `2`=raw. Separable declared layer (KTX2 lesson). |
| +0x0F | 1 | `u8` | `cross_tile_prediction` | **declared tile-independence invariant**: `0`=NONE (each tile fully independent, entropy state reset per tile — the default that enables ROI/partial/parallel), `1`=DECLARED_NEIGHBORS (the codec may predict across declared tile neighbours; decode order then matters and is declared in params). A reader KNOWS whether a single tile is self-contained. |
| +0x10 | 4 | `u32` | `tile_w` | tile width in pixels (`0` = single tile = full image). `1..` and ≤ width. |
| +0x14 | 4 | `u32` | `tile_h` | tile height. |
| +0x18 | 4 | `u32` | `n_tiles_x` | tile columns = `ceil(width / tile_w)` (stored explicitly; validated to match). |
| +0x1C | 4 | `u32` | `n_tiles_y` | tile rows = `ceil(height / tile_h)`. `n_tiles_x × n_tiles_y ≤ max_tiles`. |
| +0x20 | 4 | `u32` | `n_resolution_levels` | resolution levels for scalable codecs (`1` = none). |
| +0x24 | 4 | `u32` | `n_quality_layers` | quality layers (`1` = none). |
| +0x28 | 4 | `u32` | `progression_order` | `0`=NONE, `1`=LRCP, `2`=RLCP, `3`=RPCL, `4`=PCRL, `5`=CPRL (jp2 §). |
| +0x2C | 2 | `u16` | `entropy_method_id` | shared entropy substrate selection: `0`=rANS-static-interleaved, `1`=adaptive-CDF, `2`=prefix/Huffman, `3`=raw, `4`=binary-range(MQ-class). (Entropy §; the container only records the id.) |
| +0x2E | 1 | `u8` | `sub_image_count` | number of declared SubImage descriptors that follow (LF/DC image, quant field, color-correlation map, per-channel planes, partition map…). |
| +0x2F | 1 | `u8` | `reserved0` (0) |
| +0x30 | `sub_image_count × 16` | `SubImageDesc[]` | first-class sub-image descriptors |
| … | 4 | `u32` | `params_length` | byte length of the opaque codec params blob |
| … | `params_length` | `u8[]` | `params` | **opaque to the container**, layout owned by `(codec_id, codec_version)`. |

Each `SubImageDesc` (16 bytes) makes the JXL "everything-is-a-Modular-sub-image" concept first-class and **declared** (no hidden "JXL stores this in modular" magic):

| Off | Size | Type | Field |
|---|---|---|---|
| +0x00 | 1 | `u8` | `role` (`0`=LF/DC image, `1`=QUANT_FIELD, `2`=COLOR_CORRELATION, `3`=BLOCK_PARTITION_MAP, `4`=CONTEXT_MAP, `5`=CHANNEL_PLANE, `6`=FEATURES, `7`=MA_TREE) |
| +0x01 | 1 | `u8` | `codec_id` (which codec codes this sub-image; typically MODULAR) |
| +0x02 | 2 | `u16` | `channel_index` (for CHANNEL_PLANE; else `0xFFFF`) |
| +0x04 | 4 | `u32` | `sub_w` |
| +0x08 | 4 | `u32` | `sub_h` |
| +0x0C | 1 | `u8` | `bit_depth` |
| +0x0D | 1 | `u8` | `tidx_ref` (index into this item's `TIDX`/`EOFF` where this sub-image's bytes live; `0xFF`=inline-in-IDAT-0) |
| +0x0E | 2 | `u16` | reserved (0) |

A reader with an unknown `codec_id` fails loudly (`E_CSIF_UNKNOWN_CODEC`); the container never inspects `params`. This is the mechanism/policy seam done right: the container dispatches; the codec is policy; the params are a self-describing config blob like ISOBMFF's `av1C`.

---

### 1.11 IDAT — coded data (opaque, per-tile)

`IDAT` chunks carry the codec's opaque bitstream bytes. An item may have **multiple** `IDAT` chunks (one per tile, per resolution level, per quality pass, or per sub-image), addressed by the index chunks (`TIDX`/`IMIP`/`EOFF`/`QLYR`); a small image may have a single `IDAT`. `IDAT` is always `CRITICAL` and `IS_PAYLOAD`.

Payload structure:

| Off | Size | Type | Field |
|---|---|---|---|
| +0x00 | 8 | `u64` | `item_id` |
| +0x08 | 4 | `u32` | `idat_index` | ordinal among this item's `IDAT` chunks (referenced by indices) |
| +0x0C | 4 | `u32` | `coord_kind` | what this `IDAT` covers: `0`=WHOLE, `1`=TILE, `2`=RES_LEVEL, `3`=QUALITY_PASS, `4`=SUB_IMAGE, `5`=DEEP_TILE |
| +0x10 | 16 | `u32[4]` | `coords` | `(level, tile_x, tile_y, pass)` or `(sub_image_role, …)` per `coord_kind`; unused = `0` |
| +0x20 | … | `u8[]` | `codec_bytes` | **opaque** codec/entropy bitstream |

**Deep tiles (`sample_layout == DEEP`):** for `coord_kind == DEEP_TILE`, the `codec_bytes` begin with an explicit **sample-count table**: `u32 count[pixels_in_tile]` (so total sample count and all per-channel array lengths are computable and bounded **before** allocation), followed by the per-channel sample arrays whose lengths are `Σcount × type_width`. Fully derivable, no hidden allocation, bounded per tile. Z/ZBack channels are declared via `CHNL.role`.

The container never parses `codec_bytes`. Decode of any one `IDAT` requires memory bounded by its declared uncompressed size (from `TIDX`/`IHDR` geometry) + the codec's declared scratch — the freestanding/non-allocating invariant (rule #5) stated at the container level.

---

### 1.12 TIDX — tile index (per coded item, mandatory when tiled)

Makes tiles randomly addressable (true partial/ROI/parallel decode) and per-tile integrity-checkable. Payload:

| Off | Size | Type | Field |
|---|---|---|---|
| +0x00 | 8 | `u64` | `item_id` |
| +0x08 | 4 | `u32` | `entry_count` (= `n_tiles_x × n_tiles_y`, ≤ `max_tiles`) |
| +0x0C | 1 | `u8` | `integrity_algo` (`0`=none, `1`=CRC32, `2`=CRC32C) — per-tile checksum algorithm, **declared** |
| +0x0D | 3 | `u8[3]` | reserved (0) |
| +0x10 | `entry_count × 40` | `TileEntry[]` | |

Each `TileEntry` (40 bytes):

| Off | Size | Type | Field |
|---|---|---|---|
| +0x00 | 4 | `u32` | `tile_x` |
| +0x04 | 4 | `u32` | `tile_y` |
| +0x08 | 8 | `u64` | `idat_offset` (absolute file offset of the tile's coded bytes, inside an `IDAT`; validated ⊆ that `IDAT`'s payload, C-4) |
| +0x10 | 8 | `u64` | `stored_size` (compressed bytes on disk) |
| +0x18 | 8 | `u64` | `uncompressed_size` (decoded bytes; sizes a bounded buffer up front) |
| +0x20 | 4 | `u32` | `checksum` (per `integrity_algo`; `0` if none) |
| +0x24 | 4 | `u32` | `flags` (bit0 = independently-decodable, must be set when `cross_tile_prediction==NONE`) |

A reader maps a viewport rect → set of `(tile_x, tile_y)` → decodes only those tiles into caller buffers (bounded memory). On a tile checksum mismatch the reader reports the exact failing `(tile_x, tile_y)` loudly and may still decode the rest (honest, localized partial result — never silent garbage). This is JPEG2000-class error containment over AV1-class tiles.

---

### 1.13 IPAL — palette (explicit, separate colour table)

The palette is **not** embedded in the codec bitstream; it lives here (mechanism/policy split applied to colour: container owns the palette data, codec emits/consumes indices). Generalises PNG's PLTE (no 8-bit-RGB restriction) and subsumes palette transparency as the alpha channel of the entry. Payload:

| Off | Size | Type | Field |
|---|---|---|---|
| +0x00 | 8 | `u64` | `item_id` (or a shared-palette id referenced by frames) |
| +0x08 | 2 | `u16` | `entry_count` (`1..max_palette_entries`; **explicit**, not implied by byte count) |
| +0x0A | 1 | `u8` | `entry_channels` (e.g. 3=RGB, 4=RGBA — palette entries carry their own alpha; no magic transparent index) |
| +0x0B | 1 | `u8` | `entry_bit_depth` (per channel: 8/16) |
| +0x0C | 1 | `u8` | `entry_sample_format` (UINT8/UINT16/F16/F32 — palette colours managed identically to direct colour) |
| +0x0D | 1 | `u8` | `index_bits` (1/2/4/8 — sub-byte index packing for tiny palettes; **declared, never inferred from `entry_count`**) |
| +0x0E | 1 | `u8` | `pack_order` (`0`=MSB-first packing of indices along x) |
| +0x0F | 1 | `u8` | `is_suggested` (`0`=authoritative binding palette, `1`=quantization hint only) |
| +0x10 | `entry_count × entry_channels × ceil(entry_bit_depth/8)` | `u8[]` | the palette entries, in the item's declared colourspace (`ICOL`) |

Index alpha follows the file's single `IHDR.alpha_mode` (one alpha semantic; DRY). GIF's binary transparency is just the special case where alpha ∈ {0, max}.

---

### 1.14 IMIP — mip / resolution-level index (per coded item)

First-class resolution pyramid for trilinear sampling, texture streaming, and "decode at display size." Each level's geometry is **written**, not assumed-to-halve; each level's bytes are explicitly addressed. Payload:

| Off | Size | Type | Field |
|---|---|---|---|
| +0x00 | 8 | `u64` | `item_id` |
| +0x08 | 4 | `u32` | `level_count` (`1..max_mip_levels`) |
| +0x0C | 1 | `u8` | `level_order` (`0`=LARGEST_FIRST, `1`=SMALLEST_FIRST — **declared**, for streaming) |
| +0x0D | 1 | `u8` | `level_kind` (`0`=STORED_PYRAMID, `1`=CODEC_INTRINSIC e.g. wavelet subbands, `2`=DERIVED_FROM_DC) — a reader never assumes how levels arise |
| +0x0E | 1 | `u8` | `downsample_filter` (`0`=box, `1`=lanczos, `2`=wavelet-subband — **declared**, so two readers produce identical pixels) |
| +0x0F | 1 | `u8` | `rounding_mode` (`0`=DOWN, `1`=UP — how odd sizes halve; declared) |
| +0x10 | `level_count × 48` | `LevelEntry[]` | |

Each `LevelEntry` (48 bytes): `{ level_index:u32, width:u32, height:u32, depth:u32, layer_count:u32, face_count:u32, file_offset:u64, stored_size:u64, uncompressed_size:u64, checksum:u32, reserved:u32 }`. For array/cube/3D textures (`ITEX`, gpu §), the index granularity extends to `(level, layer, face)` via the `layer_count`/`face_count` fields, with the canonical iteration order (`for layer { for face { for z-slice { rows } } }`) declared in `ITEX`. A reader fetches only the levels/regions it needs into bounded buffers.

---

### 1.15 EOFF — entropy stream offsets (per coded item)

When the codec splits entropy data into independently-decodable streams (per tile × channel, or per group), `EOFF` declares each stream's byte range — exactly like CSE's segment table — so parallel/partial decode and error containment work at the entropy layer. Payload:

| Off | Size | Type | Field |
|---|---|---|---|
| +0x00 | 8 | `u64` | `item_id` |
| +0x08 | 4 | `u32` | `stream_count` (`1..max_entropy_streams`) |
| +0x0C | 4 | `u32` | reserved (0) |
| +0x10 | `stream_count × 32` | `StreamEntry[]` | |

Each `StreamEntry` (32 bytes): `{ stream_id:u32, tile_index:u32, channel_index:u32, file_offset:u64, length:u64, crc:u32 }`. Each stream is a self-contained entropy run (its own initial state / CDF reset). On a stream `crc` mismatch the reader returns a typed per-tile error (matches the kernel's fail-loud, bounded ethos). No stream is found by scanning; every offset is declared.

---

### 1.16 ITBL — item table (multi-image: the HEIF item model, Caustic-hardened)

`ITBL` turns the file from one raster into a set of typed, independently-addressable **items**: main image + thumbnails + alpha aux + depth + tiles-as-items + frames + metadata. It is mandatory and `CRITICAL` whenever the file holds more than one item (`header_flags.IS_MULTI_ITEM`). Payload:

| Off | Size | Type | Field |
|---|---|---|---|
| +0x00 | 4 | `u32` | `item_count` (`1..max_items`) |
| +0x04 | 4 | `u32` | reserved (0) |
| +0x08 | `item_count × 48` | `ItemRecord[]` | |

Each `ItemRecord` (48 bytes):

| Off | Size | Type | Field | Meaning |
|---|---|---|---|---|
| +0x00 | 8 | `u64` | `item_id` | **unique** id (collisions ⇒ `E_CSIF_ENUM`). |
| +0x08 | 4 | `u32` | `item_kind` | `0`=CODED, `1`=DERIVED, `2`=METADATA, `3`=AUXILIARY. |
| +0x0C | 4 | `u32` | `codec_or_deriv_id` | for CODED: the item's `ICOD.codec_id`; for DERIVED: the `deriv_id` (§1.18); for METADATA/AUX: a sub-type tag. |
| +0x10 | 4 | `u32` | `flags` | bit0=HIDDEN, bit1=IS_PRIMARY (must match header `primary_item_id`), bit2=AUXILIARY. |
| +0x14 | 4 | `u32` | `data_chunk_seq` | the `chunk_seq` of the item's first `IDAT`/`IDRV` chunk (the item's bytes live **inside this file** at a declared chunk; **no external/`mdat`-anywhere indirection**). |
| +0x18 | 8 | `u64` | `byte_offset` | absolute file offset of the item's coded bytes (validated ⊆ its data chunk, C-4 — rejects dangling/overlapping). |
| +0x20 | 8 | `u64` | `byte_length` | item byte length (validated). |
| +0x28 | 8 | `u64` | `header_chunk_seq` | the `chunk_seq` of the item's `IHDR` (geometry/properties for this item). |

**Container invariants the loader enforces (HEIF hardening, the Caustic way):** (1) every item byte range ⊆ its declared data chunk; (2) item ids unique; (3) exactly one item has `IS_PRIMARY` and it equals `primary_item_id`, and it is a CODED or DERIVED image with its full dependency closure present (else `E_CSIF_NO_PRIMARY`); (4) the DERIVED graph (via `IREF`) is acyclic with depth ≤ `max_derivation_depth` and fan-in ≤ `max_derivation_fanin` (cycles ⇒ `E_CSIF_CYCLE`); (5) each derived item's declared output geometry equals the geometry computed from its inputs (mismatch ⇒ `E_CSIF_GEOM`). These turn "parse defensively" into "the file is provably bounded."

**§1.16.3 — IAUX (auxiliary descriptor).** For an item with `item_kind == AUXILIARY`, an `IAUX` chunk declares its semantics with a **closed enum** (not a free-form URN): `aux_type ∈ {0=ALPHA, 1=DEPTH, 2=HDR_GAIN_MAP, 3=SEGMENTATION, 4=DISPARITY, 5=NORMAL, 6=USER}`, plus `is_premultiplied:u8`, `bit_depth:u8`, and a `user_tag:urn4` (for `USER`). The aux item is bound to its master by an `IREF` edge of type `AUX_OF` (§1.17). For `HDR_GAIN_MAP`, the reconstruction parameters live in `IGMP` (advanced §) — fully declared, deterministic.

---

### 1.17 IREF — typed item reference graph

Every inter-item relationship is explicit, directed, and machine-followable (no positional convention). Payload:

| Off | Size | Type | Field |
|---|---|---|---|
| +0x00 | 4 | `u32` | `ref_count` |
| +0x04 | 4 | `u32` | reserved (0) |
| +0x08 | … | `RefRecord[]` | |

Each `RefRecord`: `{ ref_type:u32, from_item:u64, to_count:u32, to_items:u64[to_count] }`. Closed `ref_type` registry: `0`=DERIVED_FROM, `1`=THUMBNAIL_OF, `2`=AUX_OF, `3`=DESCRIBES (metadata→image), `4`=PREDICTED_FROM (inter-frame), `5`=PYRAMID_LEVEL_OF, `6`=GAINMAP_FOR. The loader validates: every referenced `item_id` exists; `DERIVED_FROM` is acyclic; reference-kind constraints hold (e.g. `AUX_OF` target is a coded image). The primary item and its dependency closure are determined by walking `IREF`, never by position.

**Entity groups** (alternatives / stereo / burst) ride as a `GRPS`-style sub-record inside `IREF` or as a sibling chunk with a closed `group_kind` registry: `0`=ALTERNATIVES (preference order; reader uses first member whose codec is supported), `1`=STEREO_PAIR (`[left,right]` exactly), `2`=BURST, `3`=EXPOSURE_STACK. Member ordering semantics are spec-fixed; no free-form group type. This gives graceful degradation (ship a strong-codec image + a RAW/QOI fallback in one file) the explicit way.

---

### 1.18 IDRV — derived-image recipe (grid / overlay / identity / transform)

A DERIVED item's "pixels" are a declared recipe over other items — the container-level mechanism/policy seam parallel to the codec registry (a `{assemble}` interface mirroring `{decode,encode}`). Payload:

| Off | Size | Type | Field |
|---|---|---|---|
| +0x00 | 8 | `u64` | `item_id` (the derived item) |
| +0x08 | 4 | `u32` | `deriv_id` | closed registry: `0`=IDENTITY, `1`=GRID, `2`=OVERLAY, `3`=TRANSFORM |
| +0x0C | 4 | `u32` | `out_w` (declared output width; validated against computed geometry) |
| +0x10 | 4 | `u32` | `out_h` |
| +0x14 | 4 | `u32` | `param_length` |
| +0x18 | `param_length` | `u8[]` | recipe params (below) |

- **GRID** params: `{ rows:u32, cols:u32, tile_w:u32, tile_h:u32 }`; the input cells are the `DERIVED_FROM` items (in `IREF`), laid out row-major, output clipped to `out_w×out_h`. **Tile size is an explicit field — never inferred from the first tile.** Each cell may be any codec.
- **OVERLAY** params: `{ canvas_w:u32, canvas_h:u32, fill_rgba:u32[4], input_count:u32, per_input: { dx:i32, dy:i32, blend_mode:u32, opacity_q16:u32 }[] }`; composited in declared order. `blend_mode` closed enum (`0`=REPLACE, `1`=OVER, `2`=ADD, `3`=MUL).
- **TRANSFORM** params: `{ child_item:u64, crop:Rect, rotate:u32 (0/90/180/270), mirror:u32 (0=none,1=h,2=v) }`; applied in **declared, spec-fixed order** (crop → rotate → mirror) so two readers never disagree (the ISOBMFF irot/imir ambiguity is designed out).
- **IDENTITY** params: `{ child_item:u64 }`; the item's pixels are the child's, used to attach different `IHDR.orientation`/properties.

The recipe forms a DAG (child ids referenced via `IREF` are validated lower-index/acyclic). Geometry of the derived item must reconcile with its inputs (else `E_CSIF_GEOM`). A 100MP image is thus a GRID of small independently-coded tile items + a tiny recipe — bounded memory, parallel/partial decode, lossless rotate/crop, all over codec-agnostic items.

---

### 1.19 Animation, thumbnails, terminus

**IANI — animation header** (file-global, ≤1; presence ⇒ `header_flags.HAS_ANIMATION`):

| Off | Size | Type | Field |
|---|---|---|---|
| +0x00 | 4 | `u32` | `frame_count` (`1..max_frames`) |
| +0x04 | 4 | `u32` | `loop_count` (`0` = INFINITE — a declared sentinel, not implied) |
| +0x08 | 4 | `u32` | `timescale_hz` (ticks per second — **explicit timebase**, no implicit centiseconds) |
| +0x0C | 4 | `u32` | `n_reference_slots` (`1..max_reference_slots`; declares the bounded set of reference buffers up front) |
| +0x10 | 4 | `u32` | `max_snapshot_depth` (bound for PREVIOUS-disposal restore; keeps memory bounded) |
| +0x14 | 4 | `u32` | `canvas_w` |
| +0x18 | 4 | `u32` | `canvas_h` |
| +0x1C | 4 | `u32` | `background_rgba` |

**IFRM — frame control** (one per frame, ascending):

| Off | Size | Type | Field |
|---|---|---|---|
| +0x00 | 4 | `u32` | `frame_index` |
| +0x04 | 8 | `u64` | `item_id` (the coded item providing this frame's pixels) |
| +0x0C | 8 | `rational32`-pair | `duration_ticks` (`{num:i32, den:u32}` exact rational; ticks per `timescale_hz`) |
| +0x14 | 16 | `Rect` | `crop` (the frame's sub-rect on the canvas; frames carry only changed regions) |
| +0x24 | 4 | `u32` | `blend_op` (closed: `0`=SOURCE/replace, `1`=OVER/alpha-composite, `2`=ADD, `3`=MUL) |
| +0x28 | 4 | `u32` | `dispose_op` (closed: `0`=NONE/keep, `1`=BACKGROUND/clear-rect, `2`=PREVIOUS/restore-snapshot) |
| +0x2C | 4 | `u32` | `is_keyframe` (`1`=self-contained; `0`=delta, predicted via `IREF.PREDICTED_FROM`) |
| +0x30 | 4 | `u32` | `reference_slot` (which slot this frame may be saved into; `0xFFFFFFFF`=not saved) |
| +0x34 | 4 | `u32` | `save_as_reference` (`1`/`0`) |

Every compositing decision is a closed-enum field a reader reads; the reference graph is explicit; seeking to frame N and decoding back to its keyframe is a declared traversal (the `IREF` dependency closure). A still-only reader renders the `primary_item_id` and skips `IANI`/`IFRM` (they are `CRITICAL=0`).

**THUM — thumbnail set** (typed, multi-entry, index-backed). Payload: `{ entry_count:u32, ThumbEntry[] }` where each `ThumbEntry = { source:u32 (0=DERIVED_FROM_LEVEL, 1=INDEPENDENT_ITEM, 2=DERIVED_FROM_DC), level_index:u32, item_id:u64, width:u32, height:u32 }`. A derived thumbnail reuses the DC/level sub-image (zero duplication, always consistent); an independent thumbnail points to a separate coded item (any codec). The provenance is **declared**, so a reader knows whether the preview is bit-consistent with the full image. Ranked by explicit `width×height`.

**IHSH — whole-file strong hash** (≤1; presence ⇒ `header_flags.HAS_STRONG_HASH`). Payload: `{ hash_algo:u8 (0=BLAKE3-256, 1=SHA-256), exclusion_count:u32, exclusions:{offset:u64,length:u64}[], digest:u8[32] }`. The hashed input = whole file minus the declared exclusion ranges (which must cover at least `IHSH`'s own `digest` field and any `PROV` signature region). Tamper-evidence beyond per-chunk CRC.

**IEND — terminus** (mandatory, last, `CRITICAL`). Payload (24 bytes): `{ whole_file_checksum:u32 (per `checksum_algo`, over all bytes 0..start-of-IEND-payload), directory_offset_tail:u64 (back-pointer for streaming readers), reserved:u32, passes_decoded_marker:u64 (=0 for a complete file; truncation-resilience readers may write a partial status here only in repair tooling) }`. Absence ⇒ `E_CSIF_NO_IEND` (the file is truncated and the reader fails loud — never best-effort).

---

### 1.20 Tiling layout & the tile lattice (summary of the addressable substrate)

CSIF exposes **three explicit granularity levels** plus the resolution/quality axes, all declared, so partial/ROI/parallel/progressive decode are different *traversals of one addressable structure*:

1. **Item** (`ITBL`) — coarse independent images (and tiles-as-items via GRID derivation). Independent codec/colourspace per item.
2. **Tile** (`ICOD.tile_w/tile_h` + `TIDX`) — uniform grid within a coded item; each tile is an independently-decodable unit (`cross_tile_prediction==NONE`), randomly addressable by `(tile_x,tile_y)` → `TIDX` byte range, per-tile checksum for corruption containment. Tile boundary cells at the right/bottom edge are cropped to `data_window` (the partial tile's stored pixel count is `min(tile_w, width-tile_x·tile_w) × …`, declared via `TIDX.uncompressed_size`).
3. **Resolution level** (`ICOD.n_resolution_levels` + `IMIP`) and **quality layer** (`ICOD.n_quality_layers` + `QLYR`) — the scale and quality axes; each `(level)`/`(layer)` byte range is indexed, so a 1/4-size preview or a first-N-bytes quality prefix decodes from the same stream.
4. **Entropy stream** (`EOFF`) — the finest independently-entropy-decodable unit (per tile × channel × pass), with its own reset and optional CRC.

**Bounded-memory invariant (rule #5 at the container level):** decoding any single tile/level/stream requires memory bounded by that unit's declared `uncompressed_size` + the codec's declared scratch — never a whole-image buffer. A reader sizes every buffer from declared lengths **before** reading, allocates nothing implicitly, and reads only the byte ranges its viewport/quality/level request resolves to. Parallelism is a reader policy over the explicit indices; the container bakes in none.

**Dependency declaration (cross-cutting).** Across passes, levels, frames, and composition nodes, "unit X must be decoded before unit Y" is **explicit**: `IDAT.coord_kind`/`coords` + the index chunks declare what each unit covers; `IREF.PREDICTED_FROM` / `DERIVED_FROM` declare cross-item dependencies; `IFRM.is_keyframe` declares the frame keyframe chain. A reader closes the dependency set transitively and decodes exactly that — no "try decoding and see how far you get."

---

### 1.21 Profiles, levels, and the self-describing read strategy

**Profiles** (header `profile`, closed enum) declare the codec/feature subset a decoder must implement: `BASELINE` = {RAW, QOI, MODULAR, DCT}, 8/16-bit, no aux, no animation; `FULL` = + BLOCK/NEURAL/BILEVEL/INDEXED/VECTOR, HDR, aux channels, animation, composition; `GPU` = + block-compressed + transcodable codecs + `ITEX`/`IMIP` GPU layout; `PRO` = + float channels + deep + multipart + named channels + pro compression; `CAPTURE` = + `IRAW`/`IDEV` raw pipeline. **Levels** (header `level`) cap numeric worst-case work via the `ILIM` ceilings (max_pixels, max_tile_pixels, max_alloc_bytes, max_items, max_frames, …). A decoder first checks "do I implement this `profile` at this `level`?"; if not, it refuses cleanly (`E_CSIF_PROFILE` / `E_CSIF_LEVEL`) **before** allocating — never a partial, dangerous decode. The file's `ILIM` ceilings must be ≤ the declared level's normative caps.

**Read strategy is fully determined by three declared fields** — `layout` (random vs streaming, §1.1), `ICOD.progression_order` (the byte order of passes), and the directory + index chunks (the addressable byte ranges). A reader never sniffs: it reads `layout` and the explicit `directory_offset` (and `directory_offset_tail`/`IEND` for streaming), validates the whole structure in one bounded pass against `ILIM`, then mmaps-and-seeks (`RANDOM`) or decodes-as-it-arrives (`STREAMING`). Forward-compat is the CSE-family skippable-chunk rule (C-7); load-bearing data is always `CRITICAL`. Unknown `codec_id`/`deriv_id`/`entropy_method_id` fail loud with the exact id (`E_CSIF_UNKNOWN_CODEC`), never an alias — the device-model honesty (out-of-range index = error, not a guess) applied to the image format.

---

This completes Section 1. The container is a flat, fixed-header, directory-indexed, CRC-protected, fully-bounded TLV structure that is a true sibling of CSE (`"CSIF"` magic + version + declared endianness + explicit offset/size tables with widened-arithmetic range rejection + numbered loud errors + skippable forward-compat), and that carries — without ever interpreting — every codec bitstream, colour spec, entropy stream, tile/level/quality/entropy index, multi-item graph, derivation recipe, animation timeline, auxiliary plane, palette, metadata, thumbnail set, provenance store, and integrity hash that the later sections (codecs, toolkit, colour, entropy, lossless/MODULAR, progressive, GPU, raw, metrics, provenance, bilevel, vector) define as policy over this mechanism.

**Files referenced for family consistency (absolute paths):**
- `/home/caua/Documentos/Projetos-Pessoais/causticos/docs/CSE_FORMAT.md` — CSE byte-exact header/segment-table conventions this section mirrors.
- `/home/caua/Documentos/Projetos-Pessoais/causticos/kernel/sys/cse.cst` — the CSE loader whose validation discipline (`foff+fsz > size` rejection, `MAX_SEGS` bound, numbered `0-13..0-16` errors, locate-then-validate flow) is the model for C-4/C-5/§1.5 here.

---

I have a clear picture of the family conventions: little-endian, fixed-offset tables, explicit field-by-field tables, fail-loud loader rules, frozen-now/versioned-later discipline. Now I'll write section 2.

This is the complete specification text for section 2:

---

## 2. Pipeline de cor & HDR (CICP/ICC)

> **Escopo desta seção.** Define *todo* o sinal de cor do CSIF: o que cada amostra significa (modelo de canal), em que primárias vive (gamut), por qual função de transferência o valor-código mapeia para luz (EOTF/OETF), qual matriz converte entre RGB e luma/croma, qual é o intervalo de quantização, e — para HDR — qual é o volume de cor de masterização, o brilho de conteúdo, e o gain map que reconstrói uma renderização alternativa. **Nada aqui é inferido.** O CSIF segue a regra-mãe da filosofia Caustic: *"colorspace, gamma, endianness sempre declarados; zero heurística para adivinhar cor/gamma"*. Onde um formato de referência permite "Unspecified" e manda o leitor chutar (sRGB), o CSIF **proíbe** o chute: o valor `2 = Unspecified` do CICP é ilegal em todos os quatro campos. Um arquivo que não consegue se descrever em cor não é um CSIF conformante.

### 2.0. Princípios e contrato

1. **Tudo declarado, nada default-por-mágica.** A cor de um pixel é totalmente determinada pelo conjunto `{ sample_format, channel_layout, COLR (CICP ou ICC), faixa, siting }` mais, para HDR, os chunks descritivos `CLLI`/`MDCV`/`GMAP`. Um leitor reconstrói a cor *só* pelos cabeçalhos, sem conhecimento fora-de-banda.
2. **CICP é mecanismo; o codec é política.** O contêiner carrega os code points; o *toolkit de cor compartilhado* (`color/`) executa as conversões. Nenhum codec embute uma matriz ou uma curva — todos despacham pelos enums declarados (espelha o registry de codecs e a vtable KObject do kernel).
3. **Conjunto de operações fechado.** Primárias, transfer e matriz são enums **fechados e versionados**. Um valor fora da faixa declarada não é "vendor-específico" nem "tente o mais próximo" — é erro **alto e específico** (`E_CSIF_COLOR_*`), reportando o campo ofensor. Não há escape hatch além da rota ICC explícita.
4. **CICP *ou* ICC, com precedência declarada — nunca implícita.** O PNG/JPEG caem na armadilha de "se há ICC, ICC ganha, e você tem que saber disso". O CSIF torna a autoridade um campo (`color_authority`).
5. **Endianness fixa e declarada.** Todos os campos multi-byte de cor (chromaticities ST 2086, `intensity_target`, etc.) são **little-endian**, igual ao CSE. A endianness das *amostras de pixel* multi-byte é declarada explicitamente em IHDR (§2.5), não deduzida de `bit_depth`.
6. **Memória limitada.** Todo blob (ICC, gain map) é length-prefixed e validado contra os tetos de `ILIM` (ver seção de segurança) **antes** de qualquer alocação. ICC sobredimensionado já foi vetor de ataque; aqui é rejeitado por tamanho declarado.

A cor vive em um conjunto pequeno de estruturas, todas em chunks da família TLV do CSIF (magic+version+flags, `crc32`, bit skippable):

| Chunk | Crítico? | Conteúdo | Obrigatório quando |
|---|---|---|---|
| campo `COLR` em **IHDR** | crítico | bloco CICP (4 enums + faixa + siting) + `color_authority` | **sempre** (toda imagem) |
| **ICCP** | crítico se `color_authority=ICC*` | perfil ICC v2/v4 opaco, length-prefixed | quando `color_authority` ≠ `CICP` |
| **MDCV** | skippable (descritivo) | Mastering Display Color Volume (ST 2086) | recomendado p/ PQ; **obrigatório p/ PQ** (§2.6) |
| **CLLI** | skippable (descritivo) | MaxCLL / MaxFALL (CTA-861.3) | opcional |
| **GMAP** | crítico se referenciado por item de gain map | metadados de reconstrução do gain map (ISO 21496-1-class) | quando há aux item `GAIN_MAP` |

O **bloco CICP é parte mandatória do IHDR** — não é um chunk separado opcional, exatamente para que *nunca* exista um CSIF sem sinal de cor.

---

### 2.1. Bloco CICP em IHDR (4 enums + faixa + siting) — OBRIGATÓRIO

Layout fixo, little-endian. Posicione este bloco como sub-struct contígua dentro do IHDR (offsets relativos ao início do bloco CICP). Todos os escalares são `u8` salvo indicação; conforme o gotcha Caustic de structs de largura mista, na implementação Caustic cada campo é um `i64` independente — a serialização no arquivo é o byte declarado abaixo.

| Off | Size | Campo | Tipo | Valores válidos |
|---|---|---|---|---|
| +0x00 | 1 | `color_authority` | u8 enum | `0`=CICP, `1`=ICC, `2`=ICC_WITH_CICP_HINT |
| +0x01 | 1 | `color_primaries` | u8 enum | tabela §2.2 (H.273). `2` PROIBIDO |
| +0x02 | 1 | `transfer_function` | u8 enum | tabela §2.3 (H.273) + `255`=custom. `2` PROIBIDO |
| +0x03 | 1 | `matrix_coefficients` | u8 enum | tabela §2.4 (H.273). `2` PROIBIDO |
| +0x04 | 1 | `full_range` | u8 bool | `0`=limited/studio, `1`=full |
| +0x05 | 1 | `chroma_sample_position` | u8 enum | `0`=N/A (4:4:4 ou não-croma), `1`=co-sited(left), `2`=centered, `3`=top-left, `4`=top, `5`=bottom-left, `6`=bottom (H.273 `chroma_sample_loc_type`) |
| +0x06 | 1 | `h_subsample` | u8 | fator horizontal de subamostragem de croma: `1`=4:4:4, `2`=4:2:x |
| +0x07 | 1 | `v_subsample` | u8 | fator vertical: `1`, `2` (com `h=2,v=2`⇒4:2:0; `h=2,v=1`⇒4:2:2; `h=1,v=1`⇒4:4:4) |

**Regra de proibição de "Unspecified".** Os três code points `color_primaries`, `transfer_function`, `matrix_coefficients` **não podem** valer `2` (Unspecified de H.273). Um encoder conformante é proibido de emitir `2`; um decoder que encontra `2` em qualquer um deles retorna `E_CSIF_COLOR_UNSPECIFIED` nomeando o campo. Isto é a regra anti-mágica nº1 tornada normativa: o arquivo *tem* que escolher um valor real.

**Regra de consistência matriz↔canais.** `matrix_coefficients` tem que ser coerente com `channel_layout` (§2.5):
- `channel_layout` puramente RGB/Gray ⇒ `matrix_coefficients` **deve** ser `0` (Identity).
- `channel_layout = YCbCr` ⇒ `matrix_coefficients` **não pode** ser `0`.
- `channel_layout = ICtCp` ⇒ `matrix_coefficients` deve ser `14`.
- Combinação inconsistente ⇒ `E_CSIF_COLOR_MATRIX_MISMATCH` (alto, não "escolha uma").

**Regra de subsampling.** `h_subsample`/`v_subsample` só podem ser `>1` quando `channel_layout=YCbCr` (ou um modelo croma declarado). Para RGB/Gray devem ser `1`. `chroma_sample_position` deve ser `0` (N/A) quando `h_subsample=v_subsample=1`. O leitor **nunca** infere subsampling do tamanho dos dados — ele lê estes campos.

---

### 2.2. `color_primaries` — gamut (code points H.273 / ISO 23091-2)

Enum fechado. Os valores seguem ITU-T H.273 para interop direto com AVIF/HEVC/AV1; os demais são reservados a H.273 e ainda assim ilegais aqui se forem `2`.

| Code | Nome | Primárias R,G,B + white (CIE 1931 xy) |
|---|---|---|
| `1` | BT.709 / sRGB / Display-P3-não (sRGB) | R(.640,.330) G(.300,.600) B(.150,.060) W=D65(.3127,.3290) |
| `2` | **Unspecified — PROIBIDO** | — |
| `4` | BT.470 System M | R(.67,.33) G(.21,.71) B(.14,.08) W=C(.310,.316) |
| `5` | BT.470 System B/G (BT.601-625) | R(.64,.33) G(.29,.60) B(.15,.06) W=D65 |
| `6` | BT.601-525 / SMPTE 170M | R(.630,.340) G(.310,.595) B(.155,.070) W=D65 |
| `7` | SMPTE 240M | iguais a 170M, W=D65 |
| `8` | Generic film (C illuminant) | R(.681,.319) G(.243,.692) B(.145,.049) W=C |
| `9` | **BT.2020 / BT.2100 (Rec.2020 wide gamut)** | R(.708,.292) G(.170,.797) B(.131,.046) W=D65 |
| `10` | CIE 1931 XYZ | identidade XYZ |
| `11` | SMPTE RP 431-2 (DCI-P3, white=DCI) | R(.680,.320) G(.265,.690) B(.150,.060) W=DCI(.314,.351) |
| `12` | **SMPTE EG 432-1 (Display-P3, white=D65)** | R(.680,.320) G(.265,.690) B(.150,.060) W=D65 |
| `22` | EBU Tech 3213-E | R(.630,.340) G(.295,.605) B(.155,.077) W=D65 |

**Custom não vai aqui.** Para primárias arbitrárias que estes code points não nomeiam, use `color_authority=ICC` + chunk **ICCP** (§2.7) — *não* há "primárias customizadas inline" no CICP, mantendo o enum fechado. (As chromaticities **medidas do display de masterização** vão em MDCV §2.6, que é metadado descritivo, distinto das primárias do conteúdo.)

As coordenadas xy de cada code point são **constantes congeladas na spec** (tabela acima) e residem no módulo `color/` do toolkit; o decoder constrói a matriz primárias→XYZ(D50, com adaptação cromática Bradford declarada) a partir delas — nunca de números no arquivo (exceto a rota ICC).

---

### 2.3. `transfer_function` — EOTF/OETF (code points H.273) + curva paramétrica custom

Enum fechado. Cada code point mapeia para uma fórmula **exata e congelada** no toolkit. PQ e HLG **não são modos especiais** — são apenas code points de transfer; o decoder aplica a função nomeada.

| Code | Nome | Fórmula (valor-código *V*∈[0,1] → luz linear *L*; ou inverso) |
|---|---|---|
| `1` | BT.709 | OETF de câmera BT.709 (segmento linear 4.5·L p/ L<0.018; senão 1.099·L^0.45−0.099). Decodificação = inverso. |
| `2` | **Unspecified — PROIBIDO** | — |
| `4` | Gamma 2.2 (BT.470M) | L = V^2.2 |
| `5` | Gamma 2.8 (BT.470 B/G) | L = V^2.8 |
| `6` | BT.601 / 170M | mesma curva-câmera de BT.709 (code 1) |
| `7` | SMPTE 240M | segmento linear 4.0·L p/ L<0.0228; senão 1.1115·L^0.45−0.1115 |
| `8` | **Linear** | L = V (cena-linear; usado com float HDR) |
| `13` | **sRGB (IEC 61966-2-1)** | L = V/12.92 p/ V≤0.04045; senão ((V+0.055)/1.055)^2.4 |
| `14` | BT.2020 10-bit | curva-câmera BT.709 com constantes BT.2020 |
| `15` | BT.2020 12-bit | idem 12-bit |
| `16` | **PQ / SMPTE ST 2084 (HDR absoluto, 0–10000 cd/m²)** | constantes m1=2610/16384, m2=2523/4096·128, c1=3424/4096, c2=2413/4096·32, c3=2392/4096·32; L_abs = 10000·((max(V^(1/m2)−c1,0))/(c2−c3·V^(1/m2)))^(1/m1) |
| `18` | **HLG / ARIB STD-B67 / BT.2100 (HDR relativo)** | a=0.17883277, b=1−4a, c=0.5−a·ln(4a); OETF inverso por trechos + OOTF de sistema-gamma declarado |
| `255` | **custom paramétrico (definido pelo CSIF)** | dispara o sub-bloco `TF_CUSTOM` (§2.3.1) |

**Por que `8` Linear e `16` PQ importam juntos.** Linear (`8`) é a transfer canônica de cena-linear para amostras *float* HDR (OpenEXR-class). PQ (`16`) é display-referido e *absoluto* — por isso exige metadados de luminância (MDCV/`intensity_target`). HLG (`18`) é cena-referido e *relativo*. Os três são primeira-classe e selecionados pelo mesmo enum; nenhum é um "pipeline" separado.

#### 2.3.1. Sub-bloco `TF_CUSTOM` (quando `transfer_function = 255`)

Para *qualquer* curva de potência pura (ou potência com segmento linear) que um perfil ICC seria exagero. Toda em ponto-fixo — **sem float por mágica** — exatamente reconstruível do cabeçalho. Imediatamente após o bloco CICP no IHDR quando `transfer_function=255`.

| Off | Size | Campo | Tipo | Semântica |
|---|---|---|---|---|
| +0x00 | 4 | `gamma_num` | u32 | numerador do expoente γ |
| +0x04 | 4 | `gamma_den` | u32 | denominador (γ = num/den; `den≠0` ou erro) |
| +0x08 | 1 | `has_linear_seg` | u8 bool | `1`⇒há segmento linear na base |
| +0x09 | 4 | `slope_num` | u32 | inclinação do segmento linear (num) |
| +0x0D | 4 | `slope_den` | u32 | inclinação (den) |
| +0x11 | 4 | `threshold_num` | u32 | limiar V abaixo do qual o segmento linear vale (num) |
| +0x15 | 4 | `threshold_den` | u32 | limiar (den) |

Decodificação: `L = (slope_num/slope_den)·V` para `V < threshold_num/threshold_den` (se `has_linear_seg`); senão `L = V^(gamma_num/gamma_den)`. O decoder erra alto (`E_CSIF_COLOR_BAD_TF`) em `gamma_den=0`/`slope_den=0`/`threshold_den=0`. Um `transfer_function` desconhecido (≠ valores da tabela e ≠255) é **erro**, nunca "assuma sRGB".

---

### 2.4. `matrix_coefficients` — interpretação RGB↔luma/croma (code points H.273)

Enum fechado. Diz ao toolkit **qual** matriz RGB↔YCbCr (ou nenhuma) usar; não há matriz default implícita.

| Code | Nome | Semântica |
|---|---|---|
| `0` | **Identity / RGB / YCgCo-não** | amostras já são RGB (ou GBR); nenhuma matriz de luma. **Obrigatório** p/ canais RGB/Gray |
| `1` | **BT.709** | Kr=.2126, Kb=.0722 |
| `2` | **Unspecified — PROIBIDO** | — |
| `5` | BT.470 B/G | = BT.601 |
| `6` | **BT.601 / 170M** | Kr=.299, Kb=.114 |
| `7` | SMPTE 240M | Kr=.212, Kb=.087 |
| `8` | **YCgCo** | transformada YCgCo (não-reversível); ver §2.4.1 p/ a variante reversível |
| `9` | **BT.2020 NCL (non-constant luminance)** | Kr=.2627, Kb=.0593 |
| `10` | BT.2020 CL (constant luminance) | variante CL declarada |
| `14` | **ICtCp (BT.2100)** | espaço opponente perceptual; **obrigatório** p/ `channel_layout=ICtCp` |

#### 2.4.1. RCT reversíveis (espelho do toolkit MODULAR)

Para o codec **MODULAR** lossless, a transformada de cor reversível é uma **transformada declarada na lista ordenada do MODULAR** (não um `matrix_coefficients`), porque ela é integer-reversível por lifting e tem inversa exata. O toolkit `color/` expõe a **família RCT** (membro selecionado por `rct_type` nos params do MODULAR): `0=Identity`, `1=YCgCo-R` (lifting: `Co=R−B; t=B+(Co>>1); Cg=G−t; Y=t+(Cg>>1)`), `2..N`=combinações add/sub reversíveis dos três componentes (estilo JXL), cada uma com um campo `channel_permutation` explícito. O **+1 bit de headroom** dos canais de croma é **declarado por canal** no descritor de canal (§2.5), nunca assumido. As mesmas lifts servem o caminho YCbCr do DCT (DRY). `matrix_coefficients` no bloco CICP descreve a interpretação *colorimétrica* das amostras armazenadas; `rct_type` descreve a *transformada de decorrelação reversível* aplicada pelo codec — campos distintos, ambos explícitos.

---

### 2.5. Formato de amostra, profundidade, layout de canais e endianness

O CSIF substitui o `bit_depth` único do v1 por uma descrição completa, por-canal quando necessário (OpenEXR-class). Campos no IHDR:

#### 2.5.1. `sample_format` (enum fechado, u8)

| Code | Nome | Bytes/amostra | Formato |
|---|---|---|---|
| `0` | UINT8 | 1 | inteiro sem sinal 8-bit |
| `1` | UINT10 | 2 | uint 10-bit, justificado conforme `sample_pack` |
| `2` | UINT12 | 2 | uint 12-bit |
| `3` | UINT16 | 2 | uint 16-bit |
| `4` | **FLOAT16** | 2 | IEEE 754 binary16 (1-5-10) |
| `5` | **FLOAT32** | 4 | IEEE 754 binary32 (1-8-23) |

`FLOAT16`/`FLOAT32` habilitam HDR cena-linear de precisão (use tipicamente com `transfer_function=8` Linear ou `16` PQ). O CSIF declara, como invariante de spec: **codecs lossless preservam exatamente o padrão de bits de toda amostra float, incluindo NaN, ±Inf e zero-com-sinal**; codecs lossy declaram seu tratamento de valores não-finitos.

#### 2.5.2. Campos de profundidade/endianness/packing no IHDR

| Off | Size | Campo | Tipo | Semântica |
|---|---|---|---|---|
| — | 1 | `sample_format` | u8 enum | tabela §2.5.1 |
| — | 1 | `sample_endian` | u8 enum | `0`=little-endian (default da família, **mas declarado**), `1`=big-endian. CSIF v1 fixa `0`; o campo existe para nunca ser adivinhado |
| — | 1 | `sample_pack` | u8 enum | p/ UINT10/12 em contêiner 16-bit: `0`=LSB-justified, `1`=MSB-justified |
| — | 1 | `bit_depth` | u8 | profundidade *significativa* (8/10/12/16; p/ float = 16 ou 32, redundante c/ format mas declarada) |
| — | 1 | `sample_layout` | u8 enum | `0`=interleaved (RGBARGBA…), `1`=planar (RRR…GGG…BBB…) — **declarado**, não inferido |

#### 2.5.3. Modelo de canais — `channel_layout` + tabela de canais nomeados

`channel_layout` (u8 enum fechado) cobre os casos comuns auto-descritos: `0`=Gray, `1`=GrayA, `2`=RGB, `3`=RGBA, `4`=YCbCr, `5`=YCbCrA, `6`=CMYK, `7`=ICtCp, `8`=XYZ, `9`=**EXTENDED** (usa a tabela de canais nomeados, abaixo).

Quando `channel_layout=EXTENDED`, um **chunk CHNL** declara um array de `ChannelDesc`, um por canal lógico — modelo OpenEXR/JXL de pilha de canais arbitrários:

| Off | Size | Campo | Tipo | Semântica |
|---|---|---|---|---|
| +0x00 | 1 | `role` | u8 enum (fechado) | `0`=COLOR_R, `1`=COLOR_G, `2`=COLOR_B, `3`=ALPHA, `4`=GRAY/Y, `5`=Cb, `6`=Cr, `7`=DEPTH, `8`=DEPTH_BACK, `9`=NORMAL_X, `10`=NORMAL_Y, `11`=NORMAL_Z, `12`=OBJECT_ID, `13`=MOTION_X, `14`=MOTION_Y, `15`=MASK, `16`=SPOT, `17`=CMYK_K, `18`=AUX/arbitrário |
| +0x01 | 1 | `sample_format` | u8 enum | §2.5.1 — **por-canal** (ex.: cor FLOAT16, depth FLOAT32, id UINT32) |
| +0x02 | 1 | `is_color_managed` | u8 bool | `1`⇒este canal sofre o transform de colorspace (cor); `0`⇒**dado** (depth/id/normal/mask): a EOTF/primárias **não** se aplicam |
| +0x03 | 1 | `h_subsample` | u8 | subamostragem horizontal deste canal (croma full-res vs reduzida) |
| +0x04 | 1 | `v_subsample` | u8 | subamostragem vertical |
| +0x05 | 1 | `premul` | u8 enum | (só p/ ALPHA) ver §2.8 |
| +0x06 | 2 | `name_len` | u16 | comprimento do nome UTF-8 (p/ SPOT/AUX; `0` se não-nomeado) |
| +0x08 | … | `name` | bytes | nome UTF-8 (length-bounded por ILIM) |

`is_color_managed=false` é a declaração explícita de "não aplique a colorspace a este plano" — mata a heurística "isto parece um normal map?". Um leitor sabe o significado de **todo** canal pelo cabeçalho; não existe convenção "canal 4 é sempre alpha".

---

### 2.6. Metadados de volume de cor HDR — MDCV (ST 2086) + CLLI (CTA-861.3)

Dois chunks descritivos (skippable; um leitor que ignora HDR ainda decodifica). Não alteram pixels — informam o tone-mapping para displays-alvo. Todos os campos little-endian, ponto-fixo, com unidades **declaradas** byte-a-byte como em ST 2086.

#### 2.6.1. Chunk `MDCV` — Mastering Display Color Volume (SMPTE ST 2086)

| Off | Size | Campo | Tipo | Unidade |
|---|---|---|---|---|
| +0x00 | 2 | `primary_R_x` | u16 | incrementos de 0.00002 (valor·0.00002 = x) |
| +0x02 | 2 | `primary_R_y` | u16 | 0.00002 |
| +0x04 | 2 | `primary_G_x` | u16 | 0.00002 |
| +0x06 | 2 | `primary_G_y` | u16 | 0.00002 |
| +0x08 | 2 | `primary_B_x` | u16 | 0.00002 |
| +0x0A | 2 | `primary_B_y` | u16 | 0.00002 |
| +0x0C | 2 | `white_point_x` | u16 | 0.00002 |
| +0x0E | 2 | `white_point_y` | u16 | 0.00002 |
| +0x10 | 4 | `max_display_luminance` | u32 | 0.0001 cd/m² |
| +0x14 | 4 | `min_display_luminance` | u32 | 0.0001 cd/m² |

> **Nota de ordem das primárias.** O CSIF fixa a ordem **R, G, B** nos campos (ao contrário de HEVC SEI, que ordena G,B,R) — escolha congelada e documentada para nunca haver desacordo entre leitores.

#### 2.6.2. Chunk `CLLI` — Content Light Level (CTA-861.3)

| Off | Size | Campo | Tipo | Unidade |
|---|---|---|---|---|
| +0x00 | 2 | `max_cll` | u16 | cd/m² (máx. luminância por-pixel da imagem) |
| +0x02 | 2 | `max_fall` | u16 | cd/m² (máx. luminância média por-frame) |

#### 2.6.3. Regra de dependência explícita HDR

A filosofia troca "HDR geralmente tem isso" por uma dependência declarada:
- Se `transfer_function = 16` (PQ, **absoluto**): **MDCV é obrigatório** (`E_CSIF_HDR_MDCV_MISSING` se ausente) — PQ sem display de masterização não tem como ser tonemapeado corretamente.
- Se `transfer_function = 18` (HLG, **relativo**): MDCV/CLLI são recomendados, opcionais.
- `CLLI` é sempre opcional, mas se presente é confiável (encoder o computou).

Estes chunks são puramente descritivos: o **decoder nunca consome** estes números na matemática de decodificação — só o tone-mapper (política do renderer) os lê. Mantém mecanismo/política limpos.

---

### 2.7. Perfil ICC embutido — chunk `ICCP` + precedência declarada

Para colorspaces que os enums CICP não nomeiam (scanners, câmeras, fluxos CMYK de impressão, working spaces proprietários). Blob ICC v2/v4 **opaco** ao contêiner (o parse ICC é política, vive no toolkit `color/`).

| Off | Size | Campo | Tipo | Semântica |
|---|---|---|---|---|
| +0x00 | 4 | `icc_len` | u32 | comprimento do perfil em bytes (validado ≤ `ILIM.max_icc_bytes` **antes** de alocar) |
| +0x04 | 1 | `rendering_intent` | u8 enum | `0`=perceptual, `1`=relative-colorimetric, `2`=saturation, `3`=absolute-colorimetric (espelha ICC; **explícito**, não lido só de dentro do perfil) |
| +0x05 | 3 | `reserved` | — | zero |
| +0x08 | `icc_len` | `icc_data` | bytes | perfil .icc cru |

**Precedência — o campo `color_authority` (em IHDR §2.1) decide, sem regra implícita:**

| `color_authority` | Significado normativo |
|---|---|
| `0 = CICP` | Os 4 enums CICP são autoritativos. **ICCP é proibido** (se presente ⇒ `E_CSIF_COLOR_ICC_UNEXPECTED`). |
| `1 = ICC` | O perfil **ICCP** é autoritativo. O bloco CICP **ainda é obrigatório e válido** (regra anti-Unspecified continua valendo) e serve como *fast-path hint* — mas o byte declara que o ICC vence. **ICCP é obrigatório** (se ausente ⇒ `E_CSIF_COLOR_ICC_MISSING`). |
| `2 = ICC_WITH_CICP_HINT` | Idêntico a `1`, porém o encoder garante que o CICP é uma aproximação fiel do ICC (leitores sem CMM podem usar o CICP com confiança declarada). **ICCP obrigatório.** |

Isto elimina a armadilha PNG/JPEG do "ICC sobrescreve, e você tinha que saber": a autoridade é um campo que o leitor lê.

---

### 2.8. Semântica de alpha — totalmente declarada

O bug nº1 silencioso de composição é alpha straight-vs-premultiplied implícito. O CSIF promove `alpha_premul` do v1 a um descritor explícito. Para alpha no `channel_layout` comum (GrayA/RGBA/YCbCrA), os campos vivem num sub-bloco `ALPHA_DESC` no IHDR; para EXTENDED, no `ChannelDesc` do canal ALPHA.

| Off | Size | Campo | Tipo | Semântica |
|---|---|---|---|---|
| +0x00 | 1 | `present` | u8 bool | há canal alpha |
| +0x01 | 1 | `assoc` | u8 enum | `0`=STRAIGHT (não-associado), `1`=PREMUL (associado, em espaço codificado), `2`=PREMUL_LINEAR (associado, pré-multiplicado em luz linear) |
| +0x02 | 1 | `alpha_bit_depth` | u8 | pode diferir da cor |
| +0x03 | 1 | `alpha_is_linear` | u8 bool | o canal alpha é interpretado linear (`1`) ou codificado (`0`) |

A fórmula **OVER** é selecionada *só* por `assoc`, nunca farejada:
- STRAIGHT: `out = src.a·src + (1−src.a)·dst`
- PREMUL / PREMUL_LINEAR: `out = src + (1−src.a)·dst` (com a operação no espaço declarado por `alpha_is_linear`)

`PREMUL_LINEAR` é distinto e importante para composição filtrada/GPU correta (bilinear interpola corretamente apenas em premultiplied; e em luz linear para blends fisicamente corretos). Um único `assoc`/`alpha_is_linear` por arquivo vale para alpha de paleta também (DRY; ver seção de cor indexada).

---

### 2.9. HDR gain map — chunk `GMAP` (ISO 21496-1-class)

O recurso de HDR de arquivo-único mais moderno: uma imagem-base (tipicamente SDR) + um **gain map** auxiliar (um mapa de multiplicador log2 por pixel, possivelmente em resolução reduzida) + metadados que reconstroem a renderização HDR. Um leitor que ignora `GMAP` renderiza a base SDR honesta; um leitor HDR aplica a matemática **declarada**.

O gain map **não é um caminho novo**: é um *item auxiliar* (`aux_type = GAIN_MAP`) — um plano de canal codificado pelo mesmo registry de codecs (DRY) — mais este chunk `GMAP` carregando os parâmetros de reconstrução. Vinculado à base por uma referência `AUX_OF`/`GAINMAP_FOR` (ver seção de contêiner). A matemática de reconstrução é **congelada na spec**.

| Off | Size | Campo | Tipo | Semântica |
|---|---|---|---|---|
| +0x00 | 1 | `channel_count` | u8 | `1` (gain mono) ou `3` (gain por-canal RGB) |
| +0x01 | 1 | `base_is_hdr` | u8 bool | `0`=base é SDR (gain *aumenta* p/ HDR), `1`=base é HDR (gain *reduz* p/ SDR) |
| +0x02 | 1 | `gain_apply_space` | u8 enum | `0`=aplicar em luz linear, `1`=aplicar no transfer declarado da base |
| +0x03 | 1 | `reserved` | — | zero |
| por-canal (×`channel_count`): | | | | |
| +… | 4 | `gain_map_min_num` | i32 | min do range log2 (num) |
| +… | 4 | `gain_map_min_den` | u32 | (den) |
| +… | 4 | `gain_map_max_num` | i32 | max do range log2 (num) |
| +… | 4 | `gain_map_max_den` | u32 | (den) |
| +… | 4 | `gamma_num` | u32 | gamma de codificação do mapa (num) |
| +… | 4 | `gamma_den` | u32 | (den) |
| +… | 4 | `base_offset_num` | i32 | epsilon do base (num) |
| +… | 4 | `base_offset_den` | u32 | (den) |
| +… | 4 | `alt_offset_num` | i32 | epsilon da renderização alternativa (num) |
| +… | 4 | `alt_offset_den` | u32 | (den) |
| no fim (escalares globais): | | | | |
| +… | 4 | `base_hdr_headroom_num` | u32 | headroom HDR de referência da base, em stops (num) |
| +… | 4 | `base_hdr_headroom_den` | u32 | (den) |
| +… | 4 | `alt_hdr_headroom_num` | u32 | headroom HDR da renderização alternativa (num) |
| +… | 4 | `alt_hdr_headroom_den` | u32 | (den) |

Todos os parâmetros são **racionais ponto-fixo** (pares `num/den` i32/u32) — sem float por mágica, byte-exato e reproduzível (`den=0` ⇒ `E_CSIF_GMAP_BAD_PARAM`). A reconstrução por pixel (por canal `c`), com `m` = valor decodificado do gain map ∈[0,1]:

```
logBoost_c = lerp(gain_map_min_c, gain_map_max_c, m^(1/gamma_c))
HDR_c      = (base_c + base_offset_c) · 2^(logBoost_c · weight) − alt_offset_c
```

onde `weight` interpola entre `base_hdr_headroom` e `alt_hdr_headroom` conforme o headroom do display-alvo (clamp aos limites). A equação completa, a ordem das operações e o espaço (`gain_apply_space`) são **normativos** na spec — reprodução determinística, zero mágica proprietária. Mecanismo (contêiner carrega base + mapa + params) vs política (o boost no toolkit `color/`) perfeitamente separados.

---

### 2.10. O pipeline de decodificação de cor (ordem normativa)

Dado um CSIF conformante, um decoder reconstrói cor exibível assim (cada passo lê *só* campos declarados):

1. Ler IHDR: `sample_format`, `sample_endian`, `sample_pack`, `sample_layout`, `channel_layout` (+ CHNL se EXTENDED), `ALPHA_DESC`, e o bloco CICP (`color_authority`, 4 enums, faixa, siting, subsampling).
2. **Validar** (alto/loud em falha): nenhum dos 3 enums é `2`; matriz↔canais consistente; subsampling↔layout consistente; `color_authority` vs presença de ICCP; PQ⇒MDCV presente.
3. Desempacotar amostras conforme `sample_format`/`sample_endian`/`sample_pack`/`sample_layout` (codec já entregou inteiros/floats brutos).
4. Se `full_range=0`, expandir do studio-swing para full conforme `bit_depth` (passo declarado, tabela de níveis na spec).
5. Se `matrix_coefficients ≠ 0`, aplicar a matriz inversa (croma→RGB) selecionada pelo code point — após upsample de croma conforme `chroma_sample_position`/subsampling (filtro de upsample **declarado** na spec). Para MODULAR, em vez disso desfazer a `rct_type` declarada (inversa exata).
6. Aplicar a **inversa da `transfer_function`** (EOTF) para obter luz linear — *só* nos canais com `is_color_managed=true`. Canais de dado (`is_color_managed=false`) passam intactos.
7. Mapear primárias→XYZ(D50, Bradford) se for fazer color management; ou aplicar o **ICCP** via CMM se `color_authority≠CICP` (intent = `rendering_intent`).
8. (HDR opcional) Se `GMAP` presente e o leitor é HDR-aware, aplicar a reconstrução do gain map (§2.9). Tone-map usando MDCV/CLLI conforme o display-alvo.
9. Compor alpha pela fórmula selecionada por `ALPHA_DESC.assoc` (§2.8).

Cada passo é mecanismo puro lendo dados declarados; toda *escolha* (qual matriz, qual curva, qual intent) já está no arquivo. O encoder pode ter usado heurística para *escolher* — isso é política, invisível ao bitstream.

---

### 2.11. Códigos de erro de cor (loud, com campo ofensor)

A spec de conformância exige falha fechada (loud, nível-de-campo) em cor sub-especificada — espelhando a postura B2 do kernel ("falhe alto, sem hang"). Encoders são **proibidos** de emitir qualquer estado que dispare estes:

| Código | Disparo |
|---|---|
| `E_CSIF_COLOR_UNSPECIFIED` | `color_primaries`/`transfer_function`/`matrix_coefficients` = `2` |
| `E_CSIF_COLOR_BAD_ENUM` | code point fora da tabela fechada (e ≠255 p/ transfer) |
| `E_CSIF_COLOR_MATRIX_MISMATCH` | `matrix_coefficients` incoerente com `channel_layout` |
| `E_CSIF_COLOR_SUBSAMPLE_INVALID` | subsampling >1 em RGB/Gray, ou siting≠N/A em 4:4:4 |
| `E_CSIF_COLOR_BAD_TF` | `den=0` em `TF_CUSTOM` |
| `E_CSIF_COLOR_ICC_UNEXPECTED` | ICCP presente com `color_authority=CICP` |
| `E_CSIF_COLOR_ICC_MISSING` | `color_authority=ICC*` sem ICCP |
| `E_CSIF_COLOR_ICC_OVERSIZE` | `icc_len > ILIM.max_icc_bytes` |
| `E_CSIF_HDR_MDCV_MISSING` | `transfer_function=16` (PQ) sem chunk MDCV |
| `E_CSIF_GMAP_BAD_PARAM` | `den=0`/range inválido em GMAP |

Cada erro reporta o campo (offset + nome) ofensor. Nenhum substitui silenciosamente um default — *não há* default de cor no CSIF.

---

**Resumo da redação Caustic desta seção:** o `colorspace` único e vago do v1 vira `{ bloco CICP obrigatório (4 enums + faixa + siting + subsampling), TF_CUSTOM paramétrico, sample_format incl. float16/32 com endianness/packing/layout declarados, tabela de canais nomeados com is_color_managed, ALPHA_DESC com associação explícita, ICCP com precedência declarada via color_authority, MDCV/CLLI com dependência PQ⇒MDCV normativa, e GMAP de gain map racional-exato }` — toda a cor 100% auto-descrita, conjunto de enums fechado, "Unspecified" proibido, falha alta, mecanismo (contêiner) separado de política (toolkit `color/`).

---

The `caustic-image` directory is empty — this is a greenfield spec. I have everything I need: the CSE family conventions (header tables, `let is i64 as` constants, numbered negative errors, little-endian, fail-loud, fixed-stride validated tables) and the complete research dossier. I'll now write section 3 — the bit-exact rANS entropy coder spec.

I'll write it as exhaustive, byte-exact specification text consistent with the Caustic philosophy and CSE family conventions.

Here is my final response — the complete section 3 spec content:

---

## 3. Entropy coder (rANS) — bit-exact

This section specifies the **single shared entropy substrate** of CSIF: the bit-exact contract every codec (RAW, QOI, MODULAR, DCT, BLOCK, NEURAL, BILEVEL, INDEXED, VECTOR, the GPU/transcode codecs, and any future codec) uses to turn modeled symbols into bytes and back. It is the *mechanism*; how a codec computes a context or a token is *policy* defined in that codec's section. Nothing here is heuristic, nothing is implementation-defined: every probability, every renormalization bound, every table-build step, every byte of I/O direction is pinned to an integer-only algorithm written out below, so any two conformant implementations produce **byte-identical** output for the same symbols and reconstruct **bit-identical** symbols from the same bytes.

The substrate is a closed op-set mirroring the kernel's KObject vtable: a codec calls exactly `{ec_init, ec_decode_symbol, ec_encode_symbol, ec_flush}` plus the raw-bits and hybrid-token helpers, and **never** touches the state words, the byte stream, or the tables directly. There is no escape hatch and no side channel that bypasses this interface.

### 3.0. Scope, conventions, invariants

These invariants are normative and frozen at self-host. They are restated as a single table because, per the philosophy, **endianness, bit-order, and stream direction are always declared, never assumed** (the deepest historical interop bugs in JPEG/PNG are exactly these).

| Invariant | Frozen value | Notes |
|---|---|---|
| `STATE_BITS` | `32` | each rANS lane state `x` is a `u32` |
| arithmetic width | `u64` | all intermediate products use 64-bit integers; **no floating point anywhere in the coding loop** |
| `RANS_L` (renorm floor) | `1 << 16` = `0x10000` | the lower bound of the normalized state interval `[L, L·b)` |
| `RANS_B` (renorm radix) | `1 << 8` = `256` | renormalization emits/consumes **whole bytes** |
| state interval | `[L, L·b) = [0x10000, 0x1000000)` | a normalized lane state is always in this half-open range |
| precision `M` (`total_bits`) | `4..16`, default `12` ⇒ `TOTAL = 1<<12 = 4096` | declared per stream; `TOTAL` is the sum of all symbol frequencies |
| container endianness | little-endian | all multi-byte container/header fields; matches CSE |
| extra-bits substream bit order | **LSB-first** | for the rANS and adaptive-CDF paths (see §3.7) |
| prefix-code (Huffman) bit order | **MSB-first** | only for `entropy_method_id = 2` (see §3.10) |
| stream direction | encoder writes **backward**, decoder reads **forward** | a consequence of rANS being LIFO; pinned, not a choice |
| signed→unsigned mapping | zig-zag `(v<<1) ^ (v>>31)` (32-bit) | §3.7; the choice is declared per context, never sniffed |
| guaranteed-nonzero floor | every **used** symbol has freq `≥ 1` | §3.6; no used symbol may have frequency 0 |

> **Why `L = 1<<16`, `b = 256`, `M ≤ 16`.** With byte renorm (`b = 256`) the normalized interval is `[2^16, 2^24)`. The exact-renorm condition for static rANS requires `L` to be a multiple of `TOTAL` divided into the interval, and requires `b · L_low ≤ 2^STATE_BITS` to never overflow a `u32` state across one byte of renorm: `256 · 0xFFFFFF = 0xFFFFFF00 < 2^32`. ✔. The encoder's per-symbol upper bound (`x_max = ((L >> M) << 8) · freq`, §3.5) must stay `< 2^32` for the largest `freq ≤ TOTAL = 2^M`; this holds for all `M ≤ 16`. Hence `M` is range-limited `[4, 16]`. A stream declaring `M` outside `[4,16]` is **rejected loudly** (`E_CSIF_EC_PRECISION`, §3.12).

**Coordinate of "byte-exact".** The format ships a frozen conformance corpus (§3.11): tuples of `(ECParams, context sequence, symbol sequence) → exact output bytes`, and the reverse. A decoder is conformant iff it reproduces every symbol bit-exactly; an encoder is conformant iff it reproduces every output byte. This is checked by a `verify.sh`-style harness, the same discipline the OS uses for self-host.

### 3.1. The substrate vtable and method registry

A stream's entropy method is selected by an explicit `entropy_method_id` in the `ECTX` header (§3.4); the container dispatches by id and **never inlines a method**. The registry is closed:

| `entropy_method_id` | Method | §  | Mandatory |
|---|---|---|---|
| `0` | **rANS-static-interleaved** (the default substrate) | §3.5–3.6 | yes |
| `1` | **adaptive multi-symbol CDF** (table-free, normatively-updated) | §3.9 | yes |
| `2` | **prefix code** (canonical, length-limited Huffman) | §3.10 | yes |
| `3` | **raw passthrough** (store; for incompressible / RAW codec) | §3.10.1 | yes |
| `4..239` | reserved (future frozen methods) | — | — |
| `240..255` | private/experimental (declared, never auto-selected) | — | — |

Each method is a record of function pointers (the Caustic `call()` convention applies — these are invoked via function-pointer call):

```
struct EntropyCodec {
    fn init       (st as *ECState, p as *const ECParams) as i32   // 0 = ok, <0 = error
    fn decode_sym (st as *ECState, ctx as i64) as i64             // returns symbol; <0 = error sentinel
    fn encode_sym (st as *ECState, ctx as i64, sym as i64) as i32 // 0 = ok, <0 = error
    fn flush      (st as *ECState) as i32                         // finalize the stream
}
```

`entropy_method_id` indexes a fixed array of `EntropyCodec` (the registry). The four-entry op-set is the *whole* honest interface; a codec gets the entropy engine, a closed set of context tables, and the hybrid-token + raw-bits helpers, and nothing else.

Bounded memory: `ECState` and all tables are sized **from declared header fields before any decode begins**. The caller passes the output buffer and a bounded scratch region. There is **no hidden allocation** inside any method (freestanding/non-allocating stdlib rule).

### 3.2. The rANS lane state

```
let is i64 as RANS_LANES_MAX = 32;   // declared ceiling; lane_count ∈ [1, 32]

struct RansState {
    x as [RANS_LANES_MAX]u32          // K active lanes; only x[0..lane_count) used
}
```

`lane_count` (`K`) is a declared `ECParams` field (`1..32`), never dynamic. State words are little-endian `u32`. The decoder advances lanes per the declared `interleave_layout` (§3.8). All lanes share **one** byte stream.

### 3.3. Frequency / CDF table format and precision

A static rANS distribution over an alphabet of `n` symbols is fully described, for a declared precision `M` (`TOTAL = 1<<M`), by:

- `freq[s]` — the normalized frequency of symbol `s`, `s ∈ [0, n)`. `Σ freq[s] = TOTAL` exactly. Every **used** symbol has `freq[s] ≥ 1`.
- `cum[s]` — the cumulative (start) of symbol `s`: `cum[0] = 0`, `cum[s] = cum[s-1] + freq[s-1]`. `cum[n] = TOTAL`.

The decoder additionally needs an **inverse map** from a *slot* `r ∈ [0, TOTAL)` to its owning symbol. CSIF mandates the **alias method** (Vose/Walker) as the single canonical lookup so decode is O(1) and table build is deterministic:

```
struct AliasTable {
    M          as i64                 // precision bits; TOTAL = 1<<M
    n          as i64                 // alphabet size
    bucket_div as i64                 // = TOTAL / n  (alias divides the slot space into n equal buckets)
    // per-symbol:
    freq       as *u16                // freq[s]
    cum        as *u16                // cum[s]
    // per-bucket (n buckets, each of width bucket_div):
    alias_sym  as *u16                // alias_sym[b]  : the "large" symbol filling bucket b's tail
    alias_div  as *u16                // alias_div[b]  : split point within bucket b
    alias_off  as *u16                // alias_off[b]  : cum-offset of the primary symbol in bucket b
}
```

**Constraint:** `TOTAL` must be an exact multiple of `n` for the equal-bucket alias layout (`bucket_div = TOTAL / n`, `n ≤ TOTAL`). When a codec's alphabet does not divide `TOTAL`, the codec **pads the alphabet to the next divisor with zero-frequency (unused) symbols** and declares the padded `n` in the table header — explicit, never inferred. (The hybrid-token scheme of §3.7 keeps real alphabets to ≤ a few dozen symbols, so padding cost is negligible.)

#### 3.3.1. Serialized static-table block

When `entropy_method_id = 0`, each entropy stream's tables are carried in the `IDAT`-resident table block referenced by the `EOFF` entry (§3.8). The serialization is fixed-width and self-describing:

| Off | Size | Field | Meaning |
|---|---|---|---|
| +0x00 | 1 | `M` (u8) | precision; `TOTAL = 1<<M`; must be `4..16` |
| +0x01 | 1 | `table_src` (u8) | `0`=inline counts here; `1`=predefined table id in next field; `2`=reference a prior in-file table by index |
| +0x02 | 2 | `n` (u16) | padded alphabet size (divides `TOTAL`) |
| +0x04 | 2 | `table_ref` (u16) | predefined table id (`table_src=1`) or in-file table index (`table_src=2`); else `0` |
| +0x06 | 2 | `reserved` (u16) | must be `0` |
| +0x08 | `n`×2 | `freq[0..n)` (u16[]) | present iff `table_src=0`; the normalized frequencies, `Σ = TOTAL` |

For `table_src = 0` the decoder reads `freq[]`, validates `Σ freq = TOTAL` exactly (`E_CSIF_EC_TABLESUM` on mismatch), validates every `freq[s] ≤ TOTAL`, then builds `cum[]` and the `AliasTable` by the §3.6 algorithm. For `table_src = 1` the predefined table id selects a **spec-frozen, versioned** count table (referenced by id, the cold-start path for small data); the decoder rebuilds it identically. For `table_src = 2` the table is shared by reference with a previously-decoded stream (DRY: ten tiles can share one histogram). The `table_ref`/index must point to an already-parsed table earlier in file order, else `E_CSIF_EC_TABLEREF`.

> No table is ever found by scanning or guessing. Every table is either inline (declared length), a frozen predefined id, or an explicit back-reference — the file is 100% self-describing about which distribution decodes which symbol.

### 3.4. The `ECTX` stream-context header

Per coded unit that uses entropy (tile × channel group, see §3.8), an `ECTX` record declares the substrate parameters. It is fixed-width:

| Off | Size | Field | Meaning |
|---|---|---|---|
| +0x00 | 1 | `entropy_method_id` (u8) | registry index (§3.1) |
| +0x01 | 1 | `precision_M` (u8) | `TOTAL = 1<<M`; `4..16` |
| +0x02 | 1 | `lane_count` (u8) | rANS interleave width `K`, `1..32`; ignored for methods 1/2/3 |
| +0x03 | 1 | `interleave_layout` (u8) | `0`=round-robin, `1`=block-interleave (§3.8); ignored if `K=1` |
| +0x04 | 2 | `context_count` (u16) | number of distributions/CDFs `Kctx` actually stored |
| +0x06 | 2 | `flags` (u16) | bit0 = `reset_per_tile` (adaptive CDF, §3.9); bit1 = `has_ctxmap` (§3.6.3); bit2 = `hybrid_present` (§3.7); bit3 = `crc_present` per-stream (§3.12) |
| +0x08 | 1 | `hybrid_split_exponent` (u8) | `HybridConfig.split_exponent` (§3.7); valid iff bit2 set |
| +0x09 | 1 | `hybrid_msb_in_token` (u8) | `HybridConfig.msb_in_token` |
| +0x0A | 1 | `hybrid_lsb_in_token` (u8) | `HybridConfig.lsb_in_token` |
| +0x0B | 1 | `reserved` (u8) | must be `0` |
| +0x0C | 4 | `ctxmap_len` (u32) | bytes of the context-map block (§3.6.3); `0` if `has_ctxmap`=0 |

The `ECTX` is followed by: the context-map block (if `has_ctxmap`), then the `context_count` table blocks (§3.3.1 for method 0; default-CDF references for method 1; code-length tables for method 2). A reader knows the *entire* memory footprint — lane states, `Kctx` tables of `n` `u16`s each, the alias scratch (`TOTAL` slots), the context map, and the hybrid config — from this header **before** touching the byte stream.

### 3.5. rANS-static encode/decode, bit-exact (`entropy_method_id = 0`)

This is the normative core. All operations are integer; the renorm direction is the pinned invariant (encode writes bytes backward, decode reads forward).

#### 3.5.1. Decode of one symbol under a chosen distribution `D` (one lane `x`)

```
// D provides: freq[], cum[], alias lookup; M, TOTAL=1<<M, mask = TOTAL-1.
fn rans_decode_sym(x as *u32, in_ptr as *u8, in_pos as *i64, D as *AliasTable) as i64 {
    let is i64 as xs   = cast(i64, *x);
    let is i64 as slot = xs & (D.TOTAL - 1);          // r = x mod TOTAL  (low M bits)
    let is i64 as sym  = alias_lookup(D, slot);       // O(1) slot -> symbol (§3.6.2)
    let is i64 as f    = cast(i64, D.freq[sym]);
    let is i64 as c    = cast(i64, D.cum[sym]);
    // advance state:  x = f * (x >> M) + (x mod TOTAL) - cum[sym]
    xs = f * (xs >> D.M) + slot - c;
    // renormalize: while x < L, pull one byte (LSB into low end)
    while (xs < RANS_L) {
        xs = (xs << 8) | cast(i64, in_ptr[*in_pos]);
        *in_pos = *in_pos + 1;
    }
    *x = cast(u32, xs);
    return sym;
}
```

#### 3.5.2. Encode of one symbol (one lane `x`, writing backward)

The encoder writes into a buffer **from high address to low** (`out_pos` starts at the end and decreases). The symbol order is reversed relative to decode (LIFO): the encoder processes symbols in **reverse** of the decode order so the decoder reads them forward.

```
// out_ptr is the output buffer; out_pos decreases as bytes are written.
fn rans_encode_sym(x as *u32, out_ptr as *u8, out_pos as *i64,
                   D as *AliasTable, sym as i64) as i32 {
    let is i64 as f = cast(i64, D.freq[sym]);
    let is i64 as c = cast(i64, D.cum[sym]);
    // x_max = ((L >> M) << 8) * f   — the largest x that can still encode sym
    //         without the next-symbol state leaving [L, L*b).
    let is i64 as x_max = ((RANS_L >> D.M) << 8) * f;
    let is i64 as xs = cast(i64, *x);
    // renormalize down: while x >= x_max, emit the low byte
    while (xs >= x_max) {
        *out_pos = *out_pos - 1;
        out_ptr[*out_pos] = cast(u8, xs & 0xFF);
        xs = xs >> 8;
    }
    // x = ((x / f) << M) + (x mod f) + cum[sym]
    xs = ((xs / f) << D.M) + (xs - (xs / f) * f) + c;
    *x = cast(u32, xs);
    return 0;
}
```

#### 3.5.3. Initialization and flush

- **Encode init:** each lane `x[k] = RANS_L`.
- **Encode flush (`ec_flush`):** after all symbols, write each lane's final `u32` state to the (backward-growing) stream. The canonical order is lane `K-1` first down to lane `0` last, each as 4 little-endian bytes, written backward (so the decoder, reading forward, recovers lane `0`'s state first). The byte position where the stream begins (`out_pos` after flush) is the stream's start; `EOFF` records `off` = that position and `len` = bytes written.
- **Decode init:** read each lane's initial `u32` state from the forward stream, lane `0` first up to lane `K-1`, each 4 little-endian bytes; advance `in_pos` by `4·K`.

> **Lane initialization order is the inverse of flush order** — this is the single most error-prone point of interleaved rANS, so it is pinned and ships as conformance vector `ec/lanes_init`.

### 3.6. Normative table build (deterministic, integer-only)

Given raw integer counts `cnt[0..n)` (from the encoder's histogram) and precision `M` (`TOTAL = 1<<M`), the normalized `freq[]` is built by the **largest-remainder method with a guaranteed-nonzero floor**:

```
1. let used = number of symbols with cnt[s] > 0; total_cnt = Σ cnt[s].
2. // First pass: floor each used symbol to at least 1; scale the rest.
   for s in 0..n:
       if cnt[s] == 0: freq[s] = 0; continue            // unused stays 0
       // proportional target in [1, TOTAL]
       prod = cnt[s] * TOTAL
       freq[s] = max(1, prod / total_cnt)               // integer division; floor; min 1
   // record fractional remainders rem[s] = prod - freq[s]*total_cnt for the second pass
3. let sum = Σ freq[s].
4. // Fix the sum to exactly TOTAL by largest-remainder adjustment:
   if sum < TOTAL:   add 1 to the (TOTAL - sum) symbols with the largest rem[s]
                     (ties broken by smaller symbol index — declared, deterministic).
   if sum > TOTAL:   subtract 1 from the (sum - TOTAL) symbols with the smallest rem[s]
                     among those with freq[s] > 1 (never drive a used symbol to 0;
                     ties broken by larger symbol index — declared, deterministic).
5. assert Σ freq[s] == TOTAL and (cnt[s] > 0 => freq[s] >= 1) for all s.
6. cum[0] = 0; cum[s] = cum[s-1] + freq[s-1].
```

This is the **only** normalization algorithm; encoder and decoder both run it (the decoder runs it only for `table_src = 1` predefined tables, where it rebuilds from frozen counts). It is fully specified down to tie-breaking so two encoders produce identical `freq[]`.

#### 3.6.1. Alias table construction (Vose worklist)

`bucket_div = TOTAL / n`. Each of the `n` buckets has width `bucket_div`. Classify symbols into **small** (`freq[s] < bucket_div`) and **large** (`freq[s] ≥ bucket_div`) worklists. Then the standard Vose loop pairs a small with a large, filling each bucket with a primary symbol up to `alias_div` and the alias symbol beyond it; `alias_off[b]` records the cum-offset so the decoder can recover the in-symbol position. The loop, worklist push/pop order (LIFO, indices ascending on initial fill), and the leftover-handling are written out step-by-step in the spec body and frozen as conformance vector `ec/alias_build`. (Worklists are bounded: `n ≤ TOTAL ≤ 65536`, pre-sized from declared `n`.)

#### 3.6.2. Alias lookup (`slot → (sym, in-symbol offset)`)

```
fn alias_lookup(D as *AliasTable, slot as i64) as i64 {
    let is i64 as b   = slot / D.bucket_div;          // which bucket
    let is i64 as off = slot - b * D.bucket_div;      // position within bucket
    if (off < cast(i64, D.alias_div[b])) { return b; }            // primary symbol = bucket index
    return cast(i64, D.alias_sym[b]);                              // alias symbol
}
```

Because `slot = x mod TOTAL` already equals `cum[sym] + (in-symbol offset)`, §3.5.1 uses `slot` directly in `x = f·(x>>M) + slot − cum[sym]`; the alias table only resolves *which* symbol owns the slot. (Implementations may fold `alias_off` to recover the in-symbol offset directly; the spec presents both and the conformance vectors pin the resulting state, so either folding is byte-exact.)

#### 3.6.3. Context model: declared `ctx_id → distribution` mapping

Contexts are how a codec picks *which* distribution to use per symbol, and are the single biggest post-transform compression lever. The split is strict:

- **The context FUNCTION is policy** — it lives in the codec. Each codec section writes out the *exact, causal* property formula (e.g. for MODULAR: a quantized neighbor prediction-error bucket plus channel id; for DCT: nonzero-neighbor count plus coefficient-position band). The formula uses **only already-decoded** state (no future pixels), so it is invertible. Any decision tree (MA/MANIAC tree, §MODULAR) is **serialized as explicit nodes** `{property_id, threshold, left, right | leaf_ctx}` and evaluated as a declared interpreter — never a learned/opaque step at decode.
- **The MECHANISM is the substrate** — given a raw `ctx_id` computed by the codec, the substrate maps it to one of the `context_count` stored distributions via the **context map**.

The context-map block (present iff `ECTX.flags` bit1) is a clustering table that collapses a possibly-large raw context space onto the `Kctx` distributions actually stored (bounding table cost):

| Off | Size | Field | Meaning |
|---|---|---|---|
| +0x00 | 4 | `raw_ctx_count` (u32) | size of the raw context domain |
| +0x04 | 4 | `cluster_count` (u32) | = `context_count` (`Kctx`); the codomain |
| +0x08 | `raw_ctx_count` | `map[]` (u8[] or u16[]) | `map[raw_ctx] = cluster_id`; entry width is u8 if `cluster_count ≤ 256`, else u16 (declared by `cluster_count`) |

Decode of one symbol: the codec computes `raw_ctx` from causal neighbors → `cluster_id = map[raw_ctx]` → `D = distribution[cluster_id]` → `rans_decode_sym(x, …, D)`. If `has_ctxmap = 0`, then `raw_ctx` is used directly as `cluster_id` and must be `< context_count` (else `E_CSIF_EC_CTX`). Causal-only neighbor access bounds decode memory to a few scanlines — declared, not discovered.

### 3.7. Hybrid integer token scheme (token = bucket + extra bits)

To carry full 16/32-bit residuals/coefficients through a **tiny** ANS alphabet (so histograms stay small and table build is cheap — essential for HDR/16-bit/modular), each value is split into an entropy-coded **token** (a magnitude bucket plus a few fixed high/low bits) and **raw extra bits** written verbatim to a separate, explicitly-positioned bit substream. The split is the exact JXL hybrid-uint formula, written out and parameterized by a declared `HybridConfig`:

```
struct HybridConfig {
    split_exponent as i64    // values < (1 << split_exponent) are encoded directly as the token
    msb_in_token   as i64    // # high bits of the magnitude carried inside the token
    lsb_in_token   as i64    // # low bits of the magnitude carried inside the token
}
```

**Forward split** (value `v ≥ 0`; signed values are zig-zag folded first, §3.7.2):

```
fn token_of(v as i64, h as *HybridConfig, out_nbits as *i64, out_raw as *i64) as i64 {
    let is i64 as split = cast(i64, 1) << h.split_exponent;
    if (v < split) {
        *out_nbits = 0; *out_raw = 0;
        return v;                                   // small values ARE the token, no extra bits
    }
    // n = position of the highest set bit of v  (v >= split, so n >= split_exponent)
    let is i64 as n with mut = h.split_exponent;
    while ((cast(i64, 1) << (n + 1)) <= v) { n = n + 1; }
    // number of raw "middle" bits
    let is i64 as nbits = n - (h.msb_in_token + h.lsb_in_token);
    // high bits kept in the token
    let is i64 as high  = (v >> (n - h.msb_in_token)) & ((cast(i64,1) << h.msb_in_token) - 1);
    // low bits kept in the token
    let is i64 as low   = v & ((cast(i64,1) << h.lsb_in_token) - 1);
    // the raw middle bits go to the side channel, LSB-first
    *out_raw   = (v >> h.lsb_in_token) & ((cast(i64,1) << nbits) - 1);
    *out_nbits = nbits;
    // token = split + ((n - split_exponent) << (msb+lsb)) + (high << lsb) + low
    let is i64 as bucket = n - h.split_exponent;
    return split + (bucket << (h.msb_in_token + h.lsb_in_token))
                 + (high << h.lsb_in_token) + low;
}
```

**Inverse** (reconstruct `v` from token + raw extra bits) is the exact algebraic inverse and is written out as `value_of(token, raw, h)` in the spec body; it is a pure table-free function, frozen as conformance vector `ec/hybrid_roundtrip` over the full 32-bit range with several `HybridConfig`s.

#### 3.7.1. Extra-bits substream placement

The raw extra bits do **not** go through rANS. They are appended to a separate bit substream, **LSB-first**, whose byte range is recorded by its own `EOFF` entry (a stream id paired with the token stream). The token stream and its extra-bits stream are siblings: the decoder, for each token that carries `nbits > 0`, reads exactly `nbits` bits (LSB-first) from the extra-bits stream. Because the rANS token stream is read forward while it was built backward, and the extra-bits substream is a plain forward LSB-first bit reader, **the two are decoded in lockstep but live in distinct, explicitly-offset byte ranges** — the layout is fully self-describing; nothing is interleaved implicitly.

#### 3.7.2. Signed mapping and zero-run handling (shared toolkit helpers)

Residual statistics are signed and peaked at zero with long runs. The shared toolkit provides the canonical mappings; the **mode is declared per context** (an `ECParams`/codec enum), never detected at decode:

- `fn zigzag(i as i32) as u32` = `(i << 1) ^ (i >> 31)` — folds sign so small magnitudes of either sign get small tokens.
- `fn unzigzag(u as u32) as i32` = `(u >> 1) ^ (0 - (u & 1))`.
- Zero-run / EOB: a per-context residual mode `{0=plain, 1=zigzag, 2=zigzag+RLE, 3=EOB}`. In `RLE` a reserved run-length token codes a count of consecutive zeros; in `EOB` (transform blocks) a single token means "all remaining coefficients in this block are zero". The run accumulator is bounded scratch. Both MODULAR and DCT reuse these helpers (DRY); the helper choice is data the encoder wrote, so decode is policy-free.

### 3.8. Interleaving and multi-stream layout

#### 3.8.1. Lane interleave (`interleave_layout`)

With `K = lane_count > 1`, `K` independent lane states share one byte stream so `K` symbols decode per inner iteration with no inter-lane data dependency (SIMD/superscalar, multi-GB/s). Two declared layouts:

- `0` **round-robin:** symbol `i` (in decode order) is handled by lane `i mod K`. The encoder, processing in reverse, assigns symbol `i` to the same lane `i mod K`.
- `1` **block-interleave:** symbols are grouped into runs of declared block length; lane assignment is per block. (Block length is the next `ECParams` byte when `interleave_layout = 1`.)

The mapping from symbol index to lane is **fully determined** by `interleave_layout` + `K`; there are no implicit tie-breaks. Decode init reads `K` lane states (lane 0 first, §3.5.3); thereafter the chosen lane's `rans_decode_sym` is called per symbol.

#### 3.8.2. `EOFF` — entropy offsets table (per-stream byte ranges)

The image's entropy data is split into independently-decodable **streams** (typically one per tile × channel-group, plus the paired extra-bits substream), so parallel decode, partial/region decode, and error containment all work. The `EOFF` chunk is an explicit directory, exactly mirroring CSE's segment table discipline (fixed-stride records, declared u64 offsets/lengths, validated against the containing chunk before use):

| Off | Size | Field | Meaning |
|---|---|---|---|
| +0x00 | 4 | `stream_id` (u32) | identifies the stream (tile, channel group, token-vs-extra) |
| +0x04 | 1 | `stream_role` (u8) | `0`=rANS/CDF/prefix tokens; `1`=hybrid extra-bits; `2`=raw passthrough |
| +0x05 | 1 | `ectx_index` (u8) | which `ECTX` record governs this stream |
| +0x06 | 2 | `reserved` (u16) | must be `0` |
| +0x08 | 8 | `off` (u64) | byte offset of the stream **within its IDAT chunk** |
| +0x10 | 8 | `len` (u64) | byte length of the stream |
| +0x18 | 4 | `crc` (u32) | optional per-stream CRC-32C; `0` and absent unless `ECTX.flags` bit3 (§3.12) |

Every offset/length is **declared, not scanned** (the trap PNG/JPEG marker-hunting falls into). Before decoding, the loader validates `off + len ≤ IDAT_chunk_length` (the CSE `file_off + file_size > cst_size` guard, generalized) and rejects dangling/overlapping ranges loudly. A decoder reads only the streams for the tiles it wants — bounded memory, true partial/ROI decode at the entropy layer.

Each rANS/CDF/prefix stream **resets** its coder state at its start (lane states re-initialized from the stream's own bytes; for adaptive CDF, see `reset_per_tile` §3.9). There is **no cross-stream context carryover** — stream independence is a declared invariant, which is what makes partial decode and error containment honest.

### 3.9. Adaptive multi-symbol CDF mode (`entropy_method_id = 1`)

A table-free method: each context holds a CDF that starts from a **declared default** and self-tunes after every symbol by a fixed shift rule — so no histograms are transmitted (wins on small tiles/images and streaming where table overhead dominates, AVIF-class).

```
// Per context: cdf[0..n] (u16), cdf[0]=0, cdf[n]=TOTAL, monotone nondecreasing.
fn cdf_decode_sym(x as *u32, in_ptr as *u8, in_pos as *i64,
                  cdf as *u16, n as i64, M as i64, count as *i64) as i64 {
    // map current state's low M bits to a symbol via binary search over cdf
    let is i64 as r = cast(i64, *x) & ((cast(i64,1) << M) - 1);   // r in [0, TOTAL)
    let is i64 as sym = cdf_search(cdf, n, r);                    // largest s with cdf[s] <= r
    let is i64 as f = cast(i64, cdf[sym+1]) - cast(i64, cdf[sym]);
    let is i64 as c = cast(i64, cdf[sym]);
    // identical rANS state advance + renorm as §3.5.1 (the back-end is the same engine)
    let is i64 as xs = f * (cast(i64,*x) >> M) + r - c;
    while (xs < RANS_L) { xs = (xs << 8) | cast(i64, in_ptr[*in_pos]); *in_pos = *in_pos + 1; }
    *x = cast(u32, xs);
    cdf_adapt(cdf, n, sym, M, count);     // normative update — SAME on encode and decode
    return sym;
}
```

**Normative update rule** (`cdf_adapt`) — pinned, integer-only, no floating point:

```
fn cdf_adapt(cdf as *u16, n as i64, sym as i64, M as i64, count as *i64) as i64 {
    // rate adapts with a per-context count: faster early, slower as it stabilizes.
    let is i64 as rate = 3 + (cast_min(*count, 15) >> 2);   // declared schedule, frozen
    let is i64 as TOTAL = cast(i64,1) << M;
    let is i64 as i with mut = 1;
    while (i < n) {
        let is i64 as target = 0;
        if (i > sym) { target = TOTAL; }                   // symbols above move toward TOTAL
        // cdf[i] += (target - cdf[i]) >> rate    (signed shift; arithmetic)
        let is i64 as cur = cast(i64, cdf[i]);
        cdf[i] = cast(u16, cur + ((target - cur) >> rate));
        i = i + 1;
    }
    *count = *count + 1;
    return 0;
}
```

(The exact `rate` schedule, the `cdf_search` tie-break, and a guard that keeps `cdf` strictly monotone after each update with `f ≥ 1` are written out in full and frozen as conformance vector `ec/cdf_adapt`. The *same* update runs on encode and decode, keeping them in lockstep — the defining property that makes this method bit-exact without transmitted tables.)

- **Default CDFs** are spec-frozen constants, referenced by `table_ref` id in the per-context table block (no implicit bootstrapping — a reader knows every starting CDF from a declared id).
- `reset_per_tile` (`ECTX.flags` bit0): when set, each stream re-initializes its CDFs to the defaults at its start, bounding error propagation and enabling partial decode. When clear, CDFs persist across streams in a declared order (front-loaded for ratio); the order is declared, never implicit.
- CDF state is a fixed `[Kctx][n+1]u16` array allocated once from the caller's scratch — bounded, no per-symbol allocation.

### 3.10. Prefix-code mode (`entropy_method_id = 2`)

A canonical, length-limited Huffman back end for the speed/seekability tier (some hardware decodes prefix codes faster; trivially seekable per symbol). It reuses the **identical** hybrid-token front end (§3.7) — only the token's symbol coder changes (DRY).

- **Transmitted data:** only per-symbol **code lengths** (the canonical assignment derives the codes). Max code length is a declared `ECParams` field (`≤ 16`) capping table memory.
- **Canonical assignment:** symbols sorted by `(length ascending, symbol-index ascending)`; codes assigned by the standard canonical algorithm (first code of each length = `(prev_first + count_prev) << 1`), written out step-by-step in the spec. A reader rebuilds the table deterministically.
- **Bit order:** **MSB-first** (the one place CSIF uses MSB-first, declared in §3.0).
- The code-length table block format parallels §3.3.1 (`table_src` inline / predefined-id / back-reference). Extra bits (§3.7) remain a separate LSB-first substream — the front end is unchanged.

#### 3.10.1. Raw passthrough (`entropy_method_id = 3`)

Symbols (or bytes) are stored verbatim, length given by the `EOFF` `len`. Used by the RAW codec and as the honest escape for incompressible data. No coder state, no tables; `ec_decode_symbol` returns the next stored unit. This is the only "no compression" path and it is explicit — there is no implicit fallback that silently changes bytes.

### 3.11. Conformance vectors (frozen at self-host)

A normative corpus ships in-repo and is checked by the `verify.sh`-style harness:

| Vector | Pins |
|---|---|
| `ec/normalize` | §3.6 largest-remainder build (counts → `freq[]`), incl. tie-breaks and nonzero floor |
| `ec/alias_build` | §3.6.1 Vose worklist (`freq[]` → `AliasTable`), exact bucket contents |
| `ec/rans_roundtrip` | §3.5 single-lane encode↔decode, several `M` |
| `ec/lanes_init` | §3.5.3 flush/init order for `K = 1,2,4,8,16,32`, both `interleave_layout`s |
| `ec/hybrid_roundtrip` | §3.7 `token_of`/`value_of` over the full 32-bit range, several `HybridConfig`s |
| `ec/ctxmap` | §3.6.3 raw→cluster mapping + per-context distribution selection |
| `ec/cdf_adapt` | §3.9 adaptive update (rate schedule, monotonicity guard) |
| `ec/prefix_canonical` | §3.10 canonical length→code assignment, MSB-first I/O |
| `ec/eoff` | §3.8.2 multi-stream byte-range layout + per-stream independence |

Each vector is `(ECParams, context sequence, symbol sequence) → exact output bytes` and the reverse. They are frozen exactly like the syscall ABI; a change is a version bump, never a silent edit.

### 3.12. Error model (loud, register-level, numbered)

The substrate fails closed with numbered negative codes, in the CSE `0 - N` style, reporting the offending field/stream — never a silent clamp or guess (matches the kernel's fail-loud, bounded stance):

| Code | Constant | Condition |
|---|---|---|
| `0 - 1` | `E_CSIF_EC_METHOD` | unknown/unsupported `entropy_method_id` |
| `0 - 2` | `E_CSIF_EC_PRECISION` | `precision_M` outside `[4, 16]` |
| `0 - 3` | `E_CSIF_EC_LANES` | `lane_count` outside `[1, 32]` |
| `0 - 4` | `E_CSIF_EC_TABLESUM` | `Σ freq[s] != TOTAL` |
| `0 - 5` | `E_CSIF_EC_TABLEREF` | `table_ref`/index points to a non-prior or absent table |
| `0 - 6` | `E_CSIF_EC_ALPHADIV` | padded `n` does not divide `TOTAL` |
| `0 - 7` | `E_CSIF_EC_CTX` | computed `cluster_id ≥ context_count` |
| `0 - 8` | `E_CSIF_EC_RANGE` | `EOFF` `off + len` exceeds the containing IDAT chunk |
| `0 - 9` | `E_CSIF_EC_OVERLAP` | two stream byte ranges overlap |
| `0 - 10` | `E_CSIF_EC_TRUNC` | decoder ran past the declared stream `len` (truncated/corrupt) |
| `0 - 11` | `E_CSIF_EC_CRC` | per-stream CRC-32C mismatch (when `crc_present`) |
| `0 - 12` | `E_CSIF_EC_CDFMONO` | a decoded/adapted CDF is non-monotone or has a zero-frequency used symbol |
| `0 - 13` | `E_CSIF_EC_HYBRID` | `HybridConfig` inconsistent (`msb+lsb > split_exponent`-implied width) or token out of range |

The per-stream CRC (CRC-32C/Castagnoli, declared by `ECTX.flags` bit3) is verified before/after decoding a stream; on mismatch the decoder marks **that tile** undecodable and reports the exact `(stream_id, off)` — corruption is localized (the multi-stream layout already isolates damage; the CRC turns silent corruption into a loud, bounded, per-tile error). There is no hidden retry and no heuristic recovery.

---

**Summary of the §3 contract.** One entropy substrate, dispatched by an explicit `entropy_method_id`, with: a 32-bit interleaved static-rANS default (`L=1<<16`, byte renorm, `M∈[4,16]`, alias-method tables built by a frozen largest-remainder + Vose algorithm); a hybrid integer-token front end (`split_exponent/msb_in_token/lsb_in_token`) that carries full 32-bit values through a tiny alphabet with LSB-first raw extra bits in a sibling substream; explicit, causal context modeling via a serialized `ctx_id → cluster_id → distribution` map; an adaptive-CDF and a canonical-prefix method in the same vtable slot; per-tile/per-channel streams with a declared `EOFF` byte-range directory for parallel/partial/error-contained decode; and a frozen conformance corpus plus numbered loud errors. Every probability, bound, table-build step, lane order, and byte direction is pinned — the encoder is exactly the reverse of the decoder, bit-for-bit.

Spec section authored in `/home/caua/Documentos/Projetos-Pessoais/causticos/docs/CSE_FORMAT.md` family style (header-table conventions, `let is i64 as` constants, `0 - N` numbered errors, little-endian, fail-loud, fixed-stride validated tables). No files were written — the section content above is the deliverable.

---

I have the conventions I need. The CSE_FORMAT.md style uses: explicit byte-offset tables, little-endian, numbered loader algorithms, "fail loud" rejection rules, frozen constants. Now I'll write section 4 of the CSIF spec — the shared toolkit (color/transform/predict + quantization). This is the DRY substrate every codec calls.

I'll write the actual specification text now.

## 4. Toolkit compartilhado (color/transform/predict)

> **Status:** especificação normativa. Os módulos abaixo (`color`, `transform`, `predict`, `quant`) são a **biblioteca DRY** que TODOS os codecs do registro chamam. O contêiner CSIF nunca chama nenhum deles — ele despacha por `codec_id` e entrega ao codec os bytes do tile + um ponteiro para o toolkit. Os codecs (MODULAR, DCT, BLOCK, ...) são **política**; este toolkit é **mecanismo reutilizável**. Nada aqui aloca: toda função recebe buffers do chamador e um *scratch* limitado e declarado. Tudo é inteiro/ponto-fixo no caminho de decode — **zero ponto-flutuante no laço de decodificação** — para que a saída seja bit-exata em qualquer CPU (a Seção de conformidade congela os vetores de teste).

### 4.0. Convenções compartilhadas por todos os módulos

| Convenção | Valor declarado |
|---|---|
| Endianness de todo campo multibyte | little-endian (igual ao CSE; declarado em IHDR, nunca assumido) |
| Tipo escalar de campos de struct | **`i64`** (gotcha Caustic de larguras mistas: campos `u8/u16/u32` adjacentes podem aliasar; structs do toolkit usam `i64` por campo) |
| Profundidade de amostra suportada | `UINT8, UINT10, UINT12, UINT16, FLOAT16 (IEEE binary16), FLOAT32 (IEEE binary32)` — declarada por canal em `CHNL`, não global |
| Precisão intermediária | **declarada por função** (ver cada tabela); nunca "o que couber no registrador" |
| Aritmética modular dos preditores | módulo `2^bit_depth` do canal (reversível exata) |
| Racionais (matrizes, ganhos, escalas) | pares `i64` `{num, den}` — exatidão sem ponto-flutuante |
| Falha | **alta e explícita** (código de erro numerado), nunca clamp silencioso |

Funções do toolkit nunca leem fora do tile que receberam (memória limitada ao tile; decode parcial/paralelo preservado). Vizinhos fora do tile/da imagem são tratados pela regra de borda **declarada** de cada módulo (Seções 4.2.4 e 4.3.6) — nunca por uma suposição implícita.

Códigos de erro deste toolkit (espelham o estilo de `cse.cst`):

| Código | Nome | Significado |
|---|---|---|
| `-4.01` | `E_TK_DEPTH` | `bit_depth`/`sample_format` não suportado pela função |
| `-4.02` | `E_TK_RANGE` | valor de coeficiente/índice fora do intervalo declarado |
| `-4.03` | `E_TK_PARAM` | parâmetro de transform/preditor fora do enum fechado |
| `-4.04` | `E_TK_DIM` | dimensão de bloco não pertence ao conjunto fechado de tamanhos |
| `-4.05` | `E_TK_SCRATCH` | buffer de scratch fornecido menor que o tamanho declarado |

---

### 4.1. Módulo `color` — transformações de cor reversíveis e não-reversíveis

O módulo `color` converte entre o **modelo de canais armazenado** (declarado em `CHNL`/IHDR) e os espaços internos que os codecs usam para descorrelacionar. **A escolha da transformação é DADO no fluxo** (campo declarado em ICOD/`TransformStack`), nunca auto-detectada no decode. O decode aplica **a inversa exata** declarada.

Há duas famílias, separadas pelo invariante de reversibilidade:

1. **RCT — Reversible Color Transforms** (inteiro, sem perda, exata). Para MODULAR e qualquer caminho lossless.
2. **ICT — Irreversible Color Transforms** (matricial, com arredondamento). Para o caminho lossy do DCT/BLOCK.

A seleção da matriz YCbCr↔RGB e a interpretação de gama/primárias **vêm sempre do CICP declarado em IHDR/ICLR** (`matrix_coefficients`). O `color` nunca escolhe uma matriz por heurística.

#### 4.1.1. Enum fechado de transformações de cor

`color_transform_id` (u8), congelado:

| id | Nome | Tipo | Reversível | Headroom de croma |
|---|---|---|---|---|
| 0 | `COLOR_NONE` | identidade | sim | 0 |
| 1 | `RCT_YCGCO_R` | RCT (lifting) | sim | +1 bit em Cg e Co |
| 2 | `RCT_SUBTRACT_GREEN` | RCT | sim | +1 bit em R−G, B−G |
| 3 | `RCT_FAMILY` | RCT paramétrica (perm + tipo) | sim | declarado por variante |
| 16 | `ICT_YCBCR` | ICT (matricial) | não | 0 (depende de subamostragem) |
| 17 | `ICT_YCGCO` | ICT (matricial, não-reversível) | não | 0 |

`color_transform_id ∉ {conjunto acima}` ⇒ `E_TK_PARAM`. IDs 4–15 reservados para futuras RCTs; 18–255 reservados para futuras ICTs (adicionados por versão, nunca por comportamento implícito).

#### 4.1.2. `RCT_YCGCO_R` — fórmula exata por lifting (id 1)

Entrada inteira `(R, G, B)` no `bit_depth` do canal. Saída `(Y, Cg, Co)` onde **Cg e Co exigem +1 bit de headroom** (declarado no descritor de canal de `CHNL`, nunca implícito).

**Forward (encode):**
```
Co = R - B
t  = B + (Co >> 1)          # >> = arithmetic shift right (declarado)
Cg = G - t
Y  = t + (Cg >> 1)
```

**Inverse (decode), exata:**
```
t  = Y - (Cg >> 1)
G  = Cg + t
B  = t - (Co >> 1)
R  = Co + B
```

- `>>` é deslocamento aritmético à direita (preserva sinal), **declarado** — não é divisão truncada.
- `Co, Cg` são **assinados**; o headroom +1 bit é o que torna o round-trip exato.
- Precisão intermediária: `bit_depth + 2` bits, assinado, em `t`. (Para `UINT16` ⇒ `t` cabe em `i32`/`i64`.)
- Para `FLOAT16/FLOAT32`: `RCT_YCGCO_R` **não se aplica** ⇒ `E_TK_DEPTH` (RCTs são inteiras; floats usam `ICT_*` ou `COLOR_NONE`).

#### 4.1.3. `RCT_SUBTRACT_GREEN` (id 2)

Caso barato para conteúdo sintético/RGB:
```
Forward:  R' = R - G ;  B' = B - G ;  G' = G
Inverse:  R  = R' + G';  B  = B' + G';  G  = G'
```
`R'`, `B'` são assinados (+1 bit headroom declarado). Exata.

#### 4.1.4. `RCT_FAMILY` — RCT paramétrica (id 3)

Generaliza a família reversível (JXL-class). Parâmetros declarados na struct da transformação (no `TransformStack`):

| Campo (`i64`) | Faixa | Significado |
|---|---|---|
| `permutation` | 0..5 | permutação dos 3 canais antes do mix (qual vira "luma") |
| `type` | 0..6 | combinação de add/sub reversível aplicada |

Os 7 `type` formam o conjunto fechado de mixes reversíveis (cada um é uma sequência de lifts add/sub inteira, listada na tabela de constantes congelada do `color`). O decode lê `permutation` e `type` e aplica a inversa exata. `permutation>5` ou `type>6` ⇒ `E_TK_PARAM`. Headroom de croma de cada variante é declarado por canal em `CHNL`.

#### 4.1.5. `ICT_YCBCR` — RGB↔YCbCr matricial (id 16), com matriz selecionada por CICP

A matriz **é escolhida pelo `matrix_coefficients` declarado em CICP** (IHDR/ICLR), nunca por default. Coeficientes congelados, em ponto-fixo `Q16` (numerador sobre `2^16`):

**BT.601 (`matrix_coefficients = 6`):**
```
Kr = 0.299  Kb = 0.114   (constantes congeladas em Q16)
Y  =  Kr·R + (1-Kr-Kb)·G + Kb·B
Cb = (B - Y) / (2·(1-Kb))
Cr = (R - Y) / (2·(1-Kr))
```
**BT.709 (`= 1`):** `Kr = 0.2126, Kb = 0.0722`.
**BT.2020-NCL (`= 9`):** `Kr = 0.2627, Kb = 0.0593`.

Forma de implementação **normativa** (inteiro, sem float no decode):

```
# decode (YCbCr → RGB), full-range, Q16 fixed-point:
R = Y + ((Cr * CR_R) >> 16)
G = Y - ((Cb * CB_G) >> 16) - ((Cr * CR_G) >> 16)
B = Y + ((Cb * CB_B) >> 16)
# clamp final ao intervalo do bit_depth (full vs limited declarado por video_full_range)
```

- As constantes `CR_R, CB_G, CR_G, CB_B` são **tabelas congeladas** por `matrix_coefficients`, listadas na Seção de constantes; um decodificador NUNCA as deriva por float em runtime.
- `video_full_range` (CICP) determina o offset/escala de quantização (full `0..2^n-1` vs limited/studio). **Declarado**; o `color` não adivinha.
- Arredondamento: `+ (1 << 15)` antes do `>> 16` (round-half-up declarado), de modo a ser bit-exato.
- Precisão intermediária: produtos em `i64`; resultado clampado ao `bit_depth`.

`matrix_coefficients = 0` (Identity/RGB) é **incompatível** com `ICT_YCBCR` ⇒ o codec deve rejeitar (`E_TK_PARAM`); RGB-identity usa `COLOR_NONE`.

#### 4.1.6. Subamostragem de croma

Fatores `h_subsample`, `v_subsample` (1/2/4) e `chroma_sample_position` (co-sited / centered, por H.273) são **declarados** em IHDR. O `color` expõe `chroma_upsample(plane, h_sub, v_sub, position)` e `chroma_downsample(...)`; o filtro de reconstrução de cada `chroma_sample_position` é **especificado e congelado** (não é "qualquer resampler"). Nada é inferido do tamanho dos dados.

#### 4.1.7. Espaço perceptual XYB (para métricas e VarDCT lossy)

Para o domínio perceptual (usado por BLOCK lossy e pelas métricas SSIMULACRA2/butteraugli): `color` expõe `rgb_linear_to_xyb` / `xyb_to_rgb_linear`. A transformação RGB→linear usa a **transfer function declarada em CICP** (Seção 4.1.5 não-linear) — nunca uma gama assumida. A matriz LMS+gama do XYB é **congelada** na tabela de constantes. Como é caminho lossy/perceptual, é ICT (não-reversível) e roda em ponto-fixo declarado no decode quando reconstrói pixels.

---

### 4.2. Módulo `transform` — DCT 8×8, DCTs de tamanho variável, e DWT

O módulo `transform` é o conjunto **fechado** de transformadas espaço↔frequência/sub-banda. Cada transformada expõe exatamente `{forward, inverse}`. A tripla `(type_h, type_v, size)` (DCT/BLOCK) ou a `(filter, levels, axis)` (DWT) é **codificada explicitamente** no fluxo do codec — nunca inferida. As constantes de base e o arredondamento/escala em ponto-fixo são **congelados** nesta seção, de modo que os coeficientes decodifiquem identicamente em qualquer lugar.

#### 4.2.1. Enum fechado de transformadas

`transform_id` (u8), congelado:

| id | Nome | Eixo/forma | Reversível | Uso |
|---|---|---|---|---|
| 0 | `TX_IDENTITY` (IDTX) | bypass | sim (lossless) | conteúdo sintético/tela |
| 1 | `TX_DCT` | DCT-II/III separável | não (lossy) | DCT (id 3), BLOCK (id 4) |
| 2 | `TX_ADST` | seno assimétrico | não | resíduos intra unilaterais |
| 3 | `TX_FLIPADST` | ADST espelhado | não | caso espelhado |
| 4 | `TX_WHT` | Walsh-Hadamard 4×4 | sim (lossless) | caminho lossless de BLOCK (q=0) |
| 16 | `TX_DWT_53` | wavelet Le Gall 5/3 (lifting) | sim (lossless) | DWT escalável lossless |
| 17 | `TX_DWT_97` | wavelet CDF 9/7 (lifting) | não (lossy) | DWT escalável lossy |
| 32 | `TX_SQUEEZE` | Haar-lifting não-linear | sim (lossless) | MODULAR responsivo |

`transform_id ∉ {acima}` ⇒ `E_TK_PARAM`.

#### 4.2.2. Conjunto fechado de tamanhos de bloco (DCT/ADST)

`tx_size` (u8), congelado (espelha o conjunto VarDCT/AV1, sem escape):

| id | Forma | id | Forma |
|---|---|---|---|
| 0 | 4×4 | 8 | 16×32 |
| 1 | 8×8 | 9 | 32×16 |
| 2 | 16×16 | 10 | 32×64 |
| 3 | 32×32 | 11 | 64×32 |
| 4 | 64×64 | 12 | 8×32 |
| 5 | 8×16 | 13 | 32×8 |
| 6 | 16×8 | 14 | 4×8 |
| 7 | 16×32 reservado→ ver nota | 15 | 8×4 |

(IDs ≥16 reservados, até 256×256, adicionados por versão.) O **DCT codec (id 3)** usa **apenas** o subconjunto `tx_size = 1` (8×8) — é o subconjunto JPEG-class do mesmo toolkit (DRY). O **BLOCK codec (id 4)** usa o conjunto completo. `tx_size` fora do conjunto fechado ⇒ `E_TK_DIM`. O **mapa de partição** (qual `tx_size` por célula da grade 8×8) é um campo decodificado explícito por tile (um dos sub-images declarados), nunca inferido.

#### 4.2.3. DCT 8×8 — definição inteira exata (id 1, `tx_size=1`)

Transformada separável: 1-D ao longo das colunas, depois ao longo das linhas (ordem **declarada**: colunas primeiro no forward; linhas primeiro no inverse). Base DCT-II ortonormal.

**Constantes congeladas** (ponto-fixo, escala `S = 2^14`, valores `round(cos(k·π/16) · S)`):

| Símbolo | cos | valor `Q14` |
|---|---|---|
| `c1` | cos(π/16) | 16069 |
| `c2` | cos(2π/16) | 15137 |
| `c3` | cos(3π/16) | 13623 |
| `c4` | cos(4π/16) | 11585 |
| `c5` | cos(5π/16) | 9102 |
| `c6` | cos(6π/16) | 6270 |
| `c7` | cos(7π/16) | 3196 |

**IDCT 1-D normativo (8 pontos)** — borboleta tipo Loeffler, ponto-fixo, com arredondamento declarado. Entrada: 8 coeficientes `F[0..7]` (i64). Saída: 8 amostras `f[0..7]`.

```
# constantes acima em Q14; DESCALE(x, n) = (x + (1<<(n-1))) >> n   (round-half-up declarado)
# Estágio par:
t0 = (F0 + F4) * c4
t1 = (F0 - F4) * c4
t2 =  F2 * c6 + F6 * c2          # nota: c6,c2 = sin/cos do par
t3 =  F2 * c2 - F6 * c6
e0 = t0 + t3 ;  e3 = t0 - t3
e1 = t1 + t2 ;  e2 = t1 - t2
# Estágio ímpar:
o0 = F1*c1 + F3*c3 + F5*c5 + F7*c7
o1 = F1*c3 - F3*c7 - F5*c1 - F7*c5
o2 = F1*c5 - F3*c1 + F5*c7 + F7*c3
o3 = F1*c7 - F3*c5 + F5*c3 - F7*c1
# Combinação + desescala final:
f0 = DESCALE(e0 + o0, 15) ;  f7 = DESCALE(e0 - o0, 15)
f1 = DESCALE(e1 + o1, 15) ;  f6 = DESCALE(e1 - o1, 15)
f2 = DESCALE(e2 + o2, 15) ;  f5 = DESCALE(e2 - o2, 15)
f3 = DESCALE(e3 + o3, 15) ;  f4 = DESCALE(e3 - o3, 15)
```

- Aplica-se 1-D às 8 colunas, depois 1-D às 8 linhas do resultado.
- Precisão intermediária **declarada**: produtos e somas em `i64`; nenhum estágio satura.
- `DESCALE(x,n) = (x + (1<<(n-1))) >> n` é a **única** regra de arredondamento (round-half-up para +∞), congelada — é o que garante o IDCT bit-exato em todo decodificador (mesmo papel do "IDCT de referência" do JPEG T.83 na conformidade).
- O **FDCT** (encode) é o transposto exato com a mesma escala; sua precisão é política do encoder (o decode é que é normativo).
- DC do bloco = `F[0]`; pode ser exportado como sub-image (thumbnail/preview) pelo codec.

DCTs de tamanho variável (16×16…64×64, retangulares) usam a mesma família de borboletas escalada ao tamanho, com as constantes `cos(k·π/2N)` na tabela congelada por tamanho; a regra `DESCALE` e a ordem (colunas→linhas) são idênticas.

#### 4.2.4. ADST/FLIPADST (ids 2, 3) e IDTX (id 0)

- `TX_ADST`: base seno DST-VII (assimétrica), melhor para resíduos intra onde o erro cresce afastando-se do preditor. Constantes congeladas por tamanho na tabela do módulo; mesma disciplina `DESCALE`/`i64`. Separável: um bloco pode ser e.g. ADST-vertical × DCT-horizontal — a tripla `(type_h, type_v, size)` é **codificada**, nunca inferida.
- `TX_FLIPADST`: idêntico a ADST sobre a entrada espelhada (declarado).
- `TX_IDENTITY` (IDTX): nenhuma transformada espacial — o resíduo passa direto ao quantizador/entropia. Reversível; vence em conteúdo de tela/sintético.

#### 4.2.5. WHT 4×4 (id 4) — caminho lossless inteiro

Walsh-Hadamard 4×4, perfeitamente invertível (sem `cos`, sem escala fracionária):
```
# 1-D WHT (4 pontos), inteiro exato:
a = x0 + x3 ;  b = x1 + x2 ;  c = x1 - x2 ;  d = x0 - x3
y0 = a + b ;  y1 = d + c ;  y2 = a - b ;  y3 = d - c
# inversa: simétrica com >>1 nos estágios apropriados (declarada na tabela)
```
Usada por BLOCK quando `is_lossless` e `q_idx = 0` (predição + WHT + entropia = matematicamente sem perda). Round-trip exato é **invariante** do módulo.

#### 4.2.6. DWT — Le Gall 5/3 (id 16) e CDF 9/7 (id 17), por lifting

Decomposição 2-D separável, `R` níveis declarados. Cada nível produz LL/LH/HL/HH; recursão em LL ⇒ pirâmide de `R+1` níveis de resolução (escalabilidade estrutural). **Lifting in-place**, `O(1)` scratch extra por linha (uma linha), satisfazendo memória limitada.

**5/3 reversível (lossless), lifting inteiro — normativo:**
```
# split em pares/ímpares; índices da extensão simétrica nas bordas (declarado)
# predict (detalhe):
d[n] = x[2n+1] - ((x[2n] + x[2n+2] + 1) >> 1)
# update (aproximação):
s[n] = x[2n]   + ((d[n-1] + d[n] + 2) >> 2)
# inversa: aplica update^-1 depois predict^-1, exata
```

**9/7 irreversível (lossy):** quatro passos de lifting com os coeficientes congelados `α=-1.586134, β=-0.052980, γ=0.882911, δ=0.443506` e escala `K=1.230174`, todos em ponto-fixo `Q16` na tabela congelada; mesma disciplina de extensão simétrica e `DESCALE`.

- `filter` (5/3 vs 9/7) é **campo explícito** no codec param — nunca "deduzido de `is_lossless`".
- Modo de borda: **extensão simétrica**, declarado (sem suposição).
- Precisão e número de níveis `R`: campos declarados.

#### 4.2.7. SQUEEZE (id 32) — sub-banda Haar-lifting reversível (MODULAR responsivo)

Divide um canal em sub-canal de média (low-pass) e de resíduo (high-pass) por um lift reversível com termo de *tendência*, de modo que `(a,b)` reconstrói exato:
```
avg = (a + b) >> 1            # paridade recuperável via resíduo
res = a - b                   # + correção de tendência (declarada)
# inversa reconstrói a,b exatamente a partir de (avg, res)
```
Aplicado recursivamente (horizontal/vertical) constrói a pirâmide Laplaciana ⇒ qualquer prefixo decodifica uma imagem de menor resolução válida (responsivo por construção). O **schedule** (`{axis, channel_range, num_levels}` por passo) é **escrito** no `TransformStack`; o decode nunca adivinha a forma da pirâmide.

---

### 4.3. Módulo `predict` — preditores espaciais

Preditores convertem amostras em **resíduos** pequenos antes da entropia. O `predict_id` escolhido (e sua granularidade: por-linha, por-tile, por-canal) é **armazenado explicitamente** — o decode é mecanismo puro e determinístico; a heurística de seleção do encoder é política invisível ao bitstream. Toda aritmética é modular no `bit_depth` do canal (reversível exata) e **causal** (só usa amostras já decodificadas), de modo a inverter sem informação lateral.

Notação de vizinhos causais (amostra atual `X`):
```
        C  B  D
        A  X
```
`A` = esquerda, `B` = acima, `C` = acima-esquerda, `D` = acima-direita. Resíduo armazenado `r = (X − pred) mod 2^bit_depth`; decode reconstrói `X = (pred + r) mod 2^bit_depth`.

#### 4.3.1. Enum fechado de preditores

`predict_id` (u8), congelado:

| id | Nome | Predição |
|---|---|---|
| 0 | `PRED_NONE` | `0` (resíduo = amostra crua) |
| 1 | `PRED_SUB` | `A` (esquerda) |
| 2 | `PRED_UP` | `B` (acima) |
| 3 | `PRED_AVG` | `floor((A + B) / 2)` |
| 4 | `PRED_PAETH` | preditor de Paeth (abaixo) |
| 5 | `PRED_GRADIENT` | `clamp(A + B − C)` (gradiente) |
| 6 | `PRED_WEIGHTED` | preditor auto-corretivo ponderado (Seção 4.3.4) |
| 16 | `PRED_DC` | média dos vizinhos reconstruídos (intra-bloco) |
| 17 | `PRED_DIRECTIONAL` | extrapolação em ângulo (intra-bloco) |
| 18 | `PRED_SMOOTH` | interpolação quadrática entre bordas |
| 19 | `PRED_CFL` | chroma-from-luma linear (α declarado) |

`predict_id ∉ {acima}` ⇒ `E_TK_PARAM`. IDs 0–6 são os preditores **por-amostra** do MODULAR/PNG-class; 16–19 são os preditores **intra-bloco** do caminho lossy (DCT/BLOCK), compartilhados pelo mesmo módulo (DRY).

#### 4.3.2. Filtros PNG-class (ids 1–4) — fórmulas exatas

```
SUB:      pred = A
UP:       pred = B
AVERAGE:  pred = (A + B) >> 1            # floor; >> = logical para unsigned, declarado
PAETH:    p = A + B - C
          pa = |p - A| ; pb = |p - B| ; pc = |p - C|
          if  pa <= pb and pa <= pc:  pred = A
          elif pb <= pc:              pred = B
          else:                       pred = C
```
- Para `SUB/AVERAGE/PAETH` em imagens multi-canal interleaved, o offset de vizinho é em **bytes-por-pixel** (declarado), como no PNG.
- Tudo módulo `2^bit_depth`. Reversível exata.
- Empates do Paeth resolvidos na ordem `A, B, C` (**declarado**, para bit-exatidão).

#### 4.3.3. `PRED_GRADIENT` (id 5)

```
g = A + B - C
pred = clamp(g, min(A,B,C-ε?), ...)   # forma normativa:
pred = clamp(g, lo, hi) onde lo=min(A,B), hi=max(A,B)
```
A forma normativa é o **clamp do gradiente** ao intervalo `[min(A,B), max(A,B)]` (gradiente "clamped", LOCO-I/JPEG-LS-class). Determinístico, módulo `2^bit_depth`.

#### 4.3.4. `PRED_WEIGHTED` — preditor auto-corretivo ponderado (id 6)

O maior ganho lossless sobre PNG. Combina um conjunto fixo de **sub-preditores** com pesos atualizados online a partir do erro local recente — **sem pesos transmitidos** (encode e decode rodam a atualização idêntica).

**Conjunto fixo de sub-preditores** (congelado):
```
P0 = A                         (W: esquerda)
P1 = B                         (N: acima)
P2 = A + B - C                 (gradiente)
P3 = B + D - C                 (gradiente NE)  → clamp ao intervalo do bit_depth
```

**Acumuladores de erro** por sub-preditor `i`: `err[i]` (i64), inicializados em `0`, mantidos numa janela local declarada.

**Predição (forward e inverse idênticos):**
```
# peso recíproco do erro (mais preciso recentemente ⇒ domina)
w[i] = (1 << WEIGHT_SHIFT) / (err[i] + EPS)        # EPS, WEIGHT_SHIFT declarados
num  = Σ w[i] · P[i]
den  = Σ w[i]
pred = (num + (den >> 1)) / den                    # round-half-up; tudo i64
pred = clamp(pred, 0, 2^bit_depth - 1)
```

**Atualização (após reconstruir o `X` verdadeiro):**
```
for each i:  err[i] = err[i] - (err[i] >> ERR_DECAY_SHIFT) + |P[i] - X|
```

| Hiperparâmetro (`i64`, declarado no codec param) | Papel |
|---|---|
| `WEIGHT_SHIFT` | precisão fixa do peso recíproco |
| `EPS` | evita divisão por zero / domina arranque |
| `ERR_DECAY_SHIFT` | decaimento exponencial da janela de erro |
| `subpred_set_id` | qual conjunto de sub-preditores (0 = o acima) |

- **Sem constantes mágicas no decodificador**: todos os hiperparâmetros são CAMPOS no codec param.
- Aritmética inteira/ponto-fixo (shifts declarados) ⇒ bit-exato em qualquer máquina.
- A divisão por `den` é a única divisão; é inteira com round-half-up declarado.

#### 4.3.5. MA-tree (MANIAC) — seleção de contexto/preditor por amostra

Para escolher **contexto de entropia** (e, opcionalmente, o preditor) por amostra, o codec serializa uma **árvore de decisão** (MA-tree) no bitstream. O decodificador é um **interpretador puro** de uma árvore declarada — sem comportamento aprendido/oculto no decode.

**Vocabulário fechado de propriedades** (`property_id`, u8, congelado) — calculáveis de estado causal:

| id | Propriedade |
|---|---|
| 0 | índice do canal |
| 1 | `|A − C|` (gradiente esquerda) |
| 2 | `|B − C|` (gradiente acima) |
| 3 | `|B − D|` |
| 4 | erro máximo atual do `PRED_WEIGHTED` |
| 5 | magnitude (bucket) do resíduo anterior |
| 6 | bucket da posição `x` |
| 7 | bucket da posição `y` |

(IDs ≥8 reservados, adicionados por versão.) `property_id` fora do conjunto ⇒ `E_TK_PARAM`.

**Serialização da árvore** (TLV explícito, por nó):
```
node = { node_kind:u8, property_id:u8, threshold:i64, left:u32, right:u32 }   # nó interno
     | { node_kind:u8, context_id:u32 }                                       # folha
```
Caminhar a árvore com as propriedades correntes ⇒ folha ⇒ `context_id` seleciona a distribuição de entropia. **Limites declarados** no codec param: `max_tree_depth`, `max_node_count`, `max_context_count` — o decodificador pré-dimensiona buffers (memória limitada, sem alocação oculta).

#### 4.3.6. Preditores intra-bloco (ids 16–19) — caminho lossy

Compartilhados pelo DCT/BLOCK (preenche o bloco a partir de vizinhos reconstruídos antes da transformada do resíduo):

- `PRED_DC` (16): `pred = média(linha-topo reconstruída ∪ coluna-esquerda reconstruída)`.
- `PRED_DIRECTIONAL` (17): extrapola ao longo de um ângulo `base + delta` (passos de 3°, conjunto fechado de ângulos declarado); filtro de borda intra de 2/4-tap **congelado**; o **modo/ângulo é símbolo codificado**, nunca inferido.
- `PRED_SMOOTH` (18): interpolação quadrática entre as bordas topo/esquerda (e seus refletidos), constantes congeladas.
- `PRED_CFL` (19): `chroma = DC_chroma + ((α · luma_AC_reconstruída) >> CFL_SHIFT)`, com `α` (assinado) **declarado** por bloco; `luma` é a luma reconstruída co-localizada e sub-amostrada (filtro declarado).

Borda da imagem/tile (quando vizinhos não existem): valor de preenchimento **declarado** por modo (e.g. `1 << (bit_depth-1)` para DC inicial) — nunca implícito.

---

### 4.4. Módulo `quant` — tabelas de quantização e o mapeamento do parâmetro de qualidade

`quant` é a ponte lossy entre coeficientes da `transform` e a entropia. Tudo é **declarado e explícito**: a tabela base, o multiplicador adaptativo por bloco, e o passo de quantização por `q_idx`. O decode lê dois objetos declarados (tabela + campo de multiplicadores) e desquantiza — **mecanismo puro**. *Como* o encoder escolheu os multiplicadores é política do encoder (módulo `perceptual`), invisível ao decode.

#### 4.4.1. Desquantização normativa

```
# coeff = coeficiente codificado; (u,v) = posição de frequência no bloco; plane = Y/Cb/Cr/...
qstep = qtable[plane][u][v] · qmul_field[block]        # ambos inteiros
recon = coeff · qstep                                   # i64
# inverse transform consome `recon`
```

- `qtable[plane][u][v]`: matriz de quantização por frequência (ponderação CSF), **carregada explicitamente** quando usada; nunca assumida.
- `qmul_field[block]`: multiplicador adaptativo por bloco, armazenado como **sub-image declarada** com `role = QUANT_FIELD` e seu próprio `codec_id` (MODULAR). O decode lê o campo e escala por bloco.
- Quando ausente uma tabela custom, usa-se a `qtable` derivada de `q_idx` pela tabela congelada de `q_idx → step` (Seção 4.4.3) — também declarada, sem "dequant mágico".
- `q_idx = 0` ⇒ passo unitário + caminho `TX_WHT`/`TX_IDENTITY` ⇒ **lossless** (invariante: `is_lossless` deve estar setado).

#### 4.4.2. Quantização base + deltas por plano + segmentação

| Campo (codec param, `i64`) | Papel |
|---|---|
| `base_q` | `q_idx` base da imagem/tile |
| `dc_delta_q[plane]` | delta de `q_idx` para o coeficiente DC, por plano |
| `ac_delta_q[plane]` | delta de `q_idx` para AC, por plano |
| `seg_count` (0..8) | número de segmentos com `delta_q` próprio |
| `seg_delta_q[seg]` | delta de `q_idx` por segmento |
| `qmul_field` (sub-image) | multiplicador espacial por bloco (adaptativo) |

`q_idx` efetivo de um bloco = `base_q + (dc|ac)_delta_q[plane] + seg_delta_q[seg(block)]`, depois mapeado a `qstep` pela tabela congelada, depois multiplicado por `qmul_field[block]`. **Todos os deltas são DADOS lidos**; o decodificador não tem modelo de taxa.

#### 4.4.3. Tabela congelada `q_idx → qstep`

`q_idx` (u8, `0..255`) mapeia a `qstep` por uma **tabela monotônica congelada** (uma para DC, uma para AC, por `bit_depth`), listada na Seção de constantes do `quant`. A relação é aproximadamente exponencial (passo dobra a cada ~N índices), mas o **decode usa a tabela literal**, nunca a fórmula — exatidão e bit-reprodutibilidade. `q_idx` fora de `0..255` ⇒ `E_TK_RANGE`.

#### 4.4.4. Mapeamento do parâmetro de qualidade (CQ) → quantização

O "quality knob" do CSIF **não** é um número opaco: é um par `(metric_id, target_value)` declarado em `IQMT` (ver seção de métricas). O `quant` expõe o **seam de encode** (política, fora do decode):

```
# ENCODE-side (política do encoder; NÃO faz parte do contrato de decode):
choose q_idx (e qmul_field) tal que metric(achieved) cruze target_value
record achieved_value em IQMT
```

- **Decode jamais vê `target`/`metric`**: vê apenas `q_idx`, deltas e `qmul_field` declarados. Isso mantém o split mecanismo/política limpo.
- `metric_id = NONE` ⇒ lossless (`is_lossless` setado, `q_idx = 0`).
- O `achieved_value` é gravado (proveniência honesta: "como os bits foram escolhidos"), mas é **descritivo** — não altera o decode.
- O seam `rdo_cost(distortion_metric_id, rate_estimate, lambda)` (RDO Lagrangiano) liga o registro de métricas (distorção) ao módulo de entropia (taxa) — **DRY**, política exclusiva do encoder; o decodificador nunca vê `lambda`.

---

### 4.5. Invariantes do toolkit (normativos, verificáveis por vetores congelados)

1. **Bit-exatidão do decode:** dados os mesmos coeficientes/resíduos e os mesmos campos declarados, todo decodificador conforme produz **bytes idênticos**. Garantido por: zero float no laço de decode; `DESCALE` único e congelado; tabelas de constantes (DCT/ADST/9-7/XYB/`q_idx→step`/matrizes CICP) congeladas e versionadas; ordem de operações declarada (colunas→linhas; lifting in-place; empates de Paeth em `A,B,C`).
2. **Reversibilidade exata** dos caminhos lossless: `RCT_*`, `TX_WHT`, `TX_DWT_53`, `TX_SQUEEZE`, e todos os `predict` ids 0–6 fazem round-trip exato módulo `2^bit_depth` (preservando, para floats lossless, o padrão de bits incluindo NaN/Inf/zero-sinalizado).
3. **Memória limitada, sem alocação oculta:** toda função opera sobre buffers do chamador + scratch declarado (uma linha para DWT/SQUEEZE; tabelas dimensionadas por `max_*` da MA-tree; alias-table dimensionada por `1<<precision` na entropia). Scratch insuficiente ⇒ `E_TK_SCRATCH`.
4. **DRY estrutural:** DCT codec (id 3) é o subconjunto 8×8 do mesmo `transform` que BLOCK (id 4) usa por inteiro; MODULAR (id 2) e os preditores intra-bloco do caminho lossy partilham o mesmo `predict`; o `color` é usado tanto pela RCT lossless quanto pelo YCbCr lossy; o `quant` é chamado por DCT e BLOCK via o mesmo `dequant`. Nenhum codec reimplementa nada deste toolkit.
5. **Nada implícito:** `color_transform_id`, `transform_id`, `tx_size`, `predict_id`, `property_id`, filtro DWT, modo de borda, matriz CICP, regra de arredondamento, `q_idx`, deltas e `qmul_field` são **todos campos declarados** no fluxo do codec. Um id fora do enum fechado correspondente falha **alto** (`E_TK_PARAM`/`E_TK_DIM`/`E_TK_RANGE`), nunca cai num default silencioso.

---

I've written section 4 of the CSIF specification. Here is a summary of what the section delivers (the full markdown content is in my response above, ready to be dropped into the spec document):

**Section "## 4. Toolkit compartilhado (color/transform/predict)"** — the DRY mechanism library every codec calls, written in the project's CSE_FORMAT.md house style (byte-exact tables, frozen constants, numbered normative algorithms, loud-fail error codes, PT-BR prose / English identifiers).

Structure:
- **4.0 Shared conventions** — little-endian declared, `i64` struct fields (Caustic mixed-width gotcha), rational `{num,den}` pairs, zero-float decode loop, declared error codes `E_TK_DEPTH/RANGE/PARAM/DIM/SCRATCH`.
- **4.1 `color`** — closed `color_transform_id` enum; exact `YCgCo-R` integer lifting (forward+inverse with declared +1-bit chroma headroom), `subtract-green`, RCT family (perm+type), `ICT_YCbCr` with the matrix **selected by CICP `matrix_coefficients`** (BT.601/709/2020 frozen `Q16` tables, round-half-up, full/limited range), chroma subsampling/siting, XYB for perceptual/lossy.
- **4.2 `transform`** — closed `transform_id` + closed `tx_size` set; the exact integer **DCT 8×8** (Loeffler butterfly, frozen `cos(kπ/16)` Q14 constants, single `DESCALE` rounding rule, columns→rows order); ADST/FLIPADST/IDTX; reversible WHT 4×4; DWT 5/3 (lossless) and 9/7 (lossy) by lifting; SQUEEZE.
- **4.3 `predict`** — closed `predict_id`; exact PNG filters (Paeth tie-break `A,B,C`), clamped gradient, the **self-correcting weighted predictor** (sub-predictor set + reciprocal-error weights + integer update rule, all hyperparams as declared fields), serialized **MA-tree** with a closed property vocabulary, and intra-block predictors (DC/directional/smooth/CfL).
- **4.4 `quant`** — normative dequant (`coeff·qstep`), `QUANT_FIELD` sub-image, base_q + per-plane DC/AC deltas + segmentation, frozen `q_idx→qstep` table, and the **CQ quality-parameter mapping** (decode never sees the metric/target — only declared `q_idx`/deltas/`qmul_field`; RDO seam is encoder-only policy).
- **4.5 Invariants** — bit-exactness, exact reversibility, bounded memory, structural DRY (DCT = 8×8 subset of BLOCK's transform; shared color/predict/quant), nothing implicit.

Every SOTA lever from the dossier that belongs to the toolkit is covered the Caustic way (explicit enums, frozen constants, declared rounding, mechanism/policy split, bounded memory), and cross-references the other spec sections (CHNL, ICOD/TransformStack, CICP/ICLR, IQMT, entropy module) without redefining them.

Relevant existing file for style consistency: `/home/caua/Documentos/Projetos-Pessoais/causticos/docs/CSE_FORMAT.md`.

---

I have everything I need. The CSE family conventions are clear: little-endian, fixed-offset declared tables, numbered loader algorithm, explicit reject conditions, magic+version+flags header style. Now I'll write section 5 of the CSIF spec — the lossless codecs (RAW, QOI, MODULAR) — exhaustively and byte-exact, consistent with the Caustic philosophy and the family conventions.

## 5. Codecs lossless (RAW, QOI, MODULAR)

This section specifies the three founding lossless codecs of the CSIF codec registry: **codec 0 = RAW**, **codec 1 = QOI**, and **codec 2 = MODULAR**. All three expose the uniform `{decode, encode}` codec interface (the container ↔ codec seam; see §3) and are dispatched purely by `codec_id` carried in the per-item `ICOD` chunk. The container never inspects codec payload bytes — it hands a codec its tile's byte range plus the shared toolkit and gets pixels back. Every byte of every codec's `params` blob and per-tile bitstream described here is declared, fixed-width, and little-endian, matching the CSE family conventions.

### 5.0 Conventions binding all three codecs

These rules are normative for every lossless codec and override any ambiguity below.

#### 5.0.1 Endianness, integer widths, alignment

- **Endianness is fixed little-endian** for every multi-byte field in every codec `params` blob and in every entropy/bitstream sub-structure. This is the declared file endianness (`IHDR.endianness == 0` = little-endian; see §4); it is stated, never assumed, but no per-codec byte-order flag exists (the TIFF mistake is rejected).
- All `params`-blob scalar fields use the widths declared in their tables (`u8/u16/u32/u64`). All struct-of-scalars carried in `params` follow the Caustic mixed-width rule: where a struct is *materialized in Caustic source* it uses `i64` fields, but the *on-disk* `params` layout is the packed declared width — the codec reads each field with an explicit width-correct load. No field aliases another.
- Tile-payload byte ranges are addressed only through the item's `ITOC`/tile index (§7); a codec never scans for a sync pattern.

#### 5.0.2 Channel model the codec sees

A lossless codec operates on the **channel stack** declared by the item's `CHNL`/channel-descriptor table (§4/§6): an ordered set of `n_chan` integer channels, each with its own `bit_depth` (1..32), `signed` flag, `sample_format` (must be one of `UINT8..UINT32`; lossless codecs do not accept `FLOAT16/FLOAT32` unless the codec declares `supports_float = 1`, which RAW does and QOI/MODULAR do not — they return `E_CSIF_UNSUPPORTED_SAMPLE` for float), and resolution (`chan_w`, `chan_h`, which may differ from the image after subsampling/Squeeze).

The codec sees channels **by index**, never by hardcoded role (no "channel 3 is alpha"). Channel order and meaning come from the descriptor table. This is what lets the same codec losslessly carry RGB, RGBA, gray, depth, alpha-as-aux, or arbitrary named channels.

#### 5.0.3 Tiling, bounded memory, partial decode

- A codec decodes **one tile at a time** into a caller-provided, bounded buffer. Tile geometry (`tile_w`, `tile_h`) is declared in `ICOD`; the last column/row of tiles is cropped to the channel extent (no padding pixels are coded — the coded extent of an edge tile is `min(tile_w, chan_w - tile_x*tile_w) × min(tile_h, chan_h - tile_y*tile_h)`).
- **Tiles are independently decodable.** Entropy-coder state (rANS lanes, adaptive CDFs, color cache, LZ window, self-correcting predictor weights, MA-tree per-context distributions if `per_tile_tables=1`) is **reset at each tile boundary**. No prediction or back-reference crosses a tile boundary unless an explicit `cross_tile = 1` flag is declared (none of RAW/QOI/MODULAR set it in v1; the field is reserved and must be `0`).
- A reader computes its per-tile working set from declared fields (`tile_w × tile_h × Σ ceil(bit_depth/8)` plus the codec's declared scratch) before touching payload bytes. There is **no hidden allocation**.

#### 5.0.4 `is_lossless` invariant

Every codec in this section sets `ICOD.is_lossless = 1` and **MUST** reconstruct the exact integer sample values of every channel (`max_abs_error == 0`), with one declared exception: MODULAR's **near-lossless** mode (§5.3.9), where `near_lossless_delta[c] > 0` for some channel. The container asserts the invariant: **if any `near_lossless_delta[c] != 0`, then `ICOD.is_lossless` MUST be `0`**; `near_lossless_delta[c] == 0` for all `c` is the only configuration compatible with `is_lossless = 1`. A decoder that finds `is_lossless = 1` together with a nonzero delta fails loudly with `E_CSIF_LOSSLESS_INVARIANT`.

#### 5.0.5 Error codes (this section)

All errors are explicit, numbered, and reported with the offending field/offset (the CSE loader discipline). The codes used in this section:

| Code | Symbol | Raised when |
|---|---|---|
| -40 | `E_CSIF_UNSUPPORTED_SAMPLE` | codec handed a sample format it declares it does not support (e.g. QOI given FLOAT32) |
| -41 | `E_CSIF_BAD_PARAMS` | `params` blob shorter than its declared fixed prefix, or a field out of its valid range |
| -42 | `E_CSIF_PAYLOAD_OVERRUN` | decode would read past the declared tile byte range |
| -43 | `E_CSIF_PAYLOAD_TRUNC` | declared symbol count not satisfied before the tile range ended |
| -44 | `E_CSIF_BAD_TRANSFORM` | unknown / out-of-order MODULAR transform id, or a transform whose inverse cannot apply to the declared channels |
| -45 | `E_CSIF_TREE_BOUNDS` | MA-tree exceeds declared `max_tree_nodes`/`max_contexts`, or a node references a property id outside the closed vocabulary |
| -46 | `E_CSIF_PALETTE_BOUNDS` | palette index ≥ declared `n_colors`, or `n_colors > max_palette` |
| -47 | `E_CSIF_LZ_OFFSET` | LZ back-reference offset > declared `window` or crosses the tile boundary |
| -48 | `E_CSIF_LOSSLESS_INVARIANT` | `is_lossless = 1` with a nonzero near-lossless delta |
| -49 | `E_CSIF_CACHE_BITS` | `color_cache_bits` outside 0..11 |

---

### 5.1 Codec 0 — RAW

RAW is the **identity codec**: the floor of the registry, used for incompressible data, for the guaranteed-decodable fallback in capability/alternative sets, and for the software-decode reference of GPU-block payloads. It performs **no** entropy coding, **no** prediction, **no** color transform. It is the only lossless codec that accepts float samples (it just stores their exact bit patterns).

#### 5.1.1 `params` blob layout `(codec_id=0, codec_version=1)`

The RAW `params` blob is 8 bytes fixed (no variable tail):

| Off | Size | Field | Valid values |
|---|---|---|---|
| +0x00 | 1 | `pixel_layout` (u8) | `0` = channel-planar (each channel's samples contiguous, channel-major within the tile), `1` = interleaved (samples of all channels for pixel p, then pixel p+1, …) |
| +0x01 | 1 | `sample_pack` (u8) | `0` = byte-aligned (each sample occupies `ceil(bit_depth/8)` bytes, value right-justified, high bits zero), `1` = bit-packed (sub-byte samples packed MSB-first along x within a row, rows byte-aligned) |
| +0x02 | 1 | `row_alignment` (u8) | row stride alignment in bytes; declared power of two `1,2,4,8`; padding bytes are zero and are part of the coded payload |
| +0x03 | 5 | `reserved` (u8[5]) | MUST be `0`; nonzero → `E_CSIF_BAD_PARAMS` |

Everything else RAW needs (channel count, per-channel `bit_depth`/`sample_format`/`signed`, tile geometry) comes from the declared item descriptors — RAW invents nothing.

#### 5.1.2 RAW decode (per tile)

```
decode_raw(tile_bytes[0..len), out_channels[], tile_w, tile_h):
  compute expected_size from the declared fields:
    for each channel c: bytes_c = bytes_for_plane(chan extent of c within tile,
                                                   bit_depth[c], sample_pack, row_alignment)
    expected = (pixel_layout==0) ? Σ bytes_c
                                 : interleaved_size(...)        # see below
  reject if len != expected                                    # E_CSIF_BAD_PARAMS / overrun
  if pixel_layout == 0 (planar):
    cursor = 0
    for c in 0..n_chan:
      copy/unpack plane c from tile_bytes[cursor .. cursor+bytes_c) into out_channels[c]
      cursor += bytes_c
  else (interleaved):
    for y in 0..tile_h_eff, for x in 0..tile_w_eff, for c in 0..n_chan:
      read one sample (width = ceil(bit_depth[c]/8) or bit-packed) → out_channels[c][y][x]
```

- **`sample_pack = 0` (byte-aligned):** a sample of `bit_depth ≤ 8` is one byte; `9..16` two bytes; `17..32` four bytes; little-endian; the value is right-justified and the unused high bits are zero. Float samples (RAW only) are stored as their exact IEEE 754 little-endian bit pattern (binary16 = 2 bytes, binary32 = 4 bytes); **NaN/Inf/signed-zero round-trip exactly** (this is a stated RAW invariant).
- **`sample_pack = 1` (bit-packed):** only valid for `bit_depth ∈ {1,2,4}` integer channels; indices/samples are packed MSB-first along x, each row padded up to a byte then up to `row_alignment`.
- Decode is a pure copy/unpack; it never allocates beyond the caller's `out_channels`. Reading past `len` is `E_CSIF_PAYLOAD_OVERRUN`; a short `len` is `E_CSIF_PAYLOAD_TRUNC`.

#### 5.1.3 RAW encode

Encode is the exact inverse: pack the channels per `pixel_layout`/`sample_pack`/`row_alignment` into the tile byte range. RAW is bit-exact by construction; the conformance vector for RAW asserts `decode(encode(x)) == x` byte-for-byte including float specials.

---

### 5.2 Codec 1 — QOI

QOI is the **simple, fast lossless codec** for 8-bit RGB / RGBA content: a byte-oriented run-length + small-recent-color-cache + delta scheme. It is the registry's "low-complexity, no-entropy-coder" tier. It is intentionally a strict, sized special case of MODULAR's color cache (`color_cache_bits = 6` with the QOI hash) — keeping it as its own codec gives a tiny, dependency-free decoder.

#### 5.2.1 Applicability and `params`

QOI v1 accepts **only**: `sample_format = UINT8` on **3 channels (RGB)** or **4 channels (RGBA)**, declared in that channel order. Any other configuration (gray, 16-bit, float, CMYK, >4 channels) → `E_CSIF_UNSUPPORTED_SAMPLE`. The channel descriptors still declare the roles; QOI only requires the byte layout R,G,B[,A] in channel order.

QOI `params` blob `(codec_id=1, codec_version=1)` is 4 bytes:

| Off | Size | Field | Valid values |
|---|---|---|---|
| +0x00 | 1 | `has_alpha` (u8) | `0` = 3-channel RGB (alpha implicitly fixed at 255 for hashing/prev, never emitted), `1` = 4-channel RGBA. MUST match `n_chan` |
| +0x01 | 1 | `channels_premul` (u8) | mirrors `IHDR`/channel alpha association for the decoder's records; `0`/`1`; does not change QOI byte coding |
| +0x02 | 2 | `reserved` (u16) | MUST be `0` |

QOI is not tiled below the tile level (it codes the tile's pixels in row-major order); per-tile reset of the running array + previous-pixel applies (§5.0.3).

#### 5.2.2 Decoder state

Per tile, QOI maintains:

- `px` — the current/previous pixel, four `u8` channels `{r, g, b, a}`. **Initialized to `{0, 0, 0, 255}`** at tile start (the QOI seed). For 3-channel mode `a` is forced to `255` permanently and never read from the stream.
- `index[64]` — a 64-entry running array of pixels, each `{r,g,b,a}`. **Initialized to all-zero `{0,0,0,0}`** at tile start (note: the all-zero seed differs from `px`'s seed; this is intentional and matches QOI).
- The hash function:
  ```
  qoi_hash(r,g,b,a) = (r*3 + g*5 + b*7 + a*11) mod 64     # all u8 arithmetic, mod 64 = & 63
  ```
  After **every** decoded pixel, `index[qoi_hash(px)] = px` is written (the running-array update; encoder and decoder run it identically so no state is transmitted).

#### 5.2.3 Chunk tags (exact byte encoding)

QOI's tile bitstream is a sequence of byte-aligned chunks read until the tile's pixel count `tile_w_eff × tile_h_eff` is satisfied. There are six chunk kinds. Two are 8-bit tags (`QOI_OP_RGB`, `QOI_OP_RGBA`) distinguished by a full byte; the other four are 2-bit tags in the top two bits of the leading byte. The 2-bit-tag chunks are tried only when the byte is **not** one of the two 8-bit tags.

**Tag dispatch (leading byte `b`):**

| Leading byte | Tag | Chunk | Total size |
|---|---|---|---|
| `0xFE` | `QOI_OP_RGB` | full RGB literal | 4 bytes |
| `0xFF` | `QOI_OP_RGBA` | full RGBA literal | 5 bytes |
| `b>>6 == 0b00` | `QOI_OP_INDEX` | running-array reference | 1 byte |
| `b>>6 == 0b01` | `QOI_OP_DIFF` | small per-channel delta | 1 byte |
| `b>>6 == 0b10` | `QOI_OP_LUMA` | luma-biased delta | 2 bytes |
| `b>>6 == 0b11` | `QOI_OP_RUN` | run of previous pixel | 1 byte |

Because `0xFE` (`11111110`) and `0xFF` (`11111111`) both have top bits `0b11`, the 8-bit tags are checked **first**; this carves the two values `0b111110` and `0b111111` out of the `QOI_OP_RUN` 6-bit space (so the run length field can only encode runs up to 62, see below).

**`QOI_OP_RGB` (0xFE):** bytes `[0xFE][r][g][b]`. Set `px.r=r, px.g=g, px.b=b`; `px.a` unchanged (stays the previous alpha / 255 in RGB mode). Emit `px`.

**`QOI_OP_RGBA` (0xFF):** bytes `[0xFF][r][g][b][a]`. Set all four; emit. (In 3-channel mode `QOI_OP_RGBA` is illegal — encoder must not emit it; a decoder that meets it in 3-channel mode raises `E_CSIF_BAD_PARAMS`.)

**`QOI_OP_INDEX` (`0b00xxxxxx`):** one byte; low 6 bits = `idx` (0..63). Emit `px = index[idx]`. **Constraint:** the encoder MUST NOT emit a `QOI_OP_INDEX` that would reference the slot the *current* pixel hashes to when that pixel equals `px` (that case is a run); and two consecutive `QOI_OP_INDEX` to the same slot for the same pixel are disallowed by the encoder's preference order (below) — the decoder simply obeys whatever index it reads.

**`QOI_OP_DIFF` (`0b01xxxxxx`):** one byte. Low 6 bits hold three 2-bit signed fields with **bias 2** (i.e. stored value 0..3 maps to delta −2..+1):
```
dr = ((b >> 4) & 0x3) - 2
dg = ((b >> 2) & 0x3) - 2
db = ( b       & 0x3) - 2
```
Apply with **u8 wraparound** (modulo 256): `px.r += dr; px.g += dg; px.b += db;` `px.a` unchanged. Emit `px`. Valid only when each of dr,dg,db ∈ [−2, +1].

**`QOI_OP_LUMA` (`0b10xxxxxx`):** two bytes. Byte 0 low 6 bits = `dg + 32` (bias 32, so `dg ∈ [−32, +31]`). Byte 1 = `(dr_dg + 8)` in the high nibble and `(db_dg + 8)` in the low nibble (bias 8, so each ∈ [−8, +7]):
```
dg     = (b0 & 0x3F) - 32
dr_dg  = ((b1 >> 4) & 0x0F) - 8
db_dg  = ( b1       & 0x0F) - 8
dr = dr_dg + dg
db = db_dg + dg
px.r += dr;  px.g += dg;  px.b += db;        # u8 wraparound
```
`px.a` unchanged. Emit `px`. This codes red/blue **relative to green's delta** (cheap luma decorrelation), valid when `dg ∈ [−32,+31]` and the relative deltas ∈ [−8,+7].

**`QOI_OP_RUN` (`0b11xxxxxx`, excluding 0xFE/0xFF):** one byte. Low 6 bits = `(run_length − 1)` with **bias −1** (stored 0..61 ⇒ run 1..62). Emit `px` (the current/previous pixel) `run_length` times. The two stored values 62 and 63 (which would map to runs 63 and 64) are **forbidden** because their byte encodings are exactly `0xFE`/`0xFF`; the encoder MUST split runs longer than 62 into multiple `QOI_OP_RUN` chunks. During a run **no** running-array update is performed per repeated pixel beyond the single update for `px` (the array already holds `px`); the standard rule is the array is updated once per *distinct* emitted pixel, and a run emits the same `px` repeatedly.

#### 5.2.4 Per-pixel post-step and running-array update

After decoding any non-run chunk (and once for the pixel that begins a run), the decoder writes `index[qoi_hash(px)] = px`. The previous-pixel `px` carries forward. Decode ends exactly when the declared tile pixel count is reached; if the stream ends early → `E_CSIF_PAYLOAD_TRUNC`; if a chunk would require bytes past the tile range → `E_CSIF_PAYLOAD_OVERRUN`.

#### 5.2.5 End-of-tile

QOI in CSIF does **not** use QOI's original 8-byte `00..01` end marker — the tile's pixel count is declared by geometry, and the tile byte range is declared by the index, so termination is structural. A decoder MUST stop at the declared pixel count and MUST verify it consumed exactly the declared tile byte range (a residue of nonzero bytes → `E_CSIF_BAD_PARAMS`; this catches corruption). This removes QOI's "scan for end marker" magic in favor of the family's explicit-length discipline.

#### 5.2.6 Encoder preference order (policy, normative for producing the smallest valid stream)

The encoder is free, but the canonical (and conformance-vector) encoder, per pixel, chooses the **first** applicable in this order: (1) if pixel == `px` → extend/emit `QOI_OP_RUN`; (2) else if `index[qoi_hash(pixel)] == pixel` → `QOI_OP_INDEX`; (3) else if alpha unchanged and dr,dg,db ∈ [−2,+1] → `QOI_OP_DIFF`; (4) else if alpha unchanged and the luma-relative deltas fit → `QOI_OP_LUMA`; (5) else if alpha unchanged → `QOI_OP_RGB`; (6) else → `QOI_OP_RGBA`. The decoder does not depend on this order — it obeys whatever tags appear.

---

### 5.3 Codec 2 — MODULAR

MODULAR is the **strong lossless codec**: an integer-only pipeline of a declared, **ordered, closed, reversible transform stack** applied to the channel stack, followed by per-channel **self-correcting prediction** with an **MA decision tree** selecting the entropy context per residual, an optional **LZ77 back-reference + color-cache** literal layer, feeding the **shared rANS entropy substrate** with per-context distributions. It covers true lossless, near-lossless, palettized, and (via Squeeze) responsive/progressive lossless. It is the DRY consumer of the shared `predict`, `color`/`transform`, `lz`, and `entropy` toolkit modules.

MODULAR is a small **interpreter**: decode reads declared structures (transform list, MA-tree nodes, palette, frequency tables, LZ params) and runs them; **nothing about decode is learned or heuristic at decode time.** All encoder cleverness (which transforms, how to grow the tree, parse quality) is policy that produces these declared structures.

#### 5.3.1 `params` blob layout `(codec_id=2, codec_version=1)`

The MODULAR `params` blob has a fixed prefix followed by variable-length sub-blocks. Multi-byte fields little-endian.

**Fixed prefix (24 bytes):**

| Off | Size | Field | Meaning |
|---|---|---|---|
| +0x00 | 1 | `n_chan` (u8) | channel count this codec instance operates on (must equal the descriptor count) |
| +0x01 | 1 | `transform_count` (u8) | number of entries in the transform list (0..`max_transforms`, default cap 32) |
| +0x02 | 1 | `predictor_granularity` (u8) | `0` = per-tile (one predictor id per channel per tile), `1` = per-row (predictor id stored per scanline, like PNG), `2` = MA-tree-selected (predictor chosen at the MA-tree leaf) |
| +0x03 | 1 | `color_cache_bits` (u8) | `0` = disabled, `1..11` = enabled with `2^bits` entries; `>11` → `E_CSIF_CACHE_BITS` |
| +0x04 | 1 | `lz_enable` (u8) | `0`/`1`; when `1`, the LZ sub-block (below) is present |
| +0x05 | 1 | `window_log` (u8) | LZ back-reference window = `1<<window_log` bytes (of the post-transform residual stream); valid `0`(if lz off) or `10..24`; bounds the ring buffer |
| +0x06 | 1 | `ma_tree_mode` (u8) | `0` = no MA tree (single global context per channel), `1` = one shared MA tree for all tiles, `2` = per-tile MA tree |
| +0x07 | 1 | `entropy_method_id` (u8) | which shared-toolkit entropy method (`0` = rANS-static-interleaved is the MODULAR default; `1` = adaptive-CDF; `2` = prefix/Huffman). See §entropy. |
| +0x08 | 1 | `entropy_precision` (u8) | log2 of the ANS total (e.g. `12` ⇒ TOTAL=4096) |
| +0x09 | 1 | `entropy_lanes` (u8) | rANS interleave lane count (1/2/4/8/16/32) |
| +0x0A | 1 | `hybrid_split_exp` (u8) | hybrid-uint `split_exponent` (token/raw split for residual magnitudes) |
| +0x0B | 1 | `hybrid_msb_in_token` (u8) | hybrid-uint MSBs carried in token |
| +0x0C | 1 | `hybrid_lsb_in_token` (u8) | hybrid-uint LSBs carried in token |
| +0x0D | 1 | `residual_map` (u8) | signed→unsigned mapping: `0` = zigzag, `1` = zigzag+zero-RLE, `2` = zigzag+EOB |
| +0x0E | 2 | `max_tree_nodes` (u16) | declared cap on MA-tree node count (decoder pre-sizes; tree larger → `E_CSIF_TREE_BOUNDS`) |
| +0x10 | 2 | `max_contexts` (u16) | declared cap on distinct entropy contexts (clusters) |
| +0x12 | 1 | `tables_scope` (u8) | `0` = global frequency tables (in `params`), `1` = per-tile tables (in each tile payload) |
| +0x13 | 1 | `min_decoder_level` (u8) | the minimum MODULAR feature level a decoder must implement to render this stream; a lower-level decoder fails loudly (lossless transforms cannot be skipped) |
| +0x14 | 4 | `near_lossless_present` (u8) + `reserved` (u8[3]) | byte +0x14: `1` if a per-channel near-lossless delta sub-block follows; +0x15..+0x17 reserved=0 |

**Variable sub-blocks, in this exact order after the fixed prefix:**

1. **Near-lossless deltas** (present iff `near_lossless_present == 1`): `n_chan` × `u16` `near_lossless_delta[c]` (per-channel ±error bound; `0` = exact for that channel). If any is nonzero, container requires `is_lossless = 0` (§5.0.4).
2. **Transform list:** `transform_count` TLV records (§5.3.2).
3. **Per-channel predictor selection** (present iff `predictor_granularity == 0`): `n_chan` × `u8` `predictor_id[c]` (§5.3.4). For granularity `1` the per-row ids live in the tile payload; for granularity `2` predictor choice is encoded in MA-tree leaves.
4. **MA-tree** (present iff `ma_tree_mode == 1`, the shared tree): serialized node array (§5.3.5). For `ma_tree_mode == 2` the tree(s) live per-tile in the payload.
5. **Context-map / cluster table** (present iff `ma_tree_mode != 0`): `n_raw_ctx` × `u16` mapping raw-context → cluster id, plus `u16 cluster_count` (§5.3.6).
6. **LZ sub-block** (present iff `lz_enable == 1`): §5.3.8 — `u8 min_match`, `u8 dist_remap_enable`, repeat-offset count, and the closed length/distance code config.
7. **Global frequency tables** (present iff `tables_scope == 0`): one declared rANS frequency/CDF table per cluster (§entropy table format).

A `params` blob shorter than the bytes implied by these declared counts → `E_CSIF_BAD_PARAMS`.

#### 5.3.2 Transform list — the closed, ordered, invertible transform stack

The transform list is MODULAR's core data model. Each record:

```
[ transform_id : u8 ][ param_len : u16 ][ params : param_len bytes ]
```

`transform_id` is a **closed enum**. Unknown id → `E_CSIF_BAD_TRANSFORM` (transforms are load-bearing; they are *never* skippable — a skipped transform produces wrong pixels, so MODULAR uses `min_decoder_level`, not the skippable-chunk mechanism, for forward-compat).

| id | Transform | Reversible | param payload |
|---|---|---|---|
| 0 | `XF_RAW` | yes (identity passthrough) | none |
| 1 | `XF_RCT` | yes | §5.3.3 |
| 2 | `XF_SUBTRACT_GREEN` | yes | none (special case of RCT; kept for cheap path) |
| 3 | `XF_CROSS_COLOR` | yes | §5.3.3 |
| 4 | `XF_PALETTE` | yes | §5.3.7 |
| 5 | `XF_DELTA_PALETTE` | yes | §5.3.7 |
| 6 | `XF_SQUEEZE` | yes | §5.3.10 |

**Application order:** the encoder applies the listed transforms **forward, in stored order**. The decoder, after entropy-decoding the channels, applies each transform's **inverse in reverse order**. Every transform declares an exact integer inverse; the order is part of the file (no canonical order baked in the decoder). A transform whose declared channel range/params are inapplicable to the current channel stack → `E_CSIF_BAD_TRANSFORM`.

#### 5.3.3 RCT family and cross-color

**`XF_RCT` (id 1)** — reversible color transform over three declared color channels. param payload (4 bytes):

| Off | Size | Field |
|---|---|---|
| +0x00 | 1 | `rct_type` (u8) — closed enum 0..6 (see below) |
| +0x01 | 1 | `chan0` (u8) — index of first input channel |
| +0x02 | 1 | `chan1` (u8) |
| +0x03 | 1 | `chan2` (u8) |

`rct_type` selects a member of the reversible family (all integer lifts; the chroma channels gain +1 bit of headroom, which MUST be reflected in the post-transform channel `bit_depth` declared in the descriptor — the headroom bit is declared, never implicit):

- `0` = Identity (no-op; legal so the list can carry a permutation only).
- `1` = **YCgCo-R** (canonical), forward:
  ```
  Co = R - B
  t  = B + (Co >> 1)        # arithmetic shift, two's-complement
  Cg = G - t
  Y  = t + (Cg >> 1)
  ```
  inverse:
  ```
  t  = Y - (Cg >> 1)
  G  = Cg + t
  B  = t - (Co >> 1)
  R  = Co + B
  ```
- `2..6` = the five additional add/subtract permutations of (chan0,chan1,chan2) used by JXL's RCT family (each a fixed pair of lift directions; enumerated and fully written in the §color toolkit reference). The decoder selects the inverse by `rct_type`; there is no auto-detection.

**`XF_SUBTRACT_GREEN` (id 2)** — `R -= G; B -= G` (forward), `R += G; B += G` (inverse), on three declared channels carried in a 3-byte param payload `[chanR][chanG][chanB]`. (A frequently-useful special case kept separate so the cheap path needs no RCT machinery.)

**`XF_CROSS_COLOR` (id 3)** — per-block signed-multiplier color decorrelation (the VP8L move that RCT can't express). param payload:

| Off | Size | Field |
|---|---|---|
| +0x00 | 1 | `block_log2` (u8) — block size = `1<<block_log2` (2..8) |
| +0x01 | 1 | `chanG` / `chanR` / `chanB` indices (3 bytes) |
| +0x04 | … | per-block signed multipliers, coded as a sub-image: three `i8` multipliers per block — `green_to_red`, `green_to_blue`, `red_to_blue` — in row-major block order, themselves entropy-coded as a MODULAR sub-stream (DRY) |

Inverse, per block, per pixel (after the green channel is reconstructed): `red += (green * green_to_red) >> 5; blue += (green * green_to_blue + red * red_to_blue) >> 5` — exact integer arithmetic with the declared `>>5` scaling (fixed in the spec). Forward subtracts. Multiplier blocks are coded as a sub-image, so the same predict/entropy path handles them (no special channel).

#### 5.3.4 Predictor set (shared `predict` toolkit)

`predictor_id` (closed enum), per channel/row/leaf:

| id | Predictor | prediction `p` from causal neighbors A=left, B=above, C=above-left, D=above-right |
|---|---|---|
| 0 | `PRED_NONE` | `0` (residual = sample) |
| 1 | `PRED_SUB` | `A` |
| 2 | `PRED_UP` | `B` |
| 3 | `PRED_AVG` | `(A + B) >> 1` |
| 4 | `PRED_PAETH` | the one of `{A,B,C}` closest to `A + B − C` (ties → A then B then C) |
| 5 | `PRED_GRADIENT` | `clamp(A + B − C, min(A,B,C_clamped...), …)` — the gradient/median predictor (Paeth-style clamp to the [min,max] of A,B) |
| 6 | `PRED_WEIGHTED` | the **self-correcting weighted predictor** (§5.3.4.1) |

All arithmetic is modular at the channel bit depth (residual `r = (sample − p) mod 2^bit_depth`; reconstruct `sample = (p + r) mod 2^bit_depth`), so every predictor is exactly invertible. For signed channels the modulus wraps in two's complement.

##### 5.3.4.1 `PRED_WEIGHTED` — self-correcting weighted predictor (JXL Modular #14 class)

State per channel (reset per tile): a fixed set of `K` sub-predictors and `K` per-sub-predictor running error accumulators. The v1 sub-predictor set (`K = 4`, fixed): `W = A`, `N = B`, `NW-gradient = clamp(A + B − C)`, `NE-trend = B + (B − D)` (declared, frozen). Per pixel:

```
for i in 0..K: spi = subpred_i(neighbors)
weight_i  = (1 << WSHIFT) / (err_acc_i + EPS)         # integer reciprocal, declared WSHIFT, EPS
p = ( Σ weight_i * spi + (Σ weight_i >> 1) ) / Σ weight_i   # rounded weighted mean, integer
... decode residual, reconstruct true value v ...
for i in 0..K: err_acc_i = err_acc_i - (err_acc_i >> DECAY) + abs(spi - v)
```

`WSHIFT`, `EPS`, `DECAY`, the rounding rule, and the sub-predictor formulas are **spec-fixed constants** carried by the toolkit (declared in `params` only by `predictor_id = 6`; their values are not per-file — they are frozen so encode/decode are bit-exact across machines). The decoder runs the identical update so weights stay in lockstep with **no transmitted weights**.

#### 5.3.5 MA decision tree (MANIAC) — serialized, declared

When `ma_tree_mode != 0`, an MA tree selects, per residual, the entropy **context** (and, when `predictor_granularity == 2`, the predictor). The tree is **data in the bitstream**, evaluated as a pure interpreter of a **closed property vocabulary**.

**Property vocabulary (closed enum, the only properties a node may test):**

| prop id | Property (computed from causal state at the pixel) |
|---|---|
| 0 | channel index `c` |
| 1 | `abs(N − W)` (vertical-vs-horizontal gradient magnitude) |
| 2 | `abs(W − NW)` |
| 3 | `abs(N − NE)` |
| 4 | the `PRED_WEIGHTED` current max sub-predictor error bucket |
| 5 | previous residual magnitude bucket (in this channel) |
| 6 | x position bucket (`x >> xbucket_log`) |
| 7 | y position bucket |
| 8 | `W` value bucket |
| 9 | `N` value bucket |

A node referencing a prop id outside this set → `E_CSIF_TREE_BOUNDS`.

**Node serialization** — a flat array of `node_count` (u16) records, root = index 0:

```
[ node_kind : u8 ]        # 0 = internal, 1 = leaf
internal: [ property_id : u8 ][ threshold : i32 ][ left : u16 ][ right : u16 ]
leaf:     [ context_id : u16 ][ predictor_id : u8 (only if predictor_granularity==2, else absent) ]
```

Evaluation: start at root; at an internal node, compute `property_id`'s value; go `left` if `value <= threshold` else `right`; at a leaf, use `context_id` (and `predictor_id`). The tree MUST be acyclic and within `max_tree_nodes`/`max_contexts` (validated before decode; violation → `E_CSIF_TREE_BOUNDS`). Bucket shifts (`xbucket_log`, value-bucket quantization, error-bucket quantization) are spec-fixed constants. Access is **causal only** (no future pixels), so working memory is a few scanlines.

#### 5.3.6 Context map / clustering

`max_contexts` declared leaves can map onto a smaller set of stored distributions via a context-map (cluster) table: `cluster_count` (u16) plus a `context_id → cluster_id` array. Each distinct `cluster_id` owns one rANS frequency table (global in `params` when `tables_scope=0`, else per-tile). This bounds table cost while allowing many leaves. The decoder: derive context via the MA tree → look up `cluster_id` → decode the residual token under that cluster's distribution.

#### 5.3.7 Palette and delta-palette

**`XF_PALETTE` (id 4)** — replace the declared color channels with a single index channel referencing a coded palette. param payload:

| Off | Size | Field |
|---|---|---|
| +0x00 | 2 | `n_colors` (u16) — palette entry count; `> max_palette` (default cap 4096) → `E_CSIF_PALETTE_BOUNDS` |
| +0x02 | 1 | `palette_channels` (u8) — channels per palette entry (e.g. 3 RGB, 4 RGBA) |
| +0x03 | 1 | `index_bits` (u8) — bit depth of the index channel (1/2/4/8/16; MUST satisfy `2^index_bits ≥ n_colors`) |
| +0x04 | 1 | `pack_order` (u8) — sub-byte index packing: `0` = MSB-first along x (for `index_bits ∈ {1,2,4}`), packing declared, never inferred from `n_colors` |
| +0x05 | 1 | `index_channel` (u8) — which output channel index becomes the index plane |
| +0x06 | … | palette data: `n_colors × palette_channels` samples, each at the original channel `bit_depth`, in the file colorspace, row-major by entry — itself a MODULAR sub-image (entropy-coded, DRY) |

Inverse: for each pixel, read the index value `i` (`i ≥ n_colors` → `E_CSIF_PALETTE_BOUNDS`), write `palette[i][k]` to channel `k`. The index plane is itself fed through the predictor + MA-tree + entropy pipeline (indices have spatial structure).

**`XF_DELTA_PALETTE` (id 5)** — same layout, but palette entry `k` is stored as a residual against a prediction from prior entries (`pred = entry[k-1]` by default; an explicit `delta_mode` byte at payload +0x06 selects {prev-entry, fixed-gradient}). The decoder reconstructs entries in order before depalettizing. Useful for gradient-as-palette and near-palette images.

#### 5.3.8 LZ77 layer + color cache (the WebP-VP8L-class literal classes)

When `lz_enable == 1`, MODULAR's residual symbol stream (post-transform, post-predict, per channel or per declared LZ group) carries **three literal classes** in one closed alphabet:

1. **literal** — a predicted-residual value (coded via the hybrid-uint token + context).
2. **LZ match** — a `(length, distance)` back-reference into the bounded window of already-decoded *post-transform residual bytes*. `distance > window` or a distance that would cross the tile boundary → `E_CSIF_LZ_OFFSET`.
3. **color-cache hit** — when `color_cache_bits > 0`, a `cache_index` (`color_cache_bits` wide) referencing the direct-mapped recent-color table.

**Combined alphabet (closed, MODULAR's honest op-set):** symbol values `0 .. (2^bd − 1)` = residual literals; `2^bd .. 2^bd + n_len_codes − 1` = LZ length codes (each with declared extra-bits); the top `2^color_cache_bits` values (when enabled) = cache indices. The decoder branches on the decoded symbol's range; for a length code it then decodes a distance code (+extra bits) and copies.

**Color cache:** `2^color_cache_bits` entries, each a full color tuple. Hash slot:
```
slot = (0x1e35a7bd * pixel_u32) >> (32 - color_cache_bits)     # multiplier frozen in toolkit
```
After every decoded pixel, `cache[slot] = pixel` (encoder/decoder identical; nothing transmitted). The multiplier `0x1e35a7bd` and the update rule are spec-fixed.

**LZ sub-block fields** (in `params` when `lz_enable=1`): `u8 min_match` (≥ 2), `u8 rep_offset_count` (0..3 — number of cheap repeat-offset codes; rep state seeded with the row stride when `dist_remap_enable=1`), `u8 dist_remap_enable` (when 1, the first ~120 distances pass through the frozen 2D `(dx,dy)` remap table so `linear_distance = dy*chan_w + dx`). The length/distance extra-bits layout and the 2D remap table are **frozen constants in the shared `lz`/`entropy` toolkit** (reused by any codec wanting back-references). The window ring buffer is sized `1<<window_log` and is the only LZ allocation (bounded).

**Parse quality is encoder policy.** Greedy vs optimal (cost-graph) parsing produces different token streams but both decode identically; the format encodes no parse strategy. A future better parser drops in with no format change.

#### 5.3.9 Near-lossless

When `near_lossless_delta[c] > 0`, channel `c` is quantized **inside the prediction loop** using already-quantized neighbors so error does not accumulate: the residual is quantized to a step of `2*delta+1`, the decoder reconstructs the quantized samples **exactly** (it is lossless coding of a pre-quantized image). The reconstruction error per sample is bounded by `±delta`. `delta` is per-channel and declared; `delta = 0` ⇒ exact. The container enforces `is_lossless = 0` whenever any delta is nonzero (§5.0.4).

#### 5.3.10 Squeeze (responsive/progressive lossless)

**`XF_SQUEEZE` (id 6)** — reversible Haar-like lift building a band pyramid for resolution-/quality-progressive lossless. param payload = `u8 step_count` followed by `step_count` records `[ axis : u8 (0=horizontal,1=vertical) ][ chan_first : u8 ][ chan_last : u8 ][ levels : u8 ]`.

Per step, per affected channel, the squeeze lift splits a line `(a, b)` of adjacent samples into an **average** sub-channel and a **residual** sub-channel:
```
avg      = (a + b) >> 1
residual = a - b                       # parity of (a+b) is recoverable from residual's LSB relation
# inverse (with the tendency/rounding correction term fixed in the spec):
b = avg - (residual >> 1) ... a = b + residual   (exact integer reconstruction)
```
applied recursively for `levels`, producing DC + detail bands. The **band layout in the tile payload is declared** (a band-offset sub-table at the head of the squeezed channel's data), so progressive decode is a documented prefix read, not streaming guesswork. Decoding the DC band first, then detail bands, yields a valid lower-resolution image at each prefix; the inverse lifts reconstruct exactly. Squeeze composes with tiling: a reader gets both spatial (tile) and resolution (band) bounded-memory partial decode.

#### 5.3.11 MODULAR decode algorithm (per tile)

```
decode_modular_tile(tile_bytes, item_descriptors, params):
  1. validate params prefix + sub-blocks; pre-size all buffers from declared caps
     (channels, ring buffer 1<<window_log, color cache, MA-tree nodes, cluster tables);
     any cap violation → loud error before reading payload.
  2. reset per-tile state (rANS lanes, adaptive CDFs / load global tables,
     color cache, LZ window, weighted-predictor accumulators, per-tile MA tree if mode==2).
  3. entropy-decode the channel residual streams:
       for each symbol until all post-transform channel samples are produced:
         derive raw context (MA-tree props on causal neighbors) → cluster_id → distribution
         decode token (hybrid-uint: token under cluster dist, raw extra bits)
         branch on alphabet range:
           literal     → unzigzag/RLE/EOB per residual_map → residual r
                          → reconstruct sample = (predict(neighbors, predictor_id) + r) mod 2^bd
           LZ length   → decode distance (+remap) → copy from window (bounds-checked)
           cache hit   → emit cache[index]
         update color cache, weighted-predictor error accumulators, rep-offsets.
  4. apply the transform stack INVERSES in REVERSE order
     (e.g. inverse Squeeze → inverse Palette → inverse CrossColor → inverse RCT).
  5. result = exact integer channel samples (or ±delta-bounded for near-lossless channels).
  verify: exactly the declared tile byte range was consumed; else E_CSIF_BAD_PARAMS.
```

Encode is the mirror: apply transforms forward, predict, map residuals, optionally LZ-match + cache, build/serialize the MA tree + cluster map + frequency tables, emit the rANS streams. The conformance corpus for MODULAR asserts bit-exact `decode(encode(x)) == x` for the lossless configuration and `max_abs_error ≤ delta` for each near-lossless channel.

#### 5.3.12 Forward-compatibility for MODULAR

Because a skipped transform corrupts pixels, MODULAR does **not** use the container's skippable-chunk mechanism for its own internal structures. Instead it declares `min_decoder_level` (params +0x13): a decoder implementing a lower level **MUST refuse loudly** (`E_CSIF_BAD_TRANSFORM` / a dedicated level error) rather than silently mis-decode. New transforms, properties, or predictors are added by new enum values + a `min_decoder_level` bump (and, for the registry, a `codec_version` bump), never by overloading existing ids.

---

### 5.4 Summary of the lossless registry seam

| codec_id | name | entropy | transforms | float | progressive | use |
|---|---|---|---|---|---|---|
| 0 | RAW | none | none | yes | no | incompressible / fallback / GPU-block software path |
| 1 | QOI | none (byte chunks) | implicit luma/index | no | no | fast simple 8-bit RGB(A) |
| 2 | MODULAR | shared rANS + context | RCT / palette / cross-color / squeeze | no (v1) | yes (Squeeze) | strong lossless, near-lossless, palettized, responsive |

All three are dispatched by `codec_id` alone; the container bakes in none of them; each exposes the identical `{decode, encode}` interface; each reuses the shared toolkit (`predict`, `color`/`transform`, `lz`, `entropy`) rather than reimplementing it. Unknown `codec_id` → loud failure (`E_CSIF_UNKNOWN_CODEC`), never a guess.

---

I now have the family conventions firmly in hand (little-endian, fixed-width records, explicit offsets, loud rejection, closed enums, the entropy substrate from the dossier's `[entropy]` section). I'll write the complete section 6 spec.

## 6. Codec DCT lossy (classe JPEG)

> **Codec registry slot.** `codec_id = 3`, name `DCT`. Selected per-tile-group through the container's uniform `{decode, encode}` codec vtable (mechanism), dispatched purely by `codec_id` in `ICOD`. The container never interprets a single byte of this codec's payload — it hands the codec its tile byte-ranges (from `ITOC`) plus the shared toolkit, exactly as it does for every other codec. Everything below is **policy** owned by codec 3; nothing in this section may leak into the container.
>
> **What it is.** A JPEG-class lossy still codec — explicit color transform, optional chroma subsampling, fixed `8×8` forward/inverse DCT-II, frequency-weighted quantization driven by a named-metric quality target, zig-zag scan, DC prediction, and a hybrid-integer coefficient **token model** fed to the shared **rANS** entropy substrate with explicit context modeling — i.e. *everything JPEG does, modernized*: Huffman replaced by context-adaptive rANS, baked-in tables replaced by declared tables, the magic quality dial replaced by a perceptual-metric target, and uniform quantization extended with an optional **per-block adaptive-quant field**.
>
> **What it is NOT.** Codec 3 is the fixed-`8×8` DCT codec. Variable block sizes (`8×8 .. 32×32`), rectangular transforms, ADST/IDTX, intra prediction, CfL, and in-loop restoration (CDEF/Wiener) are the province of codec 4 (`BLOCK`), specified separately. Codec 3 deliberately uses **only** the fixed `8×8` DCT subset of the shared `transform` toolkit so that the two codecs share one transform implementation (DRY). This keeps codec 3 small, fast, deterministic, and a clean migration target for JPEG content, while codec 4 carries the VarDCT machinery.

This section is byte-exact and implementable. All multi-byte fields are **little-endian** (the container's declared, single, fixed endianness — never a per-file flag). All scalar struct fields are stored and read as the declared widths but, per the Caustic mixed-width-struct miscompile gotcha, any in-memory Caustic structs that mirror these layouts use `i64` scalar fields and pack/unpack to/from the declared byte widths explicitly.

---

### 6.1 Scope, invariants, and the mechanism/policy seam

The DCT codec's **closed op-set** is exactly:

```
DctCodec = {
    fn decode(cfg: *const DctConfig, in: *const u8, in_len: u64,
              out_planes: *PlaneSet, scratch: *Scratch) -> i32,
    fn encode(cfg: *const DctConfig, in_planes: *const PlaneSet,
              out: *u8, out_cap: u64, scratch: *Scratch) -> i64,   // bytes written, or negative errno
}
```

There is no `ioctl`, no side channel, no escape hatch. Both ops operate on **caller-provided buffers** (`out_planes`, `scratch`, `out`) — the codec performs **no hidden allocation**; all working-set sizes are computable up front from `DctConfig` (§6.3) and the tile geometry (§6.6). This satisfies the bounded-memory rule: a decoder sizes every buffer before it reads any coefficient bytes.

Hard invariants (each is a loud, numbered error — never a silent clamp or guess; §6.16):

- **I1 — Decoder determinism.** Decode is a pure function of `(DctConfig, tile bytes, declared tables)`. The inverse DCT and dequantization are a **spec-fixed fixed-point pipeline** (§6.7, §6.8); there is no platform-dependent float in the decode path. Two conformant decoders produce **bit-identical** pixels (this is what makes lossy decode conformance a *number*, not a vibe — §6.17). The encoder is free to use any search/heuristics; only its output bytes are normative.
- **I2 — Self-description.** Every parameter a decoder needs is in `DctConfig` or the per-tile header (§6.6). The decoder never infers subsampling from buffer sizes, never assumes a color matrix, never assumes a quant table, never assumes a gamma. Colorspace/transfer/primaries/matrix come from the container's `IHDR`/`ICLR` CICP block (the project's color rule) — codec 3 only declares which color-model transform it applied (§6.4).
- **I3 — Lossless flag honesty.** `ICOD.is_lossless` MUST be `0` for codec 3. Codec 3 is a lossy codec; an exactly-lossless image uses codec 2 (`MODULAR`) or the reversible path of codec 4. The container asserts this and rejects `codec_id=3 ∧ is_lossless=1` loudly (`E_DCT_LOSSLESS_FLAG`).
- **I4 — Tile independence.** Each tile is an independent decode unit: its entropy state is reset at tile start, DC prediction is reset at tile start (§6.10), no coefficient or context state crosses a tile boundary. A corrupt tile damages only that tile (§6.16). This is the mechanism that delivers bounded memory + partial/ROI decode.
- **I5 — Shared toolkit only.** Color conversion uses the shared `color` module; the transform uses the shared `transform` module's fixed-`8×8` DCT entry; entropy uses the shared `entropy` (rANS) substrate; the adaptive-quant field, when present, is a Modular sub-image decoded by codec 2 through the shared seam. Codec 3 reimplements none of these.

---

### 6.2 Pipeline overview (encode forward / decode inverse)

Decode is the exact inverse of encode, applied in reverse order. The stages, and where each is specified:

```
ENCODE (policy; only the emitted bytes are normative)
  source pixels (IHDR color model, sample format)
    → §6.4  color transform        RGB → coded color model (e.g. YCbCr), per ICOL_MODEL
    → §6.5  chroma subsample        4:4:4 / 4:2:2 / 4:2:0, per CHROMA_SUBSAMPLE; co-sited/centered
    → §6.6  tiling + per-tile hdr   partition into tiles; emit DctTileHeader
    → §6.7  level shift + fwd DCT   per 8x8 block, fixed-point DCT-II
    → §6.8  quantization            base table × adaptive multiplier (optional field)
    → §6.9  zig-zag scan            8x8 → 64 coefficients in scan order
    → §6.10 DC prediction           DC differential vs left block (per component, per tile)
    → §6.11 token model             coefficients → (token, extra-bits) hybrid-integer symbols
    → §6.12 context model           ctx_id per symbol from causal neighbors
    → §6.13 rANS entropy            tokens → bytes via shared entropy substrate
    → §6.14 stream layout           per-tile, per-component sub-streams + EOFF offsets

DECODE (mechanism + the codec's deterministic inverse)
  reverse of the above, stage by stage; §6.7 inverse DCT and §6.8 dequant are bit-exact.
```

---

### 6.3 `DctConfig` — the codec-owned, versioned config blob (`ICOD.params` for `codec_id=3`)

`ICOD` carries `codec_id (u8)`, `codec_version (u16)`, `is_lossless (u8)`, the tile grid, and an opaque `params` blob. For `codec_id=3, codec_version=1` the layout of `params` is **this** struct. The container treats it as opaque bytes (pure dispatch); only codec 3 parses it. `codec_version` gates forward-compat independently of other codecs: an unknown `(codec_id=3, codec_version)` fails loudly (`E_DCT_VERSION`), never best-effort.

`DctConfig` (fixed-width, little-endian; total declared size = `params_len`, validated):

| Off | Size | Field | Type | Meaning / valid range |
|---|---|---|---|---|
| 0x00 | 2 | `dct_magic` | u16 | `0xDC71` — sanity tag for `params`; mismatch ⇒ `E_DCT_MAGIC` |
| 0x02 | 1 | `config_version` | u8 | `1` |
| 0x03 | 1 | `n_components` | u8 | `1..=4` (must equal IHDR-implied coded-component count, §6.4) |
| 0x04 | 1 | `color_model` | u8 | closed enum, §6.4 (`0=NONE,1=YCBCR_BT601,2=YCBCR_BT709,3=YCBCR_BT2020NCL,4=YCGCO_R,5=ICTCP`) |
| 0x05 | 1 | `chroma_subsample` | u8 | closed enum, §6.5 (`0=444,1=422,2=420,3=440,4=411`) |
| 0x06 | 1 | `chroma_sample_pos` | u8 | closed enum, §6.5 (`0=COSITED_H_COSITED_V`, `1=CENTERED_H_COSITED_V`, `2=CENTERED_H_CENTERED_V`) |
| 0x07 | 1 | `precision_mode` | u8 | `0=8BIT` (level shift 128, range 0..255), `1=HIGH` (per `IHDR.bit_depth`, §6.7) |
| 0x08 | 1 | `dc_pred_mode` | u8 | closed enum, §6.10 (`0=NONE,1=LEFT,2=LEFT_RESET_AT_TILE`) |
| 0x09 | 1 | `aq_present` | u8 | `0`=global quant only; `1`=adaptive-quant sub-image present (§6.8.2) |
| 0x0A | 1 | `aq_block_log2` | u8 | log2 of the AQ field grid cell in `8×8`-block units (`0`=per-block, `1`=per-2×2 blocks, …); `0` if `aq_present=0` |
| 0x0B | 1 | `trellis_hint` | u8 | advisory only: `0`/`1` records whether the encoder used trellis quant; **never** read by decode (provenance) |
| 0x0C | 2 | `n_quant_tables` | u16 | `1..=4`; number of `8×8` base quant tables that follow |
| 0x0E | 2 | `entropy_table_block_len` | u16 | byte length of the embedded rANS table block that follows the quant tables (§6.13) |
| 0x10 | `n_components × ComponentDesc(8B)` | `components[]` | array | one per coded component, §6.3.1 |
| … | `n_quant_tables × QuantTable(132B)` | `quant_tables[]` | array | each = 4B header + 64×u16 in zig-zag order, §6.8.1 |
| … | `entropy_table_block_len` | `entropy_tables` | bytes | declared rANS frequency tables + context map (§6.13) |

A reader validates: `dct_magic`, `config_version`, that `0x10 + n_components*8 + n_quant_tables*132 + entropy_table_block_len == params_len`, and that every `ComponentDesc.quant_table_id < n_quant_tables`. Any failure ⇒ loud error.

#### 6.3.1 `ComponentDesc` (8 bytes, one per coded component)

| Off | Size | Field | Type | Meaning |
|---|---|---|---|---|
| +0 | 1 | `component_role` | u8 | closed enum: `0=Y/luma`, `1=Cb/chroma-blue`, `2=Cr/chroma-red`, `3=alpha`, `4=gray`, `5=I (ICtCp)`, `6=Ct`, `7=Cp` |
| +1 | 1 | `quant_table_id` | u8 | index into `quant_tables[]` |
| +2 | 1 | `h_subsample_log2` | u8 | horizontal subsampling, log2 (`0`=full, `1`=half) — MUST be consistent with `chroma_subsample` |
| +3 | 1 | `v_subsample_log2` | u8 | vertical subsampling, log2 |
| +4 | 1 | `entropy_ctx_set` | u8 | index of the context-model set used for this component's coefficients (§6.12) |
| +5 | 1 | `reserved0` | u8 | `0` |
| +6 | 2 | `reserved1` | u16 | `0` (must be 0; non-zero ⇒ `E_DCT_RESERVED`) |

Per-component subsampling is **declared**, not derived. The decoder cross-checks `(h_subsample_log2, v_subsample_log2)` against `chroma_subsample` (§6.5) and rejects inconsistency (`E_DCT_SUBSAMPLE_MISMATCH`).

---

### 6.4 Color transform (`color_model`)

The color transform decorrelates channels before the DCT. It is **explicit**: the codec declares which transform it applied; the decoder applies the exact inverse. The *colorimetric meaning* of the output (primaries, transfer function, full/limited range, the precise YCbCr↔RGB matrix code point) lives in the container's `ICLR` CICP block — codec 3 does not duplicate it. `color_model` only names **which reversible-direction matrix the codec used so the decoder can undo it**, and it MUST be consistent with `ICLR.matrix_coefficients` (else `E_DCT_COLOR_MATRIX_MISMATCH`).

Closed enum `color_model`:

| Val | Name | Forward (encode) | Notes |
|---|---|---|---|
| 0 | `NONE` | identity (channels coded as-is) | for already-decorrelated or gray/alpha-only input; `n_components` may be 1 (gray) |
| 1 | `YCBCR_BT601` | BT.601 RGB→YCbCr | matrix consistent with CICP `matrix=6` |
| 2 | `YCBCR_BT709` | BT.709 RGB→YCbCr | CICP `matrix=1` |
| 3 | `YCBCR_BT2020NCL` | BT.2020 non-constant-luminance | CICP `matrix=9` |
| 4 | `YCGCO_R` | reversible YCgCo-R (integer lifting) | not used for lossy gain here but allowed; chroma gets +1 headroom bit (declared in `IHDR`/component bit depth) |
| 5 | `ICTCP` | ICtCp (for HDR PQ/HLG content) | CICP `matrix=14`; requires high-precision (`precision_mode=HIGH`) |

The forward/inverse matrices are the **frozen constants in the shared `color` module** (one implementation reused by codecs 3, 4, and the metric pipeline — DRY). For non-`NONE` models the matrices and the full-/limited-range scaling are applied in the container-declared range (`ICLR.full_range`). For `YCBCR_*`, the standard `Y' = a·R' + b·G' + c·R'`, `Cb`, `Cr` definitions of the named matrix apply; constants are tabulated in the shared module spec and are bit-exact (fixed-point, declared shift). 

> Anti-magic: a `color_model` value with no consistent CICP matrix is illegal. `NONE` does **not** mean "assume RGB" or "assume sRGB"; it means the channels are coded verbatim and their meaning is whatever `ICLR` declares.

---

### 6.5 Chroma subsampling

Subsampling reduces chroma resolution before the DCT. It is **declared**, with an explicit sample-position so co-sited vs centered siting is never guessed (the classic interop bug).

`chroma_subsample` closed enum (luma : chroma horizontal : chroma vertical):

| Val | Name | Luma | Cb/Cr h-factor | Cb/Cr v-factor | `(h_sub_log2, v_sub_log2)` for chroma |
|---|---|---|---|---|---|
| 0 | `S444` | full | 1× | 1× | (0,0) |
| 1 | `S422` | full | ½ | 1× | (1,0) |
| 2 | `S420` | full | ½ | ½ | (1,1) |
| 3 | `S440` | full | 1× | ½ | (0,1) |
| 4 | `S411` | full | ¼ | 1× | (2,0) |

`chroma_sample_pos` closed enum gives the chroma siting relative to luma (mirrors H.273 `chroma_sample_loc`):

| Val | Name | Meaning |
|---|---|---|
| 0 | `COSITED_H_COSITED_V` | chroma samples co-sited with the top-left luma sample of each chroma cell |
| 1 | `CENTERED_H_COSITED_V` | horizontally centered (MPEG-1/JPEG style), vertically co-sited |
| 2 | `CENTERED_H_CENTERED_V` | centered in both axes |

**Downsampling** (encode) and **upsampling** (decode) filters are **spec-fixed and declared** so output is reproducible:

- Downsample: each chroma output is the average of its `2^h × 2^v` luma-cell co-located chroma sources, computed in fixed-point with round-to-nearest-even at the precision of the working sample depth. (Encoders may use better analysis filters internally, but the *normative* statement is only that the decoder upsamples per the rule below; the encoder's downsample choice is policy that does not change the decode contract — only the stored chroma samples do.)
- Upsample (normative, decode): determined by `chroma_sample_pos`. For `CENTERED_*`, chroma is reconstructed by the spec-fixed separable filter (a declared symmetric short filter — co-sited positions reproduce the stored sample; intermediate positions use the declared `{-1, 9, 9, -1}/16` Catmull-Rom-style tap, clamped, in fixed-point). For `COSITED_*`, the co-sited position copies; off-grid positions use the same declared filter referenced to the co-sited grid. The exact tap coefficients and rounding are frozen constants in the shared `color`/`resample` module. A decoder MUST use exactly these so the reconstructed image is bit-identical (I1).

Bounded memory: upsampling operates on a tile's chroma plane into a tile-sized luma-resolution scratch buffer whose size is computed from the tile geometry (§6.6).

---

### 6.6 Tiling and the per-tile header

Codec 3 inherits the container's tile grid (`ICOD.tile_w`, `ICOD.tile_h`, `n_tiles`) and the container's `ITOC`/`EOFF` offset index. Each tile is an **independent decode unit** (I4). Tile dimensions are declared; the last row/column of tiles is clipped to the image dimensions (the partial blocks at the right/bottom edge are padded by **edge replication** to a whole `8×8` block before the forward DCT, and the padding is discarded on output — the padding rule is declared so encode/decode agree).

Each tile's byte payload begins with a **`DctTileHeader`** (fixed-width, little-endian):

| Off | Size | Field | Type | Meaning |
|---|---|---|---|---|
| +0 | 2 | `tile_magic` | u16 | `0x71D7`; mismatch ⇒ `E_DCT_TILE_MAGIC` (also a resync anchor, §6.16) |
| +2 | 2 | `tile_index` | u16 | this tile's index in raster tile order; cross-checked against `ITOC` |
| +4 | 2 | `tile_w_px` | u16 | actual pixel width of this tile (≤ `ICOD.tile_w`) |
| +6 | 2 | `tile_h_px` | u16 | actual pixel height (≤ `ICOD.tile_h`) |
| +8 | 1 | `n_substreams` | u8 | number of entropy sub-streams in this tile (§6.14); normally `n_components` |
| +9 | 1 | `aq_substream` | u8 | `0xFF` if no AQ sub-image in this tile; else the sub-stream index of the AQ Modular sub-image (§6.8.2) |
| +0xA | 2 | `flags` | u16 | bit0=`HAS_CRC` (a per-tile CRC32C trails the tile payload, §6.16); bit1=`ALL_DC_ONLY` (every block in this tile coded DC-only, an encoder shortcut for flat tiles); bits 2..15 reserved=0 |
| +0xC | `n_substreams × SubStreamDesc(12B)` | `substreams[]` | array | per sub-stream: `{component_or_role:u8, kind:u8 (0=COEFF,1=AQ_MODULAR), reserved:u16, byte_off:u32 (relative to tile payload start), byte_len:u32}` |

`byte_off`/`byte_len` make every sub-stream randomly addressable within the tile; the container's `EOFF` may additionally expose them at file scope for cross-tile parallel/partial decode. A decoder validates each sub-stream range ⊆ the tile payload and rejects dangling/overlapping ranges (mirrors the CSE loader's `file_off+file_size > cst_size` guard).

Working-set per tile (declared, bounded): one luma-resolution plane buffer per component for the tile (`tile_w_px × tile_h_px × sample_width`), plus the `8×8` block scratch, plus the rANS lane state and the per-component context tables. All sizes derive from `DctConfig` + `DctTileHeader`; no allocation occurs after these are read.

---

### 6.7 Level shift and the `8×8` forward/inverse DCT

#### 6.7.1 Level shift

Before the forward DCT each sample is centered: `s' = s − offset`, where `offset = 1 << (bit_depth − 1)` (i.e. `128` for 8-bit, `512` for 10-bit, `2048` for 12-bit, `32768` for 16-bit). `precision_mode=8BIT` fixes `bit_depth=8` (`offset=128`); `precision_mode=HIGH` uses `IHDR.bit_depth`. On decode the inverse adds `offset` back and clamps to `[0, (1<<bit_depth)−1]`. Float sample formats (`FLOAT16`/`FLOAT32` from the container) are **not** supported by codec 3 (`E_DCT_SAMPLE_FORMAT`); float HDR uses codec 4's float path or codec 2.

#### 6.7.2 The transform — spec-fixed, integer, bit-exact

Codec 3 uses **only** the fixed `8×8` separable DCT-II / IDCT-III entry of the shared `transform` module. The transform is the **integer, bit-exact** definition (decoder side normative): a separable, two-pass integer approximation with declared fixed-point scaling and rounding — the AAN/LLM-class fast integer DCT specified in the shared module, with:

- intermediate precision and the exact rounding constants declared as frozen constants in the `transform` module spec,
- the same code path for all supported `bit_depth` (the working accumulator width is declared wide enough — 32-bit intermediates for ≤12-bit, 64-bit for 16-bit — so there is no overflow and no platform-dependent behavior),
- **inverse-DCT bit-exactness is the conformance contract** (I1): the inverse is the single normative definition and is the function the golden test vectors (§6.17) certify. The *forward* DCT is encoder policy (an encoder may use any forward transform that, after quantization and the normative inverse, yields the reference pixels) — but the spec ships one reference forward DCT so encoders have a known-good default.

This is the JPEG-`8×8` subset of the same `{fdct, idct}` interface codec 4 uses for its larger/rectangular transforms; codec 3 simply never invokes the non-`8×8` entries.

---

### 6.8 Quantization

#### 6.8.1 Base quantization tables (frequency weighting = the quality lever)

Each `8×8` block of DCT coefficients is divided by a quantization step and rounded; the inverse multiplies back. Quantization tables are **carried explicitly** in `DctConfig` (never assumed, never the baked-in JPEG default). Each `QuantTable` is 132 bytes:

| Off | Size | Field | Type | Meaning |
|---|---|---|---|---|
| +0 | 1 | `qt_id` | u8 | this table's id (must equal its array index) |
| +1 | 1 | `qt_precision` | u8 | `0`=8-bit steps (u8 values, here promoted to u16), `1`=16-bit steps |
| +2 | 2 | `qt_reserved` | u16 | `0` |
| +4 | 128 | `steps[64]` | u16[64] | quantization steps, **in zig-zag order** (index 0 = DC), each `1..=65535` |

Steps are stored in zig-zag order (so the table aligns with the scan, §6.9) and **per-frequency** (the classic JPEG luminance/chrominance weighting: small steps for low frequencies the eye sees, larger for high frequencies — but the actual values are the encoder's policy, recorded as data). A step of `0` is illegal (`E_DCT_QUANT_ZERO`).

Dequantization (decode, normative): `coeff_dequant[k] = coeff_quant[k] × step[k] × aq_mult(block)`, computed in the declared fixed-point (§6.8.3). Quantization (encode, policy): `coeff_quant[k] = round(coeff[k] / (step[k] × aq_mult(block)))`, where `round` is round-half-away-from-zero by default; encoders may trellis-quantize (`trellis_hint` records it) — only the stored quantized integers are normative.

**Quality target → tables.** Codec 3 does not embed a magic `q=NN`. The container's `IQMT` chunk (the named-metric quality scale: `{metric_id, target_value, achieved_value}`) records what "this quality" means; the encoder iterates quant scaling until the achieved metric (e.g. `SSIMULACRA2=90` or `BUTTERAUGLI_MAXNORM=1.0`) crosses the target, then writes the resulting tables here. The achieved value is recorded. The decoder reads tables, not a quality number — quality is encoder policy, the tables are mechanism the decoder reproduces exactly.

#### 6.8.2 Adaptive quantization field (optional, `aq_present=1`)

Adaptive quantization modulates the quant step spatially: more bits where the eye notices (smooth gradients, faces, edges), fewer where masking hides error (texture). This is the largest low-bitrate perceptual lever.

The per-block multipliers are stored as a **Modular sub-image** (codec 2) — *not* a bespoke side channel. This is the JXL "everything that isn't main pixels is a Modular sub-image" unification, made explicit in CSIF: the AQ field is a declared sub-stream (`SubStreamDesc.kind = AQ_MODULAR`, located by `DctTileHeader.aq_substream`), decoded by codec 2 through the shared seam (DRY). 

- The AQ sub-image is a single-channel integer image at grid resolution `ceil(tile_blocks_w / 2^aq_block_log2) × ceil(tile_blocks_h / 2^aq_block_log2)`, where `tile_blocks_*` is the tile size in `8×8` blocks for the *luma* component.
- Each stored value `m` is a **quantized log2 multiplier**: `aq_mult = 2^((m − AQ_BIAS) / AQ_SCALE)` with frozen constants `AQ_BIAS = 128`, `AQ_SCALE = 32` (so `m=128 ⇒ ×1.0`; range gives roughly `×0.06 .. ×16`). The mapping is fixed; `aq_mult` is evaluated in the declared fixed-point (§6.8.3). The same multiplier applies to all components' co-located blocks (chroma blocks map through their subsampling).
- The encoder's masking model (how it computes `m`) is **policy** living in the encoder. Decode is pure mechanism: read the declared field, look up the cell, multiply. Nothing is heuristic at decode.

If `aq_present=0`, `aq_mult(block) = 1.0` for all blocks (and no AQ sub-stream exists).

#### 6.8.3 Fixed-point dequant arithmetic (normative)

`step[k]` (u16) and `aq_mult` (a `Q16.16` fixed-point value, the dequantized result of §6.8.2's mapping evaluated against a frozen 256-entry table to avoid `pow` in the decode loop) combine as:
`dq[k] = (coeff_quant[k] · step[k] · aq_mult_q16) + (1 << 15)) >> 16`, in 64-bit intermediate, then passed to the integer IDCT. The `+ (1<<15)` is round-to-nearest. The frozen `aq_mult` table and this exact expression are part of the conformance contract.

---

### 6.9 Zig-zag scan

Each quantized `8×8` block is read into a 64-element vector in zig-zag order so low-frequency (likely-nonzero) coefficients come first and the high-frequency tail (likely-zero) is contiguous for run/EOB coding. The mapping is the **standard JPEG zig-zag**, frozen as a constant table `ZIGZAG[64]` in codec 3:

```
 0,  1,  8, 16,  9,  2,  3, 10,
17, 24, 32, 25, 18, 11,  4,  5,
12, 19, 26, 33, 40, 48, 41, 34,
27, 20, 13,  6,  7, 14, 21, 28,
35, 42, 49, 56, 57, 50, 43, 36,
29, 22, 15, 23, 30, 37, 44, 51,
58, 59, 52, 45, 38, 31, 39, 46,
53, 60, 61, 54, 47, 55, 62, 63
```

`scan[i] = block_raster[ZIGZAG[i]]`. Index `0` is the DC coefficient; indices `1..63` are AC in increasing frequency. The quant table `steps[]` is stored in this same order (§6.8.1) so step lookup is `steps[i]`.

---

### 6.10 DC prediction

The DC coefficient is strongly correlated between adjacent blocks, so codec 3 codes the **DC differential** rather than the absolute DC, per component. `dc_pred_mode`:

| Val | Name | Predictor for block at block-column `c` |
|---|---|---|
| 0 | `NONE` | predictor = 0 (absolute DC coded) |
| 1 | `LEFT` | predictor = DC of the previous block in raster order (continues across rows) |
| 2 | `LEFT_RESET_AT_TILE` | predictor = DC of the left block; **reset to 0 at the start of each tile and at the start of each block-row within the tile** |

For tile independence (I4) the recommended and default mode is **`LEFT_RESET_AT_TILE`**: the DC predictor is reset to `0` at the first block of each tile (and at each block-row start within the tile), so no DC state crosses a tile boundary. The stored value is `dc_diff = dc_quant[block] − predictor`; decode reconstructs `dc_quant[block] = dc_diff + predictor`, updating `predictor = dc_quant[block]`. The differential is signed; it enters the token model (§6.11) zig-zag-folded like any coefficient.

Each component maintains its own independent DC predictor. Prediction operates on **quantized** DC values (so it is exactly reversible).

---

### 6.11 Coefficient token model (the symbols fed to rANS)

This replaces JPEG's Huffman run/size categories with the shared **hybrid-integer token** scheme so a tiny entropy alphabet losslessly carries the full coefficient range (including high-precision/HDR coefficients), and a small set of contexts (§6.12) makes them cheap. The token stream per `8×8` block, per component, is:

**Per block, in scan order (index 0..63):**

1. **DC symbol.** The DC differential (§6.10) is signed→unsigned via zig-zag fold `u = zigzag_fold(d) = (d << 1) ^ (d >> 63)` (arithmetic shift; the toolkit's frozen `zigzag`/`unzigzag` helpers), then split by the shared **hybrid-integer** function `token_of(u, DC_HYBRID_CONFIG)` into `(dc_token, nbits, raw)`. `dc_token` is entropy-coded under a DC context (§6.12); the `nbits` `raw` extra bits are written verbatim to the extra-bits sub-channel (§6.13). `DC_HYBRID_CONFIG` (`split_exponent`, `msb_in_token`, `lsb_in_token`) is declared in the entropy table block.

2. **AC coefficients (indices 1..63).** Coded as a run/level/EOB token sequence over the shared coder:
   - **EOB token**: if all remaining AC coefficients in scan order are zero, emit a single `EOB` token (carrying, via a small hybrid split, the *position* where the block ends, so the common "rest are zero" case is one symbol). This is the modern equivalent of JPEG's end-of-block.
   - Otherwise, for each nonzero AC coefficient, the model emits a **run token** = `run_of_preceding_zeros` (hybrid-coded; long runs use extra bits) immediately followed by a **level token** = `token_of(zigzag_fold(level), AC_HYBRID_CONFIG)` with its `raw` extra bits. The `(run, level)` pairing is a single logical step but each part has its own context and its own alphabet position so the coder can model them independently.
   - A reserved **ZRL-class** long-zero-run is naturally expressed by the run token's hybrid extra bits (no separate 16-zero special symbol needed); the run alphabet covers `0..63` with extra bits.

The **combined AC alphabet** is the closed symbol set `{ EOB, run_token(magnitude bucket), level_token(magnitude bucket) }`. These three branches **are** the codec's honest coefficient op-set — there is no fourth, no escape hatch. A decoder reads a token, branches on its alphabet range (EOB vs run vs level), reads any declared extra bits, and reconstructs the coefficient. Signed reconstruction is `unzigzag_fold(value_of(token, raw, CONFIG))`.

The hybrid split keeps the token alphabet to ~tens of symbols while the extra bits (written raw to a separate, explicitly-positioned bit sub-channel) carry the in-bucket offset at ~1 bit each — this is what lets 12/16-bit coefficient magnitudes ride a small, fast, context-modeled histogram. `DC_HYBRID_CONFIG`, `AC_HYBRID_CONFIG`, the run-token config, and the EOB-position config are all declared fields (frozen per `config_version`, carried in the entropy table block), never magic constants in the decoder.

---

### 6.12 Context model

Context modeling is the largest post-transform compression lever after the token split. Each symbol is coded under one of a small set of rANS distributions selected by an **explicit, causal** context function. The context **function** is codec policy (specified here, exactly, so it is reproducible); the **mapping** `raw_ctx → cluster_id → distribution` is mechanism carried as a declared `context_map` in the entropy table block (§6.13). The decoder derives `raw_ctx` from already-decoded state only (causal), so encode and decode stay in lockstep — bit-exact, no learned/hidden behavior.

The closed property set used to form `raw_ctx` (per `entropy_ctx_set`, referenced by each `ComponentDesc`):

- **For the DC token:** `raw_ctx = quantize_dc_ctx(|dc_diff_left| + |dc_diff_up|)` where `dc_diff_left`/`dc_diff_up` are the DC differentials of the already-decoded left and above blocks (0 at tile/row edges), bucketed by a frozen log-bucket function `quantize_dc_ctx` into `N_DC_CTX` buckets. Plus the component role.
- **For AC run tokens:** `raw_ctx` = `(scan_position_band(i), nonzero_neighbor_count)` where `scan_position_band` maps the current scan index `i` into a few frequency bands (frozen band table) and `nonzero_neighbor_count` is the number of nonzero AC coefficients already decoded in this block bucketed to a small range. Plus component role.
- **For AC level tokens:** `raw_ctx` = `(scan_position_band(i), magnitude_band(previous_level_in_block))` — conditioning the level distribution on position and on the magnitude of the previously decoded level in the same block. Plus component role.

`scan_position_band`, `magnitude_band`, `quantize_dc_ctx`, `nonzero_neighbor_count` bucketing, and `N_DC_CTX` are **frozen constants** of `config_version`. The raw context space is then mapped through the declared `context_map` (a `raw_ctx → cluster_id` table) onto the `K` actually-stored distributions, so many raw contexts can share one histogram to bound table cost. `K` (cluster count) is a declared field. Causal-only neighbor access keeps decode memory bounded to the current block plus the previous block-row of DC differentials.

---

### 6.13 rANS entropy stage (shared substrate)

All tokens are coded with the **shared entropy substrate** (`entropy_method_id = 0`, static interleaved rANS), exactly as specified in the entropy section of this document. Codec 3 does **not** ship its own coder; it provides token streams + contexts and calls `ec_decode_symbol(reader, ctx_id)` / `ec_encode_symbol(writer, ctx_id, sym)`. The substrate's invariants (12-bit precision `TOTAL = 4096` default, 32-bit state, byte-wise renormalization floor `L`, lane count, alias-table build, normalized-table format, stream direction) are the substrate's contract and are bit-exact and conformance-tested there.

The **entropy table block** embedded in `DctConfig` (`entropy_table_block_len` bytes) carries, in declared order:

1. The three hybrid configs (`DC_HYBRID_CONFIG`, `AC_LEVEL_HYBRID_CONFIG`, `AC_RUN_HYBRID_CONFIG`) and the EOB-position config — each `{split_exponent:u8, msb_in_token:u8, lsb_in_token:u8, reserved:u8}`.
2. `K` (u16) — number of stored distributions.
3. The `context_map` (a `raw_ctx → cluster_id` table; length = total raw-context count, which is computable from the frozen property dimensions; entries are u16).
4. The `K` normalized frequency tables, each in the substrate's declared normalized-count format (counts summing to `TOTAL`, with the guaranteed-nonzero floor for any used symbol).

For each tile, each component's coefficient tokens form one entropy **sub-stream** (located by `SubStreamDesc`, §6.6); the AQ Modular field forms its own sub-stream. The **extra bits** (the raw hybrid bits, §6.11) are written to an explicitly-positioned raw-bit sub-channel **per coefficient sub-stream**, in the substrate's declared bit order (LSB-first for the rANS path); its byte length is part of the sub-stream's `byte_len`. Entropy state is reset at the start of every sub-stream (I4), so a sub-stream is independently decodable for parallel/partial decode.

---

### 6.14 Bitstream layout (putting it together)

For one image coded with codec 3:

```
container:
  IHDR        dims, bit_depth, channels, sample_format
  ICLR        CICP color block (primaries/transfer/matrix/full_range)  [+ optional ICCP]
  IQMT        {metric_id, target_value, achieved_value, achieved_is_measured}   (mandatory: lossy)
  ICOD        codec_id=3, codec_version=1, is_lossless=0, tile grid,
              params = DctConfig (§6.3)  ───────────────┐
  ITOC        per coded-unit {kind, coords, byte_off,   │   one entry per (tile[,component])
              byte_len, dependency_mask}                │
  EOFF        per (tile,component) sub-stream offsets    │
  IDAT        ┌──────────────────────────────────────── ▼ ────────────────────────────────┐
              │ tile[0]: DctTileHeader + substream[0..n] (coeff tokens + extra bits, AQ)   │
              │ tile[1]: …                                                                  │
              │ …                                                                           │
              └──────────────────────────────────────────────────────────────────────────┘
  IEND        whole-file checksum
```

Within a tile (the `byte_len` of an `ITOC`/`EOFF` tile entry):

```
DctTileHeader (§6.6)
  substream[i] for i in 0..n_substreams:
     rANS bytes for this (tile,component) coefficient stream   (offset = SubStreamDesc.byte_off)
       ├─ entropy-coded tokens (DC + AC run/level/EOB), context-selected
       └─ raw extra-bits sub-channel (hybrid offsets)
  [ optional AQ Modular sub-stream, kind=AQ_MODULAR ]          (codec-2 decoded)
  [ optional per-tile CRC32C if flags.HAS_CRC ]                (§6.16)
```

A reader: validates `DctConfig`, reads `ITOC`/`EOFF`, and for each tile it wants (all of them, or only those intersecting an ROI), seeks to the tile, reads `DctTileHeader`, then per component decodes the sub-stream → tokens → coefficients → dequant → IDCT → block plane; upsamples chroma (§6.5); inverts the color transform (§6.4); writes the tile into `out_planes`. Tiles are independent, so this parallelizes across CPUs with per-tile bounded memory.

---

### 6.15 Decode algorithm (normative, numbered — the deterministic core)

```
DCT_DECODE(cfg=DctConfig, tile_bytes, tile_geom, out_planes, scratch):
  D1  validate DctConfig: dct_magic, config_version, size accounting, quant_table_id<n,
        every step!=0, color_model⇄ICLR.matrix consistent, subsample⇄components consistent
  D2  read DctTileHeader; validate tile_magic, tile_index⇄ITOC, every SubStreamDesc range
        ⊆ tile payload, no overlap; reject loudly otherwise
  D3  if flags.HAS_CRC: verify trailing CRC32C over tile payload; on mismatch → E_DCT_TILE_CRC
        (localized: this tile is undecodable; other tiles unaffected)
  D4  if aq_substream != 0xFF: decode the AQ Modular sub-image (codec 2) into aq_grid[]
        else aq_grid := all-ones (mult=1.0)
  D5  init rANS substrate from cfg.entropy_tables (hybrid configs, K, context_map, K tables)
  D6  for each component comp in 0..n_components:
        reset DC predictor := 0 (dc_pred_mode); open comp's coeff sub-stream + extra-bits channel
        for each 8x8 block in comp's tile raster (block-row major):
          if dc_pred_mode resets at row start and block is first in row: predictor := 0
          B1  ctx := dc_context(comp, left/up dc_diff)            // §6.12
              dc_token := ec_decode_symbol(reader, ctx); raw := read_extra(nbits(dc_token))
              dc_diff := unzigzag_fold(value_of(dc_token, raw, DC_HYBRID_CONFIG))
              dc_quant := dc_diff + predictor;  predictor := dc_quant
              scan[0] := dc_quant
          B2  i := 1
              loop:
                t := ec_decode_symbol(reader, run_or_level_or_eob ctx)   // alphabet branch
                if t is EOB: read eob-position extra bits; zero-fill scan[i..63]; break
                if t is run: run := value_of(t,raw,AC_RUN_CFG); i += run
                             t2 := ec_decode_symbol(reader, level ctx)
                             lvl := unzigzag_fold(value_of(t2, read_extra(...), AC_LEVEL_CFG))
                             scan[i] := lvl; i += 1
                if i >= 64: break
          B3  inverse zig-zag: block_raster[ZIGZAG[k]] := scan[k]      // §6.9
          B4  dequant: for k in 0..63: dq[k] := round16(block_raster[k] * step[k] * aq_mult(block))
          B5  idct8x8_fixed(dq) → spatial[8x8]                          // §6.7.2, bit-exact
          B6  level-unshift + clamp; store into comp's tile plane at the block position
  D7  upsample chroma planes per chroma_subsample + chroma_sample_pos   // §6.5, fixed filter
  D8  inverse color transform per color_model into out_planes' pixel model  // §6.4
  D9  discard edge padding beyond (tile_w_px, tile_h_px); done
```

Every step is visible and declared; no heuristic chooses anything at decode time. The only inputs are the bytes and the declared tables.

---

### 6.16 Error resilience and integrity

- **Tile independence (I4)** localizes corruption: a damaged tile fails its own `tile_magic`/CRC/range checks and is reported loudly with `{tile_index, offset, error_code}`; all other tiles decode. A reader fills an undecodable tile with a **declared sentinel** (a flag in the decode call selects: hard-fail the whole image, or fill the tile region with mid-gray and continue with a per-tile error in the result). Never silent garbage.
- **Per-tile CRC32C** (`flags.HAS_CRC`) over the tile payload (excluding the CRC word) detects corruption before decode; on mismatch → `E_DCT_TILE_CRC`. The whole-file integrity hash lives in the container `IEND`.
- **Resync.** `tile_magic` (`0x71D7`) and `DctTileHeader` are byte-anchored at the `ITOC`-declared tile offset; the decoder seeks by declared offset and never scans for markers. If `ITOC` itself is lost, `tile_magic` allows a deterministic forward scan as a last-resort recovery (declared, not required).
- **Bounded.** Every length is validated against the remaining tile payload before it is used; no allocation precedes validation.

---

### 6.17 Conformance

- **Decoder conformance = bit-exact.** Because the inverse DCT (§6.7.2), dequant (§6.8.3), chroma upsampling (§6.5), and inverse color transform (§6.4) are all spec-fixed fixed-point, a conformant decoder MUST reproduce the reference decoded pixels **exactly** (max abs error = 0) for every vector in the codec-3 conformance corpus. The corpus ships in-repo beside the codec (like a `.cdvrspec` beside a driver) and is checked by the project's `verify.sh`-style harness. The corpus includes: minimal single-tile images at each `chroma_subsample`, each `color_model`, `8BIT`/`HIGH` precision, with and without the AQ field, with and without per-tile CRC.
- **Encoder conformance = metric band (optional).** An encoder claiming a quality target asserts that the `IQMT.achieved_value` falls within `[target − eps, target + eps]` of the named metric measured against the source, with `eps` declared per metric. This is a separate contract from decode; it never affects whether a file decodes.
- **Corruption corpus.** Truncated tiles, bad `tile_magic`, bad CRC, dangling `SubStreamDesc` ranges, zero quant steps, `is_lossless=1`, unknown `config_version`, inconsistent `color_model`/CICP — each with its **expected numbered error code** (§6.18), proving the decoder fails predictably and loudly.

---

### 6.18 Error codes (numbered, loud — never silent)

| Code | Name | Condition |
|---|---|---|
| `E_DCT_MAGIC` | bad `dct_magic` | `DctConfig.dct_magic != 0xDC71` |
| `E_DCT_VERSION` | unknown config version | `config_version` unsupported |
| `E_DCT_LOSSLESS_FLAG` | lossless flag set | `ICOD.is_lossless==1` for `codec_id=3` |
| `E_DCT_SIZE` | params size mismatch | declared sub-block sizes ≠ `params_len` |
| `E_DCT_RESERVED` | reserved field nonzero | a reserved field ≠ 0 |
| `E_DCT_QUANT_ZERO` | zero quant step | any `step[k]==0` |
| `E_DCT_COLOR_MATRIX_MISMATCH` | color model vs CICP | `color_model` inconsistent with `ICLR.matrix_coefficients` |
| `E_DCT_SUBSAMPLE_MISMATCH` | subsample vs component | `chroma_subsample` ≠ per-component `(h,v)_subsample_log2` |
| `E_DCT_SAMPLE_FORMAT` | unsupported sample format | float sample format with `codec_id=3` |
| `E_DCT_TILE_MAGIC` | bad tile magic | `DctTileHeader.tile_magic != 0x71D7` |
| `E_DCT_TILE_CRC` | tile CRC mismatch | per-tile CRC32C check failed |
| `E_DCT_SUBSTREAM_RANGE` | sub-stream out of bounds | a `SubStreamDesc` range dangles/overlaps |
| `E_DCT_TILE_INDEX` | tile index mismatch | `tile_index` ≠ `ITOC` expectation |

---

### 6.19 Summary of declared knobs (no magic, no defaults)

Everything the decoder needs is one of: a field in `DctConfig` (`color_model`, `chroma_subsample`, `chroma_sample_pos`, `precision_mode`, `dc_pred_mode`, `aq_present`, `aq_block_log2`, per-component `ComponentDesc`, the quant tables, the entropy table block); a field in `DctTileHeader` (geometry, sub-stream descriptors, flags, AQ locator, CRC); or a **frozen constant of `config_version`** (the integer DCT/IDCT, the zig-zag table, the AQ multiplier mapping, the context property functions, the hybrid token configs, the chroma resample taps, the rANS substrate constants). No quantization is assumed, no color is guessed, no subsampling is inferred, no quality number is implicit — the file is 100% self-describing, the decode is bit-exact, and quality (the encoder's quant + AQ + metric search) is cleanly separated from mechanism (the decoder reading declared fields).

---

The full specification text for section 6 is above. Key design decisions, for the integrating editor:

- **Codec slot:** `codec_id = 3, codec_version = 1`. Its `ICOD.params` blob layout is `DctConfig` (§6.3), versioned independently and validated for exact size.
- **Shared-toolkit consumers (DRY):** color matrices via shared `color`; fixed-`8×8` DCT via the shared `transform` module's `8×8` entry (same `{fdct,idct}` codec 4 uses for larger transforms); entropy via the shared rANS substrate (`entropy_method_id=0`); the adaptive-quant field is a **codec-2 Modular sub-image**, not a bespoke channel — this is the cross-section unification hook the BLOCK/MODULAR authors must mirror.
- **Cross-section dependencies the editor must keep consistent:** `IQMT` (named-metric quality), `ICLR`/CICP (color), `ITOC`/`EOFF` (tile/sub-stream offsets), the rANS substrate's frozen constants (precision/state/renorm/alias-table), and the shared `zigzag`/`token_of`/`value_of` hybrid-integer helpers. Field names (`tile_magic 0x71D7`, `dct_magic 0xDC71`, `AQ_BIAS=128`, `AQ_SCALE=32`, the `ZIGZAG[64]` table) are load-bearing and used verbatim in §6.15's decode algorithm.
- **Conformance:** decode is bit-exact (fixed-point IDCT/dequant/upsample/color), so the golden-vector corpus certifies decoders; encoder conformance is the separate `IQMT` metric-band check.

---

I have everything needed. Now writing the spec section.

## 7. Codec BLOCK lossy moderno (classe AVIF/VarDCT)

### 7.1 Propósito, posição na família e contrato de honestidade

`BLOCK` é o **codec_id = 4** do registro de codecs do CSIF. É o codec **lossy de alta eficiência** da família — a classe AVIF / AV1-intra / JPEG XL VarDCT — desenhado para fechar a lacuna entre o codec `DCT` (codec_id 3, JPEG-class, DCT 8×8 fixo) e o estado da arte de compressão perceptual a baixo bitrate. Onde `DCT` é o piso honesto e simples, `BLOCK` é o teto de qualidade-por-byte para imagens fotográficas, HDR e mistas.

Esta seção especifica o codec **no nível de design, mas de forma exaustiva**: a interface (op-set fechado), a estrutura do bitstream byte-a-byte onde aplicável, o conjunto fechado de partições, modos de predição intra, tipos/tamanhos de transformada, quantização adaptativa, filtros in-loop, contextos de entropia por tile, e síntese de grão de filme. É um **slot honesto** (princípio #4): a interface, o bitstream e as invariantes estão **completamente fechados aqui**; a implementação dos slots pode chegar depois, mas **nunca** como decodificador falso — ou um decodificador real, ou um slot de interface honestamente sequenciado que retorna `E_CSIF_CODEC_UNIMPLEMENTED` (loud), jamais pixels inventados.

`BLOCK` **não** reimplementa máquina nenhuma. Ele é, por construção, um **consumidor** dos módulos compartilhados já especificados em outras seções:

- **toolkit `entropy/`** — o substrato de entropia (rANS estático interleaved, modo CDF adaptativo, prefix-code) selecionado por `entropy_method_id`, com a frente de hybrid-integer-token, o context-map clusterizado e a tabela `EOFF` de offsets por stream. `BLOCK` **não** define entropia própria.
- **toolkit `transform/`** — o op-set fechado de transformadas `{fdct/idct, fadst/iadst, fwht/iwht, identity}` parametrizadas por tamanho, com constantes de base e arredondamento fixo-ponto **congeladas no spec** (decode bit-exato).
- **toolkit `color/`** — RGB↔YCbCr / YCgCo-R / XYB selecionado pelo `matrix_coefficients` declarado em `IHDR` (CICP). `BLOCK` nunca embute uma matriz de cor implícita.
- **toolkit `predict/`** — o op-set de preditores intra `{predict_dc, predict_paeth, predict_smooth(_h/_v), predict_directional(angle), predict_cfl(alpha)}`, compartilhado com `MODULAR`.
- **toolkit `perceptual/`** — o campo de quantização adaptativa (`aq_field`) e o seam de RDO; **mecanismo** (layout do campo) aqui, **política** (como o encoder escolhe) fora.
- **container CSIF** — tiling (`tile_w/tile_h/n_tiles`), índice `ITOC`/`TIDX`, sub-imagens declaradas (`SubImage`), canais auxiliares (`IAUX`), cor (`COLR`/CICP/ICC), HDR volume (`IHDM`), e o chunk de grão (`IGRN`). `BLOCK` **dispara** esses, não os redefine.

O seam container↔codec é **uniforme** e idêntico ao de todos os outros codecs (espelha a vtable KObject do kernel). O container despacha por `codec_id`, entrega ao `BLOCK` os bytes do tile + os toolkits, e **nunca** conhece o interior de `BLOCK`. Isto é o que torna "todos os algoritmos funcionam" arquiteturalmente verdadeiro (princípio #3, mecanismo vs política).

### 7.2 O op-set fechado de `BLOCK` (a interface, espelhando a vtable)

`BLOCK` expõe **exatamente** este conjunto fechado de operações — sem escotilha de fuga, sem canal lateral, sem `ioctl`. Toda função opera sobre **buffers fornecidos pelo chamador** (sem alocação escondida; princípio #5). A assinatura conceitual:

```
struct BlockCodec {
    // --- decode path (mecanismo puro, determinístico, bit-exato) ---
    fn init(*BlockState, *const BlockConfig, *const Toolkits) -> i32
    fn decode_tile(*BlockState, tile_index:u32,
                   *const u8 tile_bytes, tile_len:u64,
                   *u8 out_plane_buf, out_stride:u64,
                   *u8 scratch, scratch_len:u64) -> i32
    fn reconstruct_geometry(*const BlockConfig, *PartitionInfo) -> i32  // sizes p/ pré-alocar
    // --- encode path (política; pode buscar, mas emite stream válido) ---
    fn encode_tile(*BlockState, tile_index:u32,
                   *const u8 in_plane_buf, in_stride:u64,
                   *const EncodePolicy,
                   *u8 out_bytes, *u64 out_len,
                   *u8 scratch, scratch_len:u64) -> i32
    fn flush(*BlockState) -> i32
}
```

**Regras do contrato (invariantes obrigatórias):**

1. **`decode_tile` é uma função pura** de `(BlockConfig, tile_bytes, toolkits congelados)`. Mesmos bytes ⇒ mesmos pixels em qualquer CPU. Zero ponto-flutuante no caminho de decode normativo: toda dequantização, transformada inversa, predição, e filtro in-loop é **inteiro/fixo-ponto** com shifts e constantes declarados no spec (conformidade bit-exata por dump de pixels — ver §7.16).
2. **Nenhum modo é inferido por heurística de conteúdo no decode.** Partição, modo de predição, tipo/tamanho de transformada, deltas de quant, flags de filtro — **tudo é símbolo decodificado** do bitstream. O encoder decidiu (política); o decoder obedece (mecanismo).
3. **Política só no encoder.** Análise de conteúdo, RDO, busca de partição, escolha de máscara perceptual: tudo vive em `encode_tile`/`EncodePolicy` e **não** aparece no arquivo. O arquivo carrega só a *decisão*, não a *busca*.
4. **`encode` produz stream que `decode` lê** sem conhecimento de como foi escolhido — então um parser/RDO mais esperto entra sem mudar o formato.
5. **Falha alta.** Símbolo fora de faixa, offset fora do tile, profundidade de partição além do declarado, `codec_version` desconhecida ⇒ erro numerado loud (ver §7.17), **nunca** clamp silencioso nem pixel inventado.
6. **Memória limitada por tile.** Todo buffer (working-set do tile, dicionário de contexto, scratch da transformada, buffers de filtro) é dimensionado a partir de campos **declarados** em `BlockConfig`/`IHDR`/`ICOD` **antes** de tocar bytes (ver §7.15).

### 7.3 Onde `BLOCK` vive no container; o blob de config versionado

`ICOD` carrega `codec_id = 4`, `codec_version`, `is_lossless` (BLOCK pode declarar lossless via caminho WHT/IDTX — §7.8.4), `tile_w/tile_h/n_tiles`, e o blob **`params`** fechado e versionado. O layout de `params` é definido **inteiramente** por `(codec_id=4, codec_version)`; o container o trata como bytes opacos (mecanismo puro, espelha `av1C`/`hvcC`). Um leitor com `codec_version` desconhecida **falha loud** (`E_CSIF_CODEC_VERSION`), nunca adivinha.

O blob `params` de `BLOCK` é o **`BlockConfig`** (`BCFG`), little-endian, layout fixo, campos escalares `i64`/`u8` (gotcha de struct mista — usar largura uniforme por campo serializado):

#### 7.3.1 `BCFG` — cabeçalho de config do codec BLOCK

| Off | Size | Campo | Valores / faixa |
|---|---|---|---|
| 0x00 | 4 | `bcfg_magic` | `"BCFG"` |
| 0x04 | 2 | `bcfg_version` (u16) | espelha `codec_version` (validado igual) |
| 0x06 | 1 | `superblock_log2` (u8) | `6`=64×64, `7`=128×128 (enum fechado; outro = reject) |
| 0x07 | 1 | `min_block_log2` (u8) | `2`=4×4 .. `superblock_log2` (piso da árvore de partição) |
| 0x08 | 1 | `plane_count` (u8) | nº de planos codificados por BLOCK neste stream (1..4) |
| 0x09 | 1 | `chroma_subsample_x` (u8) | `0`/`1` (4:4:4 vs subamostrado em x); declarado, nunca inferido |
| 0x0A | 1 | `chroma_subsample_y` (u8) | `0`/`1` |
| 0x0B | 1 | `chroma_sample_position` (u8) | enum H.273 (co-sited/centered); declarado |
| 0x0C | 1 | `sample_format` (u8) | enum: `0`=U8,`1`=U10,`2`=U12,`3`=U16,`4`=F16,`5`=F32 (ver §7.14) |
| 0x0D | 1 | `tx_partition_enable` (u8) | `0`/`1` — árvore de transformada recursiva separada da de predição |
| 0x0E | 1 | `intra_mode_set` (u8) | enum fechado de qual subconjunto de modos intra está em uso (ver §7.6) |
| 0x0F | 1 | `tx_set` (u8) | enum fechado de qual subconjunto de transformadas está em uso (ver §7.7) |
| 0x10 | 8 | `base_q_idx` (i64) | índice base de quant (0 = lossless via WHT/IDTX; ver §7.8) |
| 0x18 | 1 | `aq_enable` (u8) | `0`/`1` — campo de quant adaptativa por bloco presente (ver §7.8) |
| 0x19 | 1 | `aq_field_block_log2` (u8) | granularidade do multiplicador AQ (ex. `3`=por 8×8) |
| 0x1A | 1 | `cfl_enable` (u8) | `0`/`1` — chroma-from-luma habilitado |
| 0x1B | 1 | `palette_enable` (u8) | `0`/`1` — palette mode intra habilitado (screen content) |
| 0x1C | 1 | `ibc_enable` (u8) | `0`/`1` — intra-block-copy habilitado (screen content) |
| 0x1D | 1 | `cdef_enable` (u8) | `0`/`1` — filtro CDEF in-loop habilitado |
| 0x1E | 1 | `lr_enable` (u8) | `0`/`1` — loop-restoration (Wiener / self-guided) habilitado |
| 0x1F | 1 | `cross_tile_pred` (u8) | `0`=tiles independentes (default), `1`=predição entre tiles declarada |
| 0x20 | 1 | `entropy_method_id` (u8) | seleciona o método no substrato `entropy/` (0=rANS-static, 1=CDF-adapt, 2=prefix) |
| 0x21 | 1 | `entropy_precision_log2` (u8) | log2(TOTAL) do coder (ex. `12`⇒TOTAL=4096) |
| 0x22 | 1 | `entropy_lane_count` (u8) | largura de interleave rANS (1/4/8/16/32) |
| 0x23 | 1 | `ctx_reset_per_tile` (u8) | `1` = contexto de entropia reseta no início de cada tile (default; ver §7.10) |
| 0x24 | 8 | `max_partition_depth` (i64) | profundidade máxima da árvore de partição (limite de memória/recursão) |
| 0x2C | 8 | `restoration_unit_log2` (i64) | tamanho da unidade de loop-restoration (ex. `6`=64×64..`8`=256×256) |
| 0x34 | 8 | `dc_subimage_ref` (i64) | índice de SubImage do DC/LF (Modular), ou `-1` se ausente (ver §7.9) |
| 0x3C | 8 | `aq_subimage_ref` (i64) | índice de SubImage do campo AQ (Modular), ou `-1` |
| 0x44 | 8 | `cc_subimage_ref` (i64) | índice de SubImage do mapa de correlação de cor (CfL/cross-color), ou `-1` |
| 0x4C | 8 | `pass_count` (i64) | nº de passes progressivos (1 = não-progressivo; ver §7.9) |
| 0x54 | … | `quant_matrix_table` | (opcional) matrizes de quant custom por frequência (ver §7.8.2); presença flag em bit |

Toda flag opcional tem bit de presença explícito; **ausência nunca implica default mágico** — um campo ausente é um valor declarado (princípio #1). `superblock_log2`, `intra_mode_set`, `tx_set`, `sample_format`, `chroma_sample_position` são **enums fechados**; valor fora da faixa = `E_CSIF_BCFG_ENUM` (reject loud).

### 7.4 Estrutura do bitstream do tile (visão geral, ordem normativa)

Cada tile é uma **unidade de decode independente** (quando `cross_tile_pred = 0`, o default): o coder de entropia reinicia no começo do tile, nenhuma predição/contexto atravessa a borda do tile, e o tile é endereçável por `TIDX` (`{offset:u64, length:u64}` por tile) para decode parcial/paralelo (princípio #5). A ordem de leitura **dentro** de um tile é normativa e totalmente determinada por `BCFG` + os campos abaixo (sem desempate implícito):

```
TILE BITSTREAM =
  [ TileHeader ]                       # §7.4.1
  [ PartitionTree ]                    # §7.5 — a árvore de partição (símbolos), em ordem de varredura Z (Morton) de superblocos
  [ for each leaf block, em ordem da árvore: ]
      [ IntraModeSymbols ]             # §7.6 — modo de predição + parâmetros (angle delta, CfL alpha, palette, IBC mv)
      [ TxPartition (se tx_partition_enable) ] # §7.7 — sub-árvore de transformada
      [ for each transform unit: ]
          [ TxTypeSymbols ]            # §7.7 — (type_h, type_v, size) explícitos
          [ CoeffTokens ]             # §7.10 — level-map + sign + EOB via substrato entropy
  [ DeltaQField (se aq_enable e inline) ]   # §7.8 — ou referenciado via aq_subimage_ref
  [ CdefParams (se cdef_enable) ]      # §7.11 — direções/forças por filter-block
  [ LrParams (se lr_enable) ]          # §7.12 — por restoration unit: NONE/Wiener/SGR + taps/weights
```

Os streams de entropia em si são endereçados por uma tabela `EOFF` (do substrato `entropy/`): um stream por tile por plano (e sub-streams literais/level/sign conforme o método), com offsets **declarados** — nenhum stream é encontrado por varredura. Cada stream é auto-contido (estado inicial próprio; reset de CDF se `ctx_reset_per_tile`).

#### 7.4.1 `TileHeader`

| Campo | Tipo | Significado |
|---|---|---|
| `tile_magic` | u32 = `"BTIL"` | sanidade/resync (princípio: marcadores explícitos, opt-in via `cdef`/resilience flag) |
| `tile_index` | u32 | índice do tile (validado contra `TIDX`) |
| `tile_w_px`, `tile_h_px` | u32, u32 | dimensões em pixels (último tile da linha/coluna pode ser cropado; explícito) |
| `delta_q_tile` | i32 | delta de q por-tile sobre `base_q_idx` (perceptual; explícito) |
| `crc32` | u32 | (se `checksum_algo != none` no header do arquivo) integridade do tile — corrupção localizada (§7.13) |

### 7.5 Particionamento de blocos (árvore recursiva, enum fechado)

Um superbloco (`superblock_log2`: 64×64 ou 128×128) é dividido por uma **árvore de partição recursiva**, decodificada **antes** de qualquer dado de bloco. O símbolo de partição em cada nó vem de um **enum fechado** — sem escotilha de fuga, totalmente enumerado como os op-sets fechados do kernel:

| Valor | Nome | Forma do split |
|---|---|---|
| 0 | `PART_NONE` | bloco inteiro, sem split |
| 1 | `PART_HORZ` | 2 sub-blocos meia-altura (W×H/2) |
| 2 | `PART_VERT` | 2 sub-blocos meia-largura (W/2×H) |
| 3 | `PART_SPLIT` | 4 quadrantes (W/2×H/2), recursivo |
| 4 | `PART_HORZ_A` | 1 topo W×H/2 + 2 base W/2×H/2 (4:1 A) |
| 5 | `PART_HORZ_B` | 2 topo W/2×H/2 + 1 base W×H/2 (4:1 B) |
| 6 | `PART_VERT_A` | 1 esq W/2×H + 2 dir W/2×H/2 |
| 7 | `PART_VERT_B` | 2 esq W/2×H/2 + 1 dir W/2×H |
| 8 | `PART_HORZ_4` | 4 fatias horizontais (W×H/4) |
| 9 | `PART_VERT_4` | 4 fatias verticais (W/4×H) |

A recursão termina quando o bloco atinge `min_block_log2` (4×4) ou quando o símbolo é `PART_NONE`. A profundidade é limitada por `max_partition_depth` (campo declarado) — exceder = `E_CSIF_PARTITION_DEPTH` (reject, limite de recursão/memória). A árvore é serializada **explicitamente** em ordem de varredura Z (Morton) dos superblocos e, dentro de cada superbloco, ordem fixa pai→filhos (topo-esq, topo-dir, base-esq, base-dir para `SPLIT`); **nenhuma** suposição de raster implícita. O símbolo de partição é codificado pelo substrato de entropia com contexto derivado do tamanho do bloco e das partições dos vizinhos já decodificados (causal). O conjunto resultante de **blocos-folha** define para cada um a forma exata (W×H, do conjunto fechado de formas que os splits acima produzem entre 4×4 e o superbloco, incluindo retangulares como 16×8, 8×32, 64×16 etc.). O leitor **nunca** adivinha tamanho de bloco — toda transformada de todo bloco é declarada.

### 7.6 Predição intra (op-set fechado de modos)

Cada bloco-folha prediz a partir de amostras **já reconstruídas** dos vizinhos topo/esquerda (causal — sem amostras futuras, memória limitada a algumas scanlines). O modo é um **símbolo decodificado explícito**, de um enum fechado; `intra_mode_set` em `BCFG` declara qual subconjunto está em uso (permite tiers de complexidade sem escotilha). O conjunto completo:

| Valor | Modo | Definição (todos os preditores vêm do toolkit `predict/`) |
|---|---|---|
| 0 | `DC` | média dos vizinhos topo+esquerda disponíveis |
| 1 | `PAETH` | escolhe topo/esq/topo-esq mais próximo do gradiente linear `p=A+B−C` |
| 2 | `SMOOTH` | interpolação quadrática entre bordas topo e esquerda |
| 3 | `SMOOTH_H` | interpolação horizontal |
| 4 | `SMOOTH_V` | interpolação vertical |
| 5..12 | `DIR_0..DIR_7` | 8 modos direcionais base; **delta de ângulo** explícito em passos de 3° (campo `angle_delta` ∈ [−3,+3] por modo direcional, fino 56-ângulos), com filtro de borda intra de 2/4-tap e upsampling para ângulos baixos — tudo fixo-ponto declarado |
| 13 | `CFL` | (croma) `predict_cfl(alpha)`: croma = `dc_chroma + alpha · (luma_reconstruído_AC subamostrado)`; `alpha` é símbolo assinado decodificado; só válido se `cfl_enable` |
| 14 | `PALETTE` | (screen content) tabela de cores explícita pequena (n_colors declarado) + índices por pixel; só se `palette_enable` |
| 15 | `IBC` | (screen content) intra-block-copy: copia um bloco anterior já reconstruído por um deslocamento `(dx,dy)` sinalizado, dentro do tile; só se `ibc_enable` |

O índice do modo é codificado com contexto derivado dos modos dos vizinhos. Para `DIRECTIONAL`, o `angle_delta` é um símbolo separado. Para `CFL`, `alpha` é símbolo assinado (zig-zag, do toolkit). Para `PALETTE`, a tabela e os índices são dados no bitstream (estrutura fechada; nada de side file). Para `IBC`, `(dx,dy)` é um deslocamento dentro do tile (validado ⊆ região já reconstruída do tile; fora = reject). **Nenhum modo é implicado por conteúdo no decode**: o decoder lê o índice e roda o preditor correspondente. Os preditores são o op-set fechado `predict/`, reusado por `MODULAR` (DRY).

### 7.7 Transformadas adaptativas (tipo × tamanho, op-set fechado)

Após a predição, o **resíduo** (bloco − predição) é transformado. `BLOCK` usa o **op-set fechado de transformadas** do toolkit `transform/`, com a tupla `(type_h, type_v, size)` **codificada explicitamente** por unidade de transformada — nunca inferida.

**Tipos (separáveis — uma transformada 1-D por eixo, então `ADST_V × DCT_H` é legal):**

| Valor | Tipo | Uso |
|---|---|---|
| 0 | `DCT` | DCT-II/III, compactação de energia geral |
| 1 | `ADST` | transformada senoidal assimétrica — casa a estatística unilateral do resíduo intra (erro cresce afastando da borda predita) |
| 2 | `FLIPADST` | ADST espelhada (caso mirror) |
| 3 | `IDTX` | identidade / sem transformada espacial — screen content, bordas sintéticas |

**Tamanhos:** retangulares de 4×4 até 64×64 (4×4, 8×8, 16×16, 32×32, 64×64, e retangulares 4×8, 8×4, 8×16, 16×8, 16×32, 32×16, 32×64, 64×32, e os 1:4 4×16, 16×4, 8×32, 32×8), selecionados por uma **árvore de transformada recursiva** (`TxPartition`) que pode ser **menor** que o bloco de predição quando `tx_partition_enable = 1`. O conjunto `(type_h, type_v)` permitido por tamanho é **context-pruned** por um conjunto fechado declarado por `tx_set` (ex.: blocos grandes restringem a DCT×DCT; pequenos permitem o conjunto cheio) — a poda é parte do spec, não escolha de implementação.

**Caminho lossless (§7.8.4):** quando `base_q_idx = 0` e `is_lossless = 1`, a transformada é **WHT 4×4** (Walsh-Hadamard, inteira, perfeitamente invertível) ou `IDTX`, dando reconstrução exata; predição + WHT/IDTX + entropia lossless = matematicamente sem perda. Mesmo registro, **flag explícita**, sem "formato lossless" separado.

As constantes de base, o escalonamento e o arredondamento fixo-ponto de cada transformada são **declarados no spec** (§7.16), garantindo decode bit-exato e reproduzível em qualquer CPU. Sem alocação dentro das transformadas — operam sobre buffers de tamanho fixo do chamador (memória limitada). O codec `DCT` (id 3) usa o subconjunto DCT 8×8 deste **mesmo** toolkit (DRY).

### 7.8 Quantização adaptativa (perceptual, totalmente declarada)

#### 7.8.1 Quant base + deltas explícitos

A quantização é **dado explícito**: `base_q_idx` (em `BCFG`), `delta_q_tile` (em `TileHeader`), deltas DC/AC por plano (em `BCFG`/`TileHeader`), e um **campo de delta-Q por bloco** (AQ). O step de dequant vem de uma **tabela `q_idx → step` declarada no spec** (sem dequant mágico). O op `dequant(coeff, q_idx, plane)` é compartilhado com `DCT` (id 3) via o toolkit de quant (DRY).

#### 7.8.2 Matrizes de quantização custom por frequência

Quando usadas, matrizes de quant custom (peso por coeficiente, estilo JPEG) são **carregadas explicitamente** em `quant_matrix_table` (`BCFG`), nunca assumidas. Cada matriz é declarada por (tamanho de transformada, plano).

#### 7.8.3 Campo AQ (quant adaptativa por bloco) — SubImage declarada

O multiplicador de quant por bloco é uma **SubImage declarada** com papel `role = QUANT_FIELD`, codec próprio (`MODULAR`), referenciada por `aq_subimage_ref` em `BCFG` (ou inline no bitstream do tile via `DeltaQField` quando `aq_enable` e a flag inline está setada). Granularidade = `aq_field_block_log2` (ex.: por 8×8). O step efetivo por bloco = `tabela_base[q_idx] · multiplicador_bloco`. O decoder **lê dois valores declarados e multiplica** — zero heurística no decode. A heurística de masking (luminance/contrast/texture masking) que **produziu** o campo é política do encoder (toolkit `perceptual/`, função `aq_field(tile, params)`); o **layout** do campo é mecanismo declarado. Isto é o seam política/mecanismo limpo: o decode é mecanismo puro lendo campos declarados (§7.1, princípio #3).

#### 7.8.4 Lossless dentro da mesma família

`is_lossless = 1` + `base_q_idx = 0` ativa o caminho reversível: predição intra exata + WHT-4×4/IDTX + entropia lossless, bit-exato. O container não assume nada; o codec declara. DRY com `MODULAR` (id 2, o codec lossless-forte) — `BLOCK` pode declarar lossless via WHT/IDTX, mas a recomendação é que conteúdo verdadeiramente lossless use `MODULAR`. A invariante do container: `is_lossless=1` ⇒ o decode round-trip deve ser exato (bit-pattern preservado, incl. faixa declarada).

### 7.9 Decode progressivo/responsivo (passes declarados; DC como SubImage/thumbnail)

`BLOCK` é progressivo **por construção**, não bolt-on. O `pass_count` (`BCFG`) declara N passes; o índice `ITOC`/`PassTable` declara os ranges de byte de cada pass — **pontos de truncamento são DECLARADOS, não descobertos**. Estrutura:

- **Pass 0 = DC/LF.** Os valores DC por bloco formam uma imagem 8× downscalada, armazenada como **SubImage Modular** referenciada por `dc_subimage_ref` (`BCFG`). Ela é (a) o primeiro pass progressivo, (b) um preview/thumbnail utilizável. O chunk `THUM` **pode** referenciar essa SubImage DC (campo declarado `thumbnail source = embedded DC sub-image at level L`) em vez de duplicar bytes (DRY — não armazenar o mesmo low-res duas vezes). A escolha é campo declarado, nunca inferida.
- **Passes 1..N = refinamento AC.** Cada pass adiciona planos de bit / aproximação sucessiva de coeficientes AC. Cada pass é uma unidade `ITOC` (com `pass_index` e `decode_dependency_mask` apontando o DC).

Um decoder lendo só o pass 0 de todos os tiles obtém um frame coarse completo. O leitor sabe pelo header **quantos** passes existem e **onde** cada um termina (auto-descritivo). Sem "tenta decodificar e vê até onde vai" — truncamento num limite de pass é estado de primeira classe declarado. Mapas de correlação de cor (CfL global / cross-color) também são SubImages Modular declaradas (`cc_subimage_ref`), servindo o mesmo motor de entropia/predição (unificação JXL-style, DRY).

### 7.10 Contextos de entropia por tile (substrato compartilhado)

`BLOCK` **não** define coder de entropia — usa o substrato `entropy/` via `entropy_method_id` (`BCFG`). Coeficientes são codificados como **level-map** (is-nonzero, base-range, high-range escape via Exp-Golomb), mais **sign** e **EOB** (end-of-block position), **cada um com seu contexto**. A **seleção de contexto** é a parte de maior ganho:

- **Função de contexto (política, no codec, declarada no spec):** para um nível de coeficiente, o contexto bruto é derivado de — soma dos níveis de vizinhos já decodificados, posição no bloco (banda de frequência), tamanho de transformada, plano. Para o símbolo de partição, do tamanho do bloco + partições vizinhas. Para o modo intra, dos modos vizinhos. **Toda derivação é causal** (sem pixel futuro), mantendo memória limitada a poucas scanlines.
- **Mapeamento (mecanismo, no substrato):** o `ctx_id` bruto passa por um `context_map` clusterizado (transmitido como dado declarado) → `cluster_id` → distribuição (CDF/histograma rANS). O número de clusters K é campo declarado. A regra de adaptação de CDF (no modo `entropy_method_id=1`) é constante congelada no spec (bit-exata).
- **Por tile:** quando `ctx_reset_per_tile = 1` (default), CDFs e estado do coder **resetam** no início de cada tile, garantindo independência (contenção de erro + decode parcial). A tabela `EOFF` dá um stream de entropia por tile por plano (e sub-streams), com offsets declarados — nenhum stream é varrido. Mapeia direto no tiling do container (princípio #5).

A frente de **hybrid-integer-token** do substrato (`split_exponent, msb_in_token, lsb_in_token`, declarados) permite que um alfabeto ANS pequeno carregue resíduos de 16/32-bit (HDR), mantendo histogramas pequenos. `BLOCK` reusa isso — não reinventa (DRY).

### 7.11 Filtro in-loop CDEF (deringing direcional)

Quando `cdef_enable = 1`, CDEF roda **após** a reconstrução, com ordem fixa declarada (CDEF antes de Loop Restoration). Por bloco 8×8: estima a **direção dominante de borda** (1 de 8) minimizando variância ao longo de linhas candidatas, então aplica um filtro não-linear com **força primária** (ao longo da borda) e **força secundária** (45° off), com forças sinalizadas por filter-block. Parâmetros (`CdefParams` no bitstream do tile): por filter-block, `{direction:u8, primary_strength, secondary_strength, damping}` — **todos explícitos**. O op `cdef_apply(strengths)` opera sobre buffers fixos. Se `cdef_enable = 0`, o decoder **não faz nada** — sem pós-processamento implícito; reprodutibilidade exata. Um leitor sabe o pipeline de pós-filtro inteiro só pelos headers.

### 7.12 Loop Restoration (Wiener / self-guided)

Quando `lr_enable = 1`, Loop Restoration roda por **restoration unit** (tamanho `restoration_unit_log2`, ex. 64×64..256×256), **após** CDEF. Por unidade, seleciona explicitamente (símbolo decodificado):

| Valor | Filtro | Parâmetros declarados |
|---|---|---|
| 0 | `LR_NONE` | — |
| 1 | `LR_WIENER` | filtro FIR separável simétrico 7-tap; os taps são sinalizados (`wiener_taps`) |
| 2 | `LR_SGR` (self-guided) | dois passes de box-filter (guided), combinados com dois pesos sinalizados (`sgr_weights`) + raios declarados |

Os ops `wiener_apply(taps)` / `sgr_apply(weights, radii)` operam sobre buffers fixos. Ordem e enable são **declarados por tile** no bitstream do codec — o container **nunca** roda um filtro; o codec declara, no próprio bitstream, exatamente quais filtros rodam e com que parâmetros (mecanismo/política). Filtro off ⇒ decoder não faz nada; reprodutibilidade exata.

### 7.13 Cor, HDR e canais auxiliares (disparados, não redefinidos)

`BLOCK` **dispara** a maquinaria de cor/HDR do container; não a redefine:

- **CICP/cor:** o `matrix_coefficients` declarado em `COLR`/`IHDR` diz ao toolkit `color/` qual matriz RGB↔YCbCr/YCgCo-R/XYB usar. `BLOCK` opera no espaço declarado (ex.: XYB para lossy perceptual, ou YCbCr conforme matrix code point). **Nunca** embute BT.601/sRGB implícito. `BLOCK` valida que `matrix_coefficients` é consistente com `channels`/`plane_count` (RGB⇒matrix=0 identity; YCbCr⇒matrix≠0), senão reject loud.
- **HDR:** `sample_format` ∈ {U10,U12,U16,F16,F32} é declarado em `BCFG`; o caminho lossy aceita float (pipeline DWA-class: YCoCg/XYB + DCT em dados lineares) e a transferência (PQ/HLG/linear) é o code point declarado em `COLR` — `BLOCK` não trata PQ/HLG como modo especial, só aplica a função de transferência nomeada. Metadados de volume de cor (MDCV/MaxCLL/MaxFALL) viajam em `IHDM` (skippable) — descritivos, nunca consumidos pela matemática de decode de `BLOCK`.
- **Auxiliares (alpha/depth/gain-map):** são **itens/SubImages auxiliares declarados** (`IAUX`/`AUX_OF`), cada um um plano monocromático independente que pode escolher seu próprio codec (incluindo `BLOCK` ou `MODULAR`), bit-depth e lossless — `BLOCK` os codifica como qualquer plano via o **mesmo** seam vtable (DRY). Alpha não é canal interleaved fixo: é companheiro declarado, premultiplicação é flag explícita por-aux.
- **Integridade:** quando `checksum_algo ≠ none` no header do arquivo, cada tile carrega `crc32` (em `TileHeader`); corrupção é **localizada** ao tile (tiles independentes), reportada loud por `(tile_index)`, o resto decodifica (resultado parcial honesto, nunca lixo silencioso).

### 7.14 Formato de amostra e endianness

`sample_format` (`BCFG`) é enum fechado {U8,U10,U12,U16,F16,F32}. Float é IEEE 754 binary16/binary32 (declarado). Endianness é a do container (little-endian, declarada no header do arquivo — nunca assumida). Profundidade intermediária das transformadas/filtros é **declarada por `sample_format`** (precisão intermediária maior para evitar overflow), bit-exata. Um codepath por `sample_format` por operação (DRY). Para lossless, o codec preserva o bit-pattern exato (incl. NaN/Inf/−0 para float); para lossy, o spec declara o tratamento de não-finitos.

### 7.15 Memória limitada (pré-dimensionável a partir de campos declarados)

Antes de tocar qualquer byte de pixel, um decoder calcula seu working-set inteiro a partir de campos declarados:

- **Buffer do tile:** `tile_w_px × tile_h_px × plane_bytes(sample_format)` por plano. Decode tile-a-tile ⇒ memória = um tile, não a imagem.
- **Árvore de partição:** limitada por `max_partition_depth` (campo) e `superblock_log2`.
- **Contexto de entropia:** `K_clusters × (SYMS+1)` entradas de CDF (modo adaptativo), `K` declarado; alocado uma vez do scratch do chamador.
- **Scratch de transformada:** maior tamanho de TU declarado (até 64×64) — buffer fixo.
- **Buffers de filtro:** restoration unit (`restoration_unit_log2`) + margem CDEF — declarados.
- **Palette/IBC:** `n_colors` da palette e o window do IBC são limitados pelo tile.

`reconstruct_geometry()` retorna esses tamanhos antes do decode (princípio #5; espelha a disciplina do loader CSE que rejeita `mem_size < file_size` e dimensiona antes de copiar). Nenhuma alocação escondida; tudo no buffer do chamador.

### 7.16 Determinismo e conformidade

O decode de `BLOCK` é **bit-exato**: toda dequant, transformada inversa (IDCT/IADST/IWHT/IDTX), predição intra, e filtro in-loop (CDEF/Wiener/SGR) é inteiro/fixo-ponto com constantes, shifts e regras de arredondamento **congeladas no spec** (numeradas como o algoritmo do loader em CSE_FORMAT.md). Consequência: a **conformidade do decoder é por dump de pixels** (igualdade bit-exata contra imagens de referência), não "parece igual". A conformidade do encoder (opcional) checa que o `achieved_value` (do chunk `IQMT`, métrica perceptual declarada) cai na banda do `target_value`. Um corpus de vetores congelados (entradas + dumps de pixel de referência + um corpus de corrupção com o código de erro esperado por entrada malformada) acompanha o codec e roda pelo harness estilo `verify.sh`. Nenhum decoder oco passa: tem que bater pixel-exato.

### 7.17 Códigos de erro (falha loud, estilo CSE)

`BLOCK` retorna códigos numerados negativos (errno causticos), nunca clamp/adivinha:

| Código | Nome | Condição |
|---|---|---|
| −1 | `E_CSIF_BCFG_MAGIC` | `bcfg_magic ≠ "BCFG"` |
| −2 | `E_CSIF_CODEC_VERSION` | `codec_version`/`bcfg_version` desconhecida ou inconsistente |
| −3 | `E_CSIF_BCFG_ENUM` | enum fechado fora da faixa (`superblock_log2`, `intra_mode_set`, `tx_set`, `sample_format`, …) |
| −4 | `E_CSIF_PARTITION_DEPTH` | profundidade da árvore excede `max_partition_depth` |
| −5 | `E_CSIF_PARTITION_SYM` | símbolo de partição fora do enum fechado |
| −6 | `E_CSIF_INTRA_MODE` | índice de modo intra fora do conjunto declarado por `intra_mode_set`, ou modo usado sem seu enable (ex. CFL sem `cfl_enable`) |
| −7 | `E_CSIF_TX_TUPLE` | `(type_h,type_v,size)` fora do `tx_set` permitido para o tamanho |
| −8 | `E_CSIF_IBC_RANGE` | deslocamento IBC aponta fora da região já reconstruída do tile |
| −9 | `E_CSIF_COEFF_RANGE` | token de coeficiente fora da faixa do `entropy_precision_log2` |
| −10 | `E_CSIF_TILE_OFFSET` | offset/length do tile (via `TIDX`) fora do IDAT |
| −11 | `E_CSIF_TILE_CRC` | `crc32` do tile não bate (corrupção localizada) |
| −12 | `E_CSIF_COLOR_MATRIX` | `matrix_coefficients` inconsistente com `channels`/`plane_count` |
| −13 | `E_CSIF_LOSSLESS_INVARIANT` | `is_lossless=1` mas `base_q_idx ≠ 0` / transformada não-reversível declarada |
| −14 | `E_CSIF_CODEC_UNIMPLEMENTED` | slot honesto não implementado nesta build (loud; nunca pixel falso) |

### 7.18 Síntese de grão de filme (parâmetros; op pós-decode declarado)

Grão de filme é de alta entropia: codificá-lo direto destrói compressão. `BLOCK` adota o padrão **denoise-no-encode + ressíntese-no-decode**, totalmente paramétrico e determinístico. Os parâmetros vivem no chunk **`IGRN`** (skippable — um leitor que o ignora mostra a imagem limpa, honesto e não-quebrado), não no bitstream do codec; a síntese é um **op de toolkit fechado** `grain_synthesize(model, intensity_plane)` que escreve num buffer do chamador (limitado, sem alocação escondida), aplicado **após** o decode inverso e os filtros in-loop. `BLOCK` declara em `BCFG` (bit) se espera grão (consistência: o encoder que denoise-ou deve emitir `IGRN`).

#### 7.18.1 `IGRN` — modelo de grão (campos explícitos, fixo-ponto)

| Campo | Tipo | Significado |
|---|---|---|
| `grn_magic` | u32 = `"IGRN"` | |
| `seed` | u16 | semente do PRNG (síntese determinística) |
| `prng_algo` | u8 | enum fechado do PRNG **nomeado e especificado no spec** (saída bit-reproduzível em todo decoder) |
| `ar_coeff_lag` | u8 | lag do processo autoregressivo (0..3) |
| `ar_coeffs_y[]` | i8[] | coeficientes AR de luma (comprimento = f(lag), declarado) |
| `ar_coeffs_cb[]`, `ar_coeffs_cr[]` | i8[] | coeficientes AR de croma (presentes se `chroma_scaling_from_luma=0`) |
| `scaling_points_y[][2]` | u8[][2] | LUT piecewise-linear intensidade-de-luma → amplitude de grão |
| `scaling_points_cb/cr[][2]` | u8[][2] | LUT por croma |
| `scaling_shift` | u8 | shift fixo-ponto da escala |
| `chroma_scaling_from_luma` | u8 | `0`/`1` — deriva escala de croma da luma |
| `cb_mult, cb_luma_mult, cr_mult, cr_luma_mult` | i16 ×4 | multiplicadores chroma-from-luma |
| `overlap_flag` | u8 | `0`/`1` — overlap entre blocos de grão (suaviza costuras) |
| `grain_block_log2` | u8 | tamanho do template de grão (ex. `6`=64×64) |
| `clip_to_restricted` | u8 | `0`/`1` — clip à faixa estudio vs cheia (declarado) |

A recorrência AR e o PRNG são **fixos no spec** (mesma semente + coeffs ⇒ mesmo grão em todo lugar; nada de aleatoriedade mágica). O decoder regenera um template de grão `grain_block` a partir de `seed`+AR, escala por intensidade local via a LUT piecewise-linear, e adiciona após a reconstrução. **Opt-in e declarado por imagem**; sem estado escondido. A conformidade inclui dumps pré-grão (base) e pós-grão (para decoders grain-aware), ambos bit-exatos.

### 7.19 Resumo das invariantes de honestidade (checklist do princípio Caustic)

| Princípio | Como `BLOCK` o satisfaz |
|---|---|
| #1 Explícito, sem mágica | Partição, modo intra, tupla de transformada, deltas de quant, campo AQ, direções/forças CDEF, taps Wiener/SGR, passes, grão — **tudo símbolo/campo decodificado**; enums fechados; endianness/sample_format/cor declarados; "unspecified" proibido em cor. |
| #2 Op-set fechado honesto | `{init, decode_tile, reconstruct_geometry, encode_tile, flush}`, sem ioctl, sem canal lateral; enums de partição/modo/transformada/filtro fechados e completos. |
| #3 Mecanismo vs política | Container despacha por `codec_id` (mecanismo); `BLOCK` é política de compressão; **dentro** de `BLOCK`, decode = mecanismo (lê campos), encode/RDO/masking = política (não aparece no arquivo). |
| #4 Sem workaround/fake | Decode bit-exato ou `E_CSIF_CODEC_UNIMPLEMENTED` loud; nunca decoder falso; corpus de conformidade prova o slot honesto. |
| #5 Memória limitada | Tudo pré-dimensionado de campos declarados; decode tile-a-tile; buffers do chamador; profundidade de partição/restoration unit/contexto declarados; `reconstruct_geometry()` antes de qualquer byte. |
| #6 DRY | Reusa `entropy/` (rANS+contexto+hybrid-token), `transform/` (DCT/ADST/FLIPADST/IDTX/WHT), `color/` (matriz por CICP), `predict/` (op-set intra), `perceptual/` (AQ/RDO); compartilha dequant/quant-matrix com `DCT` (id 3). |
| #7 Família de formatos | `BCFG` segue o estilo magic+version+campos fixos little-endian de CSE/CSIF; chunks `IGRN`/`IHDM` skippable forward-compat; tabelas `TIDX`/`EOFF`/`ITOC` espelham a segment-table do CSE. |
| #8 Estende o toolkit | Onde falta capacidade (ex. ADST fixo-ponto, CDEF, SGR), estende os toolkits compartilhados com ops fechados reusáveis, em vez de hack local. |

---

The specification for section 7 is complete above. It is the literal spec content (clean markdown, starting with the `## 7.` heading), exhaustive and byte-exact where applicable, strictly within the Caustic philosophy.

Key load-bearing design decisions made (for the parent agent assembling the full CSIF spec, to keep cross-section consistency):

- **`codec_id = 4 = BLOCK`**, blob `params` = **`BCFG`** struct (magic `"BCFG"` + version-gated layout, little-endian, `i64`/`u8` fields per the mixed-width-struct miscompile gotcha).
- **Closed op-set**: `{init, decode_tile, reconstruct_geometry, encode_tile, flush}` — decode is a pure deterministic function (zero float in the normative path; bit-exact).
- **Tile bitstream order** is normative: `TileHeader → PartitionTree → per-leaf {IntraMode, TxPartition, TxType, CoeffTokens} → DeltaQField → CdefParams → LrParams`. New chunk/table names this section assumes from siblings: `TIDX` (per-tile offset index), `EOFF` (entropy stream offsets), `ITOC`/`PassTable` (progressive ranges), `SubImage` descriptor (DC/LF, QUANT_FIELD, color-correlation), `IAUX`/`AUX_OF`, `COLR`/CICP, `IHDM` (HDR volume), `IGRN` (film grain), `IQMT` (quality metric).
- **Film grain** is specced as the skippable `IGRN` chunk + a toolkit op (NOT in the codec bitstream), to keep it opt-in/forward-compat.
- **Honest slot**: returns `E_CSIF_CODEC_UNIMPLEMENTED` (−14), never a fake decoder. Full numbered error table (−1..−14) in §7.17, CSE-loader style.
- Everything (partition enum, ~16 intra modes, transform tuple, AQ field, CDEF/LR params, passes) is a **decoded symbol** — no decode-time heuristics; encoder-side RDO/masking is policy that never appears in the file.

This file was returned inline as the answer (no spec .md file was written, per instructions). If the parent wants it persisted, the canonical location matching the repo convention would be `/home/caua/Documentos/Projetos-Pessoais/causticos/docs/CSIF_FORMAT.md` (sibling of `docs/CSE_FORMAT.md`).

---

I have the family conventions. Now I have everything I need to write section 8. The dossier gives me the substance; CSE_FORMAT.md gives me the house style (header tables with Off/Size/Field/Value, little-endian, fail-loud loader algorithm, frozen-at-self-host, version+flags+TLV). Let me write the spec section.

## 8. Codec NEURAL (aprendido) + runtime

> **Status: real interface slot, sequenced behind a technical blocker.**
> This section specifies `codec_id = 5` (**NEURAL**) *completely* — the
> bitstream, the `ICOD.params` model descriptor, the runtime contract, and the
> determinism rules — so that the moment a conformant **CSIF Inference Runtime
> (CIR)** exists, a NEURAL decoder is buildable byte-for-byte from this text
> with zero open questions. It does **not** ship a built-in autoencoder, and
> the reference decoder MUST refuse a NEURAL stream with `E_CSIF_NO_RUNTIME`
> (see §8.11) until a CIR is registered. This is honest sequencing, **not** a
> fake decoder (philosophy rule 4): the interface is closed and complete now;
> the *policy* (the learned weights + tensor program) plugs in later. The real
> blocker is real: a learned codec is undecodable without a deterministic
> tensor-execution engine, and CSIF has not yet built one. We specify it; we
> gate it; we never stub it green.

---

### 8.1 What a learned codec is, in CSIF terms

A learned (neural) image codec is, like every other CSIF codec, **POLICY over
the shared MECHANISM**. The container does not know it is neural — it dispatches
to `codec_id = 5` exactly as it dispatches to MODULAR (2) or DCT (3), handing
the codec its tile bytes, the shared toolkit, and the declared
`ICOD.params`. The neural-ness lives entirely inside the codec.

The decode pipeline of a learned codec is split into **three honest stages**,
and CSIF makes all three explicit so nothing is magic:

1. **Entropy stage (MECHANISM, shared).** The latent payload and the
   side-information ("hyperprior") are **not** coded by a private neural
   entropy coder. They are coded by the **shared rANS entropy substrate**
   (`entropy_method_id = 0`, the static interleaved rANS of the Entropy
   section), driven by per-symbol probability parameters that the synthesis
   network *computes*. This is the decisive Caustic move: the learned model
   produces **probabilities**, and the *declared, frozen, integer-exact* rANS
   produces **bytes**. No learned arithmetic coder, no float-in-the-coding-loop.

2. **Inference stage (POLICY, runtime).** A deterministic tensor program
   (the decoder/synthesis transform `g_s` and the hyper-synthesis `h_s`) runs
   on the **CIR** to turn quantized integer latents into (a) the entropy
   parameters consumed by stage 1 and (b) the reconstructed sample tensor.

3. **Output stage (MECHANISM, shared).** The reconstructed tensor is mapped
   into the file's declared channels / bit-depth / colorspace using the
   **shared color + transform toolkit**, identical to every other codec. A
   learned codec never invents its own colorspace handling; IHDR's declared
   `ColorEncoding` is authoritative.

The container–codec seam is the **same uniform `{decode, encode}` vtable**
(mirroring the kernel's KObject vtable). NEURAL adds **no new container path**.

```
NEURAL.decode(tile_bytes, params, toolkit, out_tensor):
    1. parse NEURAL tile header  (§8.6)
    2. rANS-decode the hyper-latent ẑ           (shared entropy, ctx = declared)
    3. CIR.run(h_s, ẑ) -> entropy params Φ      (deterministic tensor program)
    4. rANS-decode the main latent ŷ using Φ    (shared entropy)
    5. CIR.run(g_s, ŷ) -> reconstructed tensor  (deterministic tensor program)
    6. shared color/transform -> out_tensor in IHDR's declared sample space
```

Step 2's reverse is the classic **hyperprior**: a tiny second latent `ẑ` is
coded under a *learned but image-independent* factorized prior (a declared CDF
table), then expanded by `h_s` into the per-element probability parameters `Φ`
(e.g. mean+scale of a Gaussian, or a discretized mixture) used to code the main
latent `ŷ`. Everything `Φ` touches is fed to the **shared** rANS — `Φ` only
*selects the distribution*, exactly as a context does for any other codec.

---

### 8.2 Why it is sequenced behind a runtime (the real blocker)

A NEURAL decoder cannot exist without a tensor-execution engine that is:

- **deterministic and bit-exact** across CPUs, build flags, and `-smp` widths
  (a learned codec that decodes to slightly different pixels on two machines is
  not a format — it fails the conformance contract of the Metrics/Conformance
  section). Floating-point matmul/convolution are **not** bit-reproducible in
  general (FMA contraction, reduction order, denormal handling, transcendental
  rounding), so the runtime MUST be **integer / fixed-point** with a
  fully-specified arithmetic, or it is unusable here.
- **bounded and non-allocating at decode** (philosophy rule 5): tile-sized
  working tensors, declared up front, no hidden heap growth.
- **complete** enough to run the declared operator set (§8.8).

causticos has **not** built such a runtime. Building it is a foundation task
(toolchain-before-feature, per the project's no-deferring rule applied
honestly: you close the *design* now, you build the *foundation* before the
feature). Therefore NEURAL is specified in full and **gated off** at the
decoder until a CIR registers. This is identical in spirit to how BLOCK (4) is
a real-but-later slot: the seam is frozen; the engine arrives on its own clock.

The encoder side is **encoder policy** and may exist independently (training +
quantizing weights happens off-target, like any RDO search); but a CSIF file
carrying `codec_id = 5` is only *renderable* where a CIR is present, and the
file says so explicitly (§8.5, `runtime_required`).

---

### 8.3 Position in the registry and conformance

| Field | Value |
|---|---|
| `codec_id` | `5` |
| name | `NEURAL` |
| closed op-set | `{ decode, encode }` (no `reconstruct_source`, no side channel) |
| `is_lossless` | declared per-image in ICOD; **MAY** be `1` (see §8.10) |
| sample types supported | declared in the model descriptor (§8.5); a CIR MUST honor exactly those; unsupported sample type ⇒ honest `E_CSIF_UNSUPPORTED`, never silent down-conversion |
| profile | **FULL** only (the BASELINE profile of the Conformance section excludes NEURAL). A BASELINE decoder hitting `codec_id = 5` fails with `E_CSIF_PROFILE` *before* any allocation. |

NEURAL participates in the **same** bounded-decode invariants as every codec:
its tiles are independently decodable (entropy context reset per tile), its
working memory is computed from declared fields before decode, and it is
addressed through the container's tile index (`TIDX`) like any other codec.

---

### 8.4 The container–codec seam: NEURAL changes nothing structural

NEURAL reuses, without modification:

- **ICOD** (`codec_id`, `codec_version`, `is_lossless`, `tile_w`, `tile_h`,
  `n_tiles`, `params`). The `params` blob is the **closed, codec-owned,
  versioned model descriptor** of §8.5; the container treats it as opaque
  bytes and never parses it (pure mechanism, KObject-vtable analogy).
- **TIDX** (per-tile offset/length index) for parallel/partial decode.
- The shared **entropy** substrate (rANS) for the latent and hyper-latent
  payloads — NEURAL declares `entropy_method_id = 0` and MUST NOT introduce a
  new entropy method.
- The shared **color** + **transform** toolkit for the output stage.
- IHDR's declared **ColorEncoding**, **channels**, **bit_depth/sample_format**,
  **endianness** — all authoritative; the model descriptor MUST be *consistent*
  with them (§8.5) and the loader rejects inconsistency loudly.

The **only** addition NEURAL requires anywhere outside its own `params` is one
optional, skippable chunk, **`IMDL`** (§8.5.3), used **only** when model weights
are referenced out-of-file by content hash. When weights are embedded, no new
chunk is needed.

---

### 8.5 `ICOD.params` for NEURAL — the model descriptor

`ICOD.params`, when `codec_id = 5`, is a **NEURAL Model Descriptor (NMD)**:
a fully-declared, fixed-then-TLV structure. Its layout is owned by
`(codec_id = 5, codec_version)` (the Conformance section's per-codec versioned
config contract). All multi-byte fields are **little-endian** (declared, never
assumed — matches CSE and the rest of CSIF). All scalar fields are `i64`-width
in memory per the Caustic mixed-width-struct gotcha, but are stored in the file
at the byte widths given below and widened on read.

#### 8.5.1 NMD fixed header (64 bytes)

| Off | Size | Field | Notes |
|---|---|---|---|
| 0x00 | 4 | `nmd_magic` | `"NMD1"` (4E 4D 44 31) — self-identifies the descriptor; loud reject on mismatch |
| 0x04 | 2 | `nmd_version` (u16) | descriptor layout version; gated by `codec_version` |
| 0x06 | 2 | `flags` (u16) | bit0 `weights_embedded`, bit1 `weights_referenced`, bit2 `runtime_required` (always 1 for NEURAL), bit3 `lossless_residual_present` (§8.10), bit4 `tiled_latent` (latent is itself tiled to the container tiles) |
| 0x08 | 4 | `model_id` (u32) | a **declared, registered** model-family id (closed registry, §8.5.4); unknown ⇒ `E_CSIF_UNKNOWN_MODEL` (loud, no guess) |
| 0x0C | 4 | `model_version` (u32) | exact trained-weights version within the family; pinned, not "compatible-ish" |
| 0x10 | 32 | `weights_digest` | BLAKE3-256 of the canonical weights blob (§8.5.5). MUST match the embedded or referenced weights, or `E_CSIF_WEIGHTS_DIGEST` |
| 0x30 | 1 | `arith` (u8) | runtime arithmetic id: `1 = INT8xINT32-accum fixed-point` (the only value defined for `nmd_version 1`); other ⇒ `E_CSIF_UNSUPPORTED` |
| 0x31 | 1 | `sample_format` (u8) | declared model I/O sample format (UINT8/10/12/16, FLOAT16/32) — MUST equal IHDR's, else `E_CSIF_INCONSISTENT` |
| 0x32 | 1 | `channels` (u8) | model output channel count — MUST equal IHDR channel count |
| 0x33 | 1 | `color_space_tag` (u8) | the colorspace the *model operates in* (e.g. learned XYB-like, or RGB-linear); the output stage converts from this to IHDR's declared ColorEncoding via the shared color toolkit; **declared, never inferred** |
| 0x34 | 2 | `latent_channels` (u16) | C of the main latent ŷ |
| 0x36 | 2 | `hyper_channels` (u16) | C of the hyper-latent ẑ |
| 0x38 | 1 | `latent_stride_log2` (u8) | downsampling factor of ŷ vs pixels (e.g. 4 ⇒ /16 each axis) |
| 0x39 | 1 | `hyper_stride_log2` (u8) | downsampling of ẑ vs ŷ |
| 0x3A | 1 | `entropy_param_kind` (u8) | distribution family for ŷ: `0 = Gaussian(mean,scale)`, `1 = GaussianMixture-K`, `2 = Laplacian(scale)`, `3 = categorical-LUT`; **closed enum** |
| 0x3B | 1 | `mixture_k` (u8) | K for `entropy_param_kind = 1`, else `0` |
| 0x3C | 4 | `tlv_bytes` (u32) | total length of the TLV section that follows |

The fixed header is followed by `tlv_bytes` of **TLV records** describing the
tensor program, the quantization, and the bounded-memory budget. Every record
is `{ rec_type:u32, rec_len:u32, payload[rec_len] }`, little-endian, and
unknown `rec_type` is a **hard error for NEURAL** (the tensor program is
load-bearing — it cannot be skipped and still decode correctly; this mirrors
the lossless-transform rule that a missing transform is fatal, not skippable).

#### 8.5.2 NMD TLV record types (closed set, `nmd_version 1`)

| `rec_type` | Name | Payload (all little-endian) |
|---|---|---|
| `0x01` | `GRAPH` | the deterministic tensor program: a topologically-ordered op list (§8.8). Each op = `{ op_code:u16, n_in:u8, n_out:u8, in_ids[], out_ids[], attr_len:u32, attrs[] }`. Tensor ids are dense `u32`. The graph MUST be a DAG; loader checks acyclicity + bounded fan-in (reject loudly). |
| `0x02` | `TENSORS` | tensor table: per tensor `{ id:u32, role:u8 (INPUT_LATENT/INPUT_HYPER/WEIGHT/BIAS/SCRATCH/OUTPUT/CONST), dtype:u8, rank:u8, dims:i32[rank], weight_off:u64, weight_len:u64 }`. `weight_off/len` index into the weights blob (§8.5.5); validated `⊆ blob`. |
| `0x03` | `QUANT` | per-latent quantization: `{ y_quant_step:rational(i32 num,i32 den), z_quant_step:rational, round_mode:u8 (0=round-half-to-even) }`. Dequant is a **declared exact** integer op; the dequant table for `entropy_param_kind = 3` is carried here too. |
| `0x04` | `HYPERPRIOR` | the factorized prior CDF for ẑ: a declared, frozen cumulative table per hyper-channel `{ channel:u16, cdf_precision:u8 (=12), n_symbols:u16, cdf[n_symbols+1]:u16 }`. This is the only image-independent distribution; it is **data in the descriptor**, not hidden runtime state. |
| `0x05` | `BUDGET` | bounded-memory declaration: `{ max_scratch_bytes:u64, max_tensor_bytes:u64, max_weight_bytes:u64, max_ops:u32, max_tensor_rank:u8 }`. A decoder pre-sizes all buffers from these before running; exceeding any at decode is `E_CSIF_BUDGET` (loud). |
| `0x06` | `LATENT_LAYOUT` | how the rANS-coded latent maps to tensor `INPUT_LATENT`: `{ scan:u8 (row-major channel-last), ctx_model:u8 (0=hyperprior-driven), n_streams:u32, stream_map_kind:u8 }`. Ties the entropy `EOFF` streams to latent positions; per-tile when `tiled_latent`. |
| `0x07` | `RESIDUAL` | present iff `lossless_residual_present`: declares the lossless residual codec for exact reconstruction (§8.10): `{ residual_codec_id:u8 (=2 MODULAR), residual_params_len:u32, residual_params[] }`. |
| `0x08` | `WEIGHTS_REF` | present iff `weights_referenced`: `{ store_id:u32, name_len:u16, name_utf8[] }` — names the OS weight-store entry; the actual bytes are fetched and **MUST** hash to `weights_digest` (§8.5.3). |

#### 8.5.3 Weights: embedded vs referenced (`IMDL` chunk)

Two delivery modes, declared by `flags`, exactly mirroring the
dictionary-delivery design of the Compressors section:

- **Embedded** (`weights_embedded`): the canonical weights blob (§8.5.5) is a
  normal **`IMDL`** chunk in this file (skippable-if-unknown bit set, so a
  non-NEURAL reader skips it; but for NEURAL it is required). `IMDL` payload =
  `{ model_id:u32, model_version:u32, blob_len:u64, blob[blob_len] }`. The
  loader verifies `BLAKE3(blob) == weights_digest` before any inference, or
  fails `E_CSIF_WEIGHTS_DIGEST`.
- **Referenced** (`weights_referenced`): no `IMDL` chunk; the `WEIGHTS_REF`
  TLV names a shared OS model-store entry by id+name. The runtime fetches it,
  and **MUST** verify `BLAKE3 == weights_digest`. If the store lacks that exact
  weights blob, decode **fails loudly** with `E_CSIF_WEIGHTS_MISSING` — never a
  silent fallback to a different model (that would change pixels). The file
  stays self-describing about *what it needs* even when the weights live
  out-of-file: the digest is the exact key (the project's "everything is a
  key" applied to model weights).

Embedding and referencing are mutually exclusive; setting both bits is
`E_CSIF_INCONSISTENT`.

#### 8.5.4 Model-family registry (`model_id`) — closed, versioned

`model_id` is a **closed registry** parallel to the codec registry and the
entropy-method registry. It does **not** name a generic "any network" — it
names a *specific declared architecture family* whose operator wiring is
expressible by the `GRAPH` op-set (§8.8) and whose semantics are pinned by the
spec, so two CIRs run it identically. `nmd_version 1` reserves:

| `model_id` | Family | Status |
|---|---|---|
| `0` | reserved / invalid | always `E_CSIF_UNKNOWN_MODEL` |
| `1` | **HYPERPRIOR-MEAN-SCALE** (Ballé/Minnen scale-hyperprior, factorized hyper, Gaussian conditional) | spec'd, shippable when a CIR exists |
| `2` | **HYPERPRIOR-MIXTURE** (Gaussian-mixture conditional, autoregressive-free) | spec'd |
| `3..0x7FFF` | reserved for future *declared* public families | — |
| `0x8000..0xFFFF` | private/experimental (requires the `CHUNK_PUBLIC=0` discipline; never collides with public ids) | — |

There is **no** "interpret arbitrary ONNX/whatever" escape hatch. A family must
be a declared entry, mapping onto the closed op-set. Adding a family is a spec
+ registry change (a new `model_id` + its frozen semantics), exactly like
adding a codec or a `.cdvrspec` device class.

#### 8.5.5 Canonical weights blob layout

The weights blob is a flat, **little-endian**, deterministically-ordered byte
image of all `WEIGHT`/`BIAS`/`CONST` tensors, in **ascending tensor `id`**
order, each tightly packed at its declared `dtype` with no padding between
tensors except to the declared `arith` alignment (8 bytes for
`INT8xINT32-accum`). The `TENSORS` table's `weight_off/weight_len` index into
this blob. Canonical ordering makes `weights_digest` reproducible: any compliant
serializer produces byte-identical blobs from the same trained weights, so the
hash is a stable key. Quantized weights are stored as their integer values
(int8 for weights, int32 for biases under `arith = 1`); **no float weights ever
appear** in a CSIF NEURAL file (float weights would defeat bit-exact decode).

---

### 8.6 NEURAL tile bitstream (per-tile, inside IDAT)

Each NEURAL tile is independently decodable (entropy context reset at tile
start), addressed by `TIDX`. A tile begins with a small **NEURAL Tile Header**,
then the two rANS-coded payloads:

| Off | Size | Field |
|---|---|---|
| +0x00 | 4 | `nt_magic` `"NTL1"` |
| +0x04 | 4 | `hyper_stream_len` (u32) — bytes of the rANS-coded ẑ |
| +0x08 | 4 | `latent_stream_len` (u32) — bytes of the rANS-coded ŷ |
| +0x0C | 4 | `flags` (u32) — bit0 `residual_follows` |
| +0x10 | … | `hyper_stream[hyper_stream_len]` |
| … | … | `latent_stream[latent_stream_len]` |
| … | … | optional `residual_stream` (a MODULAR sub-stream, §8.10) iff `residual_follows` |

Both `hyper_stream` and `latent_stream` are **shared-rANS** streams
(`entropy_method_id = 0`, precision 12, the interleaved static rANS). The loader
validates `0x10 + hyper_stream_len + latent_stream_len (+ residual) ==` the
tile's `TIDX` length, else `E_CSIF_TILE_LEN`.

**Decode order within a tile (deterministic, declared):**

1. rANS-decode ẑ from `hyper_stream` using the **`HYPERPRIOR`** factorized CDF
   (image-independent, from NMD). Dequantize by `z_quant_step` → ẑ tensor.
2. `CIR.run(h_s, ẑ)` → entropy parameters `Φ` (e.g. per-position mean+scale),
   produced as **fixed-point integers** in the declared `arith`.
3. Convert `Φ` to **rANS distributions**: the spec fixes the exact, integer-only
   mapping from `(mean, scale)` (or mixture params) to a 12-bit quantized CDF
   over the latent symbol alphabet (the discretized-Gaussian construction is
   written out numerically in §8.9). This is the *only* place inference output
   meets entropy coding, and it is **table-driven and exact**.
4. rANS-decode ŷ from `latent_stream` under those per-position distributions.
   Dequantize by `y_quant_step` → ŷ tensor.
5. `CIR.run(g_s, ŷ)` → reconstructed sample tensor in `color_space_tag`.
6. Shared color/transform → output in IHDR's declared sample space.

A corrupt tile fails **loudly and locally** (per-tile independence + optional
`TIDX` checksum), never poisoning other tiles.

---

### 8.7 The CSIF Inference Runtime (CIR) contract

A CIR is the engine that executes `GRAPH` deterministically. It is registered
with the container exactly like an `EntropyCodec` is registered — a small,
closed vtable (the KObject-vtable analogy, again uniform across the system):

```
CIR vtable:
  fn cir_init(*CirState, *const NMD, *const WeightsBlob) -> i32
  fn cir_run(*CirState, graph_id u32, *const Tensor[] inputs,
             *Tensor[] outputs) -> i32      # deterministic, bounded
  fn cir_free(*CirState) -> i32
```

A CIR MUST provide, to be conformant:

1. **Deterministic fixed-point arithmetic.** Under `arith = 1`
   (INT8×INT32-accum), every operator is specified as integer math with
   declared rounding and saturation (§8.8/§8.9). The same `GRAPH` + weights +
   inputs MUST yield **byte-identical** output tensors on every conformant CIR,
   on every CPU, at every `-smp` width. No float, no FMA-contraction freedom,
   no fast-math, no transcendental-rounding ambiguity. Activation functions are
   either piecewise-linear (exact) or table-lookups whose tables are **frozen
   constants in the spec** (referenced by a versioned `table_id`), never
   computed in float at runtime.

2. **Bounded, caller-provided memory.** All scratch/tensor/weight buffers are
   sized from the `BUDGET` TLV *before* `cir_run`. The runtime allocates
   **nothing** during `cir_run`; the caller passes the buffers (freestanding /
   non-allocating discipline, philosophy rule 5). Tiling bounds the latent
   tensor to one container tile's footprint when `tiled_latent`.

3. **The complete declared operator set (§8.8)** — or it honestly refuses
   `cir_init` with `E_CSIF_CIR_OP` naming the missing `op_code`. No operator is
   approximated; an unsupported op is a loud refusal, never a silent
   substitution.

4. **No side effects, no I/O, no clock, no RNG.** A CIR is a pure function of
   `(graph, weights, inputs)`. Any randomness a learned codec needs (none for
   the reconstruction path; grain/noise synthesis is a *separate* declared
   feature with its own declared PRNG) is out of scope here — the
   reconstruction transform is deterministic.

5. **Validation before execution.** `cir_init` validates the graph (DAG,
   bounded fan-in, tensor dims consistent, weight ranges `⊆` blob, op attrs
   in range) and the `weights_digest`. It fails loudly on any violation; it
   does not "best-effort" a malformed graph.

The container is **mechanism**: it dispatches to the CIR and never inspects
tensors. The CIR is **policy**: it knows how to run the math. The trained
weights are **data**. This is the same three-way split CSIF uses everywhere.

---

### 8.8 Declared operator set (`op_code`, closed, `nmd_version 1`)

The `GRAPH` op-set is **closed and exhaustive** — the honest closed op-set rule
applied to tensors. A family (`model_id`) is only valid if it is expressible in
these ops. Every op has spec-fixed integer semantics under `arith = 1`.

| `op_code` | Op | Integer semantics (summary; full numeric spec in the conformance vectors) |
|---|---|---|
| `0x0001` | `CONV2D` | int8 weights × int8 acts → int32 accum; attrs: stride, pad, dilation, groups; output requantized by a declared `(mult:i32, shift:u8)` per output channel (fixed-point), saturating to int8 |
| `0x0002` | `CONV2D_TRANSPOSE` | as `CONV2D`, transposed (used by `g_s`/`h_s` upsampling); declared output_padding |
| `0x0003` | `DEPTHWISE_CONV2D` | groups == channels special case, same requant |
| `0x0004` | `ADD` | int32/int8 elementwise add with declared requant |
| `0x0005` | `MUL_CONST` | multiply by a declared fixed-point constant |
| `0x0006` | `LEAKY_RELU` | piecewise-linear, declared negative slope as `(num,den)` |
| `0x0007` | `RELU` | exact clamp at 0 |
| `0x0008` | `GDN` / `IGDN` | generalized divisive normalization, computed via the **frozen reciprocal-sqrt table** `table_id` declared in attrs (no float `pow`); the canonical learned nonlinearity for image autoencoders, made exact by table lookup |
| `0x0009` | `PRELU` | per-channel piecewise-linear slopes (declared fixed-point) |
| `0x000A` | `TABLE_LUT` | apply a frozen 1-D LUT (`table_id`) elementwise (exact) |
| `0x000B` | `RESHAPE` | metadata-only; no arithmetic |
| `0x000C` | `SLICE` / `CONCAT` | layout ops; no arithmetic |
| `0x000D` | `PARAM_SPLIT` | split a tensor into the entropy-parameter fields (mean/scale or mixture) consumed by §8.9 |
| `0x000E` | `CLAMP` | declared int min/max |
| `0x000F` | `PAD` | declared constant pad |

`GDN`/`IGDN` and the activations are the only nonlinearities, and each resolves
to **piecewise-linear or frozen-table** math — that is what makes the whole
network bit-exact. There is no general `exp`/`log`/`pow`/`div` in float
anywhere on the decode path.

---

### 8.9 Inference output → rANS distribution (the exact bridge)

This is the load-bearing determinism point and is specified to the bit. For
`entropy_param_kind = 0` (Gaussian conditional), `g_s`/`h_s` (via `PARAM_SPLIT`)
produce per-latent-element fixed-point `mean μ` and `scale σ` (σ as a positive
fixed-point value, declared `Q` format). For each element with integer symbol
alphabet `s ∈ [s_lo, s_hi]` (declared in `LATENT_LAYOUT`), the spec defines the
**discretized-logistic/Gaussian** cumulative exactly:

- The continuous CDF is evaluated **only** through a **frozen, integer,
  monotone table** `CDF_TABLE[table_id]` indexed by the fixed-point quantity
  `t = clamp((s + 0.5 − μ) / σ)` computed with declared rounding, giving a
  12-bit cumulative value. The table is a spec constant (versioned, frozen at
  self-host like the entropy conformance vectors); no `erf`/`exp` runs at
  decode. 
- Per-symbol frequency = `CDF(s+0.5) − CDF(s−0.5)`, normalized to total
  `TOTAL = 4096` by the **same** largest-remainder, guaranteed-nonzero-floor
  algorithm the shared entropy substrate uses for any histogram (DRY — one
  normalization routine, reused). The resulting alias table feeds the shared
  rANS decode.

For `entropy_param_kind = 1` (mixture-K) the K weighted components are summed in
fixed-point and the same table+normalization applies. For
`entropy_param_kind = 3` (categorical-LUT) the network output *is* the
distribution (a declared LUT), again normalized identically.

Because (a) inference is integer-exact, (b) the CDF table is frozen, and (c) the
normalization + rANS are the same frozen integer routines used elsewhere,
**every conformant decoder reconstructs byte-identical latents and pixels.**
This satisfies the Conformance section's requirement that lossy decode be
bit-exact (the encoder is free; the decoder is pinned).

---

### 8.10 Lossless and near-lossless via declared residual

A learned codec is inherently lossy (quantized latents). CSIF makes lossless
NEURAL **honest and explicit**, never implied:

- If `flags.lossless_residual_present` (and `ICOD.is_lossless = 1`), the tile
  carries, after the latent stream, a **residual sub-stream** coded by the
  **shared MODULAR codec** (`residual_codec_id = 2`, params in the `RESIDUAL`
  TLV). The decoder computes the learned reconstruction (§8.6 steps 1–6), then
  adds the MODULAR-decoded integer residual `(original − learned)` to obtain the
  **bit-exact original**. The container asserts the invariant
  `is_lossless = 1 ⇔ residual present`, and rejects a NEURAL stream claiming
  lossless without a residual (`E_CSIF_INCONSISTENT`). 
- Near-lossless is the same path with a **declared per-channel error bound**
  carried in the `RESIDUAL` params (the MODULAR codec's `near_lossless_delta`),
  so reconstruction error is bounded by `±delta` and the file states the exact
  bound — no silent quality degradation.

This reuses the existing lossless engine (DRY) rather than inventing a learned
lossless path, and keeps `is_lossless` meaning exactly what it says.

---

### 8.11 Error model (loud, bounded, register-level)

NEURAL adds these numbered, explicit errors to CSIF's closed error set; a
decoder returns the specific code with the offending field/offset (matching
`cse.cst`'s enumerated fail-loud discipline) and **never** renders garbage:

| Error | Cause |
|---|---|
| `E_CSIF_NO_RUNTIME` | `codec_id = 5` encountered but no CIR is registered (the current state of every causticos build) |
| `E_CSIF_PROFILE` | NEURAL in a file whose declared profile is BASELINE, or decoder advertises BASELINE |
| `E_CSIF_UNKNOWN_MODEL` | `model_id` not in the closed registry |
| `E_CSIF_WEIGHTS_DIGEST` | embedded/referenced weights hash ≠ `weights_digest` |
| `E_CSIF_WEIGHTS_MISSING` | referenced weights absent from the OS model-store |
| `E_CSIF_CIR_OP` | `GRAPH` uses an `op_code` the CIR does not implement |
| `E_CSIF_BUDGET` | decode would exceed a declared `BUDGET` ceiling |
| `E_CSIF_UNSUPPORTED` | declared `sample_format`/`arith` not supported by the CIR |
| `E_CSIF_INCONSISTENT` | NMD contradicts IHDR, or lossless/residual/weights flags contradict each other |
| `E_CSIF_TILE_LEN` | tile sub-stream lengths don't sum to the `TIDX` length |
| `E_CSIF_GRAPH` | non-DAG graph, dangling tensor id, out-of-range weight range, or attr out of range |

All resource sizes (tensors, scratch, weights, ops) are validated against the
`BUDGET` TLV **before** any allocation or inference (overflow-checked in widened
arithmetic), so a malicious NMD cannot demand unbounded memory — the same
pre-allocation discipline CSIF applies to image dimensions.

---

### 8.12 Honesty, provenance, and AI-disclosure coupling

A learned encoder is an algorithmic transform of the pixels. CSIF makes that
**signed and disclosed**, wiring NEURAL to the Provenance section:

- When `codec_id = 5` is used, the encoder **MUST** emit a `DISCLOSE`
  assertion (`digital_source_type ∈ {algorithmicEdit, algorithmicMedia}` —
  learned *compression* of human-captured content is `algorithmicEdit`; learned
  *generation* would be `trainedAlgorithmicMedia`) naming the `model_id` /
  `model_version`. If a `PROV` chunk is present, the container **cross-checks**
  that a NEURAL ICOD has a matching `DISCLOSE`, and reports a verification
  inconsistency loudly — a learned codec is never an undisclosed black box.
- The `weights_digest` and `model_id/version` make the *exact* model an
  auditable, hashable key, so provenance can attest precisely which learned
  transform produced the bytes.

This keeps NEURAL aligned with the project's deepest value: the format is honest
about how the pixels came to be.

---

### 8.13 Summary of what is frozen now vs. what arrives with the runtime

- **Frozen now (this spec):** the `codec_id = 5` slot; the `{decode, encode}`
  seam; the NMD descriptor (magic, fields, TLV records); the model-family
  registry shape; the weights delivery + hashing; the tile bitstream; the
  three-stage pipeline (shared rANS ↔ inference ↔ shared color); the closed
  operator set; the exact inference→distribution bridge; the determinism
  contract (`arith = 1`, frozen tables, integer-only); the bounded-memory
  budget; the lossless-via-residual path; the error model; the
  provenance/disclosure coupling.
- **Arrives with the CIR (the real blocker, sequenced honestly):** a
  deterministic integer tensor engine implementing §8.7/§8.8, the frozen CDF
  and activation tables as committed conformance constants, and at least one
  registered `model_id` family with shipped quantized weights + golden test
  vectors (per the Conformance section's golden-corpus requirement). Until then,
  every decoder returns `E_CSIF_NO_RUNTIME` — a real, loud, honest gate, not a
  stub that pretends to decode.

---

Section 8 written above as the literal spec content. It defines `codec_id = 5` (NEURAL) as a complete, closed interface slot honestly gated behind the (real) inference-runtime blocker, fully consistent with the Caustic philosophy and the CSIF family conventions in `/home/caua/Documentos/Projetos-Pessoais/causticos/docs/CSE_FORMAT.md` (little-endian declared, magic+version+flags+TLV, fail-loud numbered errors, frozen-at-self-host, shared toolkit / mechanism-vs-policy split). Key load-bearing decisions: latent + hyperprior coded by the **shared rANS** (model produces probabilities, frozen integer rANS produces bytes — no learned arithmetic coder, no float in the coding loop); `ICOD.params` = a declared **NMD** descriptor (`"NMD1"`, model_id closed registry, BLAKE3 weights digest, closed tensor op-set, BUDGET ceilings); a **CIR** vtable contract mandating integer/fixed-point bit-exact determinism + bounded caller-provided memory; lossless via a declared shared-MODULAR residual; and `E_CSIF_NO_RUNTIME` as the honest gate (never a fake decoder). It also couples NEURAL to the Provenance section's AI-disclosure (`DISCLOSE` assertion required, cross-checked).

---

Now I understand the project's documentation conventions: byte-exact field tables with `Off/Size/Field/Value` columns, little-endian, fail-loud loader algorithms, and the philosophy framing. I have everything needed to write section 9 in this exact style. Let me write the specification.

I now have full context. Here is section 9 of the CSIF specification, written to match the project's byte-exact table style, fail-loud loader discipline, and Caustic philosophy framing, and to fit consistently with the other sections of the dossier (ITBL items, ITOC index, codec registry, ColorEncoding, ICHN channels, etc.).

---

## 9. Progressivo, ROI, animação, aux, thumbnails

This section specifies the **advanced container features**: progressive / responsive decode (LF-first passes), region-of-interest and partial decode by tile range, multi-frame animation (frame chunks, timing, disposal, reference frames), layered / composited stills, auxiliary channels (premultiplied alpha, depth, HDR gain map), and multi-resolution embedded thumbnails / mipmaps.

Every one of these is expressed **as declared data in the container** — never as a codec side effect, never inferred from content, never a behavior-changing default. They are all *different traversals of one addressable structure*: the **ITOC** index (§9.1) maps every coded unit to a byte range plus an explicit dependency set; the **IPRG**, **ILVL**, **IANI/IFRM**, **ICMP**, **ICHN/IGMP**, and **ITHM** chunks declare *how* a reader should traverse, refine, compose, or skip those units. The container is **mechanism** (index + traversal declarations + bounded-recursion validation); each codec is **policy** (what a unit's bytes mean).

This section assumes the chunk/TLV container (`magic "CSIF"` + version + flags + chunk directory), the `ITBL` item table, the closed codec registry dispatched by `codec_id`, the `ICHN` per-channel descriptor table, and the explicit `ColorEncoding` block, all defined in earlier sections. All multi-byte fields are **little-endian** (declared once in the file header, never per-field, never guessed). All offsets are **u64** from file start. All `*_count` fields are bounded by the corresponding `ILIM` ceiling (§9.10) and validated **before** any allocation.

### 9.0 Cross-cutting invariants

These hold for every feature in this section and are enforced by the loader's `validate_structure` pass **before** any codec runs (fail-loud, register-level error reporting per §9.10):

1. **Everything is a declared key.** A pass, a level, a frame, a layer node, an aux channel, a thumbnail — each is an explicit record addressed by an index, with explicitly-declared geometry, dependencies, and byte range. Nothing is positional ("the previous frame", "the first item", "channel 4 is alpha") — references are always by **declared index**.
2. **Dependency = data, not codec-internal magic.** Whenever unit *Y* needs unit *X* decoded first (AC-after-DC, P-frame-after-keyframe, overlay-over-base, derived-from-coded), that edge is recorded explicitly in `ITOC.dependency` (§9.1). A reader closes the dependency set by table lookup; it never reconstructs decode order from codec bytes.
3. **All dependency graphs are DAGs, bounded.** Passes, levels, frames, and composition nodes form directed acyclic graphs. The loader rejects cycles and rejects depth/fan-in exceeding `ILIM` (`E_CSIF_GRAPH_CYCLE`, `E_CSIF_GRAPH_DEPTH`). This bounds recursion and memory.
4. **Geometry reconciliation.** Every derived/composed/assembled unit declares its output geometry; the loader recomputes geometry from the unit's inputs and rejects a mismatch (`E_CSIF_GEOM_MISMATCH`). Output dimensions are never trusted-as-stated when they are derivable.
5. **Bounded memory, partial decode honest.** A reader sizes every buffer from declared lengths/geometry up front. Decoding any single tile/pass/level/frame/aux unit requires memory bounded by that unit's declared uncompressed size + the codec's declared scratch — never a whole-image buffer (unless the image *is* one unit).
6. **Skippable means skippable.** Feature chunks that do not change the canonical default pixels (animation, gain map, ROI hints, extra thumbnails beyond the first) carry the `CHUNK_SKIPPABLE` flag (the CSE-family forward-compat convention). A reader that does not implement the feature skips the chunk by its declared length and still produces a valid still image — the **canonical default rendition** (§9.5.4).

### 9.1 ITOC — Table Of Contents (the addressable substrate)

**ITOC is mandatory** for any file using progressive, ROI, animation, layers, multi-level, or auxiliary features. (A trivial single-unit still MAY omit ITOC; then the single IDAT chunk is the one unit.) ITOC maps every coded unit to a byte range plus its dependency set. It is the single mechanism that makes partial decode, ROI, progressive, multi-frame, and channel-skipping all possible.

**ITOC chunk payload:**

| Off | Size | Field | Notes |
|---|---|---|---|
| 0x00 | 4 | `entry_count` (u32) | number of coded-unit entries; ≤ `ILIM.max_toc_entries` |
| 0x04 | 4 | `entry_stride` (u32) | bytes per entry; MUST equal 56 for this version (lets future versions widen) |
| 0x08 | … | `entries[]` | `entry_count` records of `entry_stride` bytes each |

**ITOC entry (56 bytes):**

| Off | Size | Field | Notes |
|---|---|---|---|
| +0x00 | 4 | `unit_id` (u32) | unique, dense (0..entry_count-1); used as the dependency reference |
| +0x04 | 1 | `unit_kind` (u8) | closed enum, see below |
| +0x05 | 1 | `codec_id` (u8) | which codec decodes these bytes (or `DERIV` for a composition node) |
| +0x06 | 2 | `flags` (u16) | bit0 = `INDEPENDENT` (no entropy-context carry-in); bit1 = `IS_DEFAULT_RENDITION` member; bit2 = `HAS_CRC` |
| +0x08 | 4 | `frame_index` (u32) | which frame (0 if still); `0xFFFFFFFF` = not-frame-scoped |
| +0x0C | 4 | `level_x` (u32) | resolution level along X (mip), 0 = full-res |
| +0x10 | 4 | `level_y` (u32) | resolution level along Y (ripmap; = `level_x` for mipmaps) |
| +0x14 | 4 | `tile_x` (u32) | tile column in this level; `0xFFFFFFFF` = whole-level |
| +0x18 | 4 | `tile_y` (u32) | tile row in this level |
| +0x1C | 4 | `channel_id` (u32) | which channel-plane (index into ICHN); `0xFFFFFFFF` = all/interleaved |
| +0x20 | 4 | `pass_index` (u32) | progressive pass (0 = DC/LF); `0xFFFFFFFF` = not-pass-scoped |
| +0x24 | 8 | `byte_offset` (u64) | absolute file offset of this unit's bytes (MUST lie inside a declared IDAT-class chunk) |
| +0x28 | 8 | `byte_length` (u64) | length of this unit's bytes |
| +0x30 | 4 | `dep_offset` (u32) | offset into the ITOC dependency pool (§below) of this unit's dependency list; `0xFFFFFFFF` = no deps |
| +0x34 | 4 | `crc32c` (u32) | CRC-32C over the unit's bytes if `HAS_CRC` else 0 (§9.9) |

**`unit_kind` closed enum:** `0 = LF_PASS` (DC / coarse, a complete low-res image), `1 = AC_PASS` (refinement), `2 = TILE` (a spatial tile at a level), `3 = LEVEL` (a whole resolution level, untiled), `4 = FRAME_BASE` (a self-contained frame), `5 = FRAME_DELTA` (a frame predicted from references), `6 = CHANNEL_PLANE` (an aux/extra channel plane), `7 = THUMBNAIL` (a standalone preview image), `8 = DERIV` (a composition/derived node, payload = a derivation descriptor, see §9.6), `9 = PROV` (provenance unit, out of scope here). Unknown `unit_kind` ⇒ `E_CSIF_TOC_KIND`.

**Dependency pool** (appended after `entries[]` in the ITOC payload): a flat array of `{ dep_count:u32, dep_unit_ids:u32[dep_count] }` records, referenced by `dep_offset`. A unit's transitive dependency closure (computed by repeated lookup) is exactly the set a reader must decode before it.

**Reader contract (partial decode by index):** to satisfy a request `{region, level, frames, channels, quality}` the reader (1) selects the ITOC entries whose declared coordinates intersect the request, (2) transitively closes their `dep_offset` lists, (3) byte-range-fetches exactly those `(byte_offset, byte_length)` ranges, (4) optionally verifies `crc32c`, (5) hands each unit's bytes to its `codec_id`. No scan, no marker hunting, no "decode and see how far you get".

**Validation:** every `byte_offset + byte_length` MUST lie within a single declared IDAT-class chunk (reject dangling/overlap, mirroring the CSE loader's `file_off+file_size > cst_size` guard); `unit_id` MUST be unique and dense; every referenced `dep_unit_id` MUST exist; the dependency graph MUST be acyclic with depth ≤ `ILIM.max_dep_depth`.

### 9.2 IPRG — Progressive / responsive decode

Progressive decode is **structural and declared**, not bolted on. The codec emits multiple **passes** per tile: `pass_index = 0` is the **DC/LF pass** (a coarse but complete image, conventionally ≈ 1:8 of full resolution); passes `1..N` are refinements (higher-frequency AC / successive-approximation bits). Each pass is its own ITOC unit (`LF_PASS` / `AC_PASS`, with `pass_index`). A reader that decodes only the LF passes of all tiles gets a full coarse frame; truncation **at a declared pass boundary** is a first-class state, never a "best effort".

**IPRG chunk payload:**

| Off | Size | Field | Notes |
|---|---|---|---|
| 0x00 | 1 | `progression_order` (u8) | closed enum, see below |
| 0x01 | 1 | `pass_count` (u8) | total passes per tile; ≤ `ILIM.max_passes` |
| 0x02 | 1 | `lf_downsample_log2` (u8) | the DC/LF pass is 1:2^this of full res (e.g. 3 = 1:8) |
| 0x03 | 1 | `lf_upsample_filter` (u8) | filter the reader MUST use to upsample an LF-only render: `0=NEAREST, 1=BILINEAR, 2=BICUBIC_DECLARED, 3=WAVELET_SUBBAND` (intrinsic to wavelet codecs) |
| 0x04 | 4 | `reserved` (u32) | MUST be 0 |
| 0x08 | … | `pass_descs[]` | `pass_count` records of 16 bytes |

**`progression_order` closed enum** (the explicit "one file, many access patterns" knob, after JPEG 2000 LRCP/RLCP/RPCL/PCRL/CPRL): `0 = LRCP` (quality/layer-first), `1 = RLCP` (resolution-first), `2 = RPCL` (resolution then position), `3 = PCRL` (position/spatial-first), `4 = CPRL` (component/channel-first). The byte order of units in the file is **fully determined** by this field plus the tile/level/channel/pass partition; there are no implicit tie-breaks. Because ITOC also gives random access, the order is a **streaming optimization hint** for the prefix-render path, not a hidden requirement for random access.

**`pass_desc` (16 bytes):**

| Off | Size | Field | Notes |
|---|---|---|---|
| +0x00 | 4 | `pass_index` (u32) | 0..pass_count-1 |
| +0x04 | 4 | `cumulative_byte_len` (u64-lo / see note) | declared total bytes from file-render-start through the end of this pass (for streaming truncation) |
| +0x0C | 4 | `quality_checkpoint` (f32) | achieved quality after this pass, in the file's declared metric (see the metrics section); `NaN` = unspecified |

> Note: `cumulative_byte_len` is a `u64` occupying +0x04..+0x0B; the table splits it only for column width. A streaming reader that has received *B* bytes decodes all passes whose `cumulative_byte_len ≤ B`, renders that prefix via `lf_upsample_filter`, and reports **"decoded pass K of N, quality Q"** — an honest status, never a silently-degraded image pretending to be complete.

**Responsive (resolution-scalable) path.** When the codec is wavelet/Squeeze-based, the LF passes ARE lower resolution levels (`lf_upsample_filter = WAVELET_SUBBAND`, intrinsic). When the codec is DCT/Modular, the LF pass is the DC image and `lf_upsample_filter` declares the exact reproducible upsampler. Either way the *per-prefix render recipe is declared*, so two readers produce the same coarse image. The DC/LF unit MAY also serve as a thumbnail by reference (§9.8) — DRY, no duplicated low-res data.

### 9.3 ILVL — Resolution pyramid / mipmaps / ripmaps

ILVL declares a multi-resolution pyramid as **first-class addressable levels**, so a reader can "decode at the size I'm displaying" without decoding full-res and downscaling. This composes with §9.2 (LF passes within a level) and with tiling (each level's tiles are separate ITOC `TILE` units carrying `level_x`/`level_y`).

**ILVL chunk payload:**

| Off | Size | Field | Notes |
|---|---|---|---|
| 0x00 | 1 | `level_mode` (u8) | `0 = ONE_LEVEL`, `1 = MIPMAP` (uniform X&Y halving), `2 = RIPMAP` (independent X,Y decimation) |
| 0x01 | 1 | `rounding_mode` (u8) | how odd dims halve: `0 = ROUND_DOWN`, `1 = ROUND_UP` (declared, never implicit) |
| 0x02 | 1 | `downsample_filter` (u8) | filter that PRODUCED the levels: `0=BOX, 1=LANCZOS_DECLARED, 2=BILINEAR, 3=WAVELET_SUBBAND` (intrinsic) |
| 0x03 | 1 | `level_intrinsic` (u8) | `0 = stored pyramid` (levels are real coded data), `1 = intrinsic` (levels are codec subbands; ILVL is descriptive only) |
| 0x04 | 4 | `level_count_x` (u32) | ≤ `ILIM.max_levels` |
| 0x08 | 4 | `level_count_y` (u32) | for MIPMAP equals `level_count_x`; for RIPMAP the X×Y grid |
| 0x0C | … | `levels[]` | `level_count_x × level_count_y` records of 24 bytes, row-major over (ly, lx) |

**`level` (24 bytes):**

| Off | Size | Field | Notes |
|---|---|---|---|
| +0x00 | 4 | `level_x` (u32) | X-decimation index |
| +0x04 | 4 | `level_y` (u32) | Y-decimation index |
| +0x08 | 4 | `width` (u32) | level width in pixels (declared **and** validated against the rounding formula) |
| +0x0C | 4 | `height` (u32) | level height |
| +0x10 | 4 | `tile_count` (u32) | tiles in this level (0 ⇒ untiled, a single `LEVEL` unit) |
| +0x14 | 4 | `reserved` (u32) | MUST be 0 |

**Geometry reconciliation:** the loader recomputes each level's `width/height` from level 0 dims, `level_x/level_y`, and `rounding_mode`; a stored value that disagrees ⇒ `E_CSIF_GEOM_MISMATCH`. Offsets are addressed only through ITOC (`level_x/level_y/tile_x/tile_y`), so ILVL carries geometry, ITOC carries byte ranges — clean separation. Partial decode of one level reads only that level's tile units into caller-provided buffers (bounded).

### 9.4 ROI — Region-of-interest / partial decode by tile range

ROI decode is **pure traversal of the explicit index** (ITOC + ILVL + the tile grid), plus an optional **quality-prioritized region** declaration. There is no inferred ROI (the Maxshift "guess the region from coefficient magnitudes" heuristic is rejected as magic): any region with elevated quality is declared.

**Tile independence is a declared fact.** ICOD carries `cross_tile_prediction` (`0 = NONE` — every tile fully self-contained, entropy context reset at tile start; `1 = DECLARED_NEIGHBORS` — a tile lists its predecessor tiles in ITOC deps). A reader KNOWS, from the header, whether fetching one tile is safe; it never guesses.

**Mapping a viewport to tiles.** Given a request rect at level *L*, the reader computes the covering tile set `(tile_x, tile_y)` from the declared level `width/height` and the ICOD `tile_w/tile_h`, selects the matching ITOC `TILE` units, closes their dependency lists (their LF passes, their declared neighbor tiles), and fetches exactly those ranges. Memory = one tile's working set at a time.

**IROI chunk payload (optional, skippable):** declares named quality-uplifted regions the encoder coded earlier/finer.

| Off | Size | Field | Notes |
|---|---|---|---|
| 0x00 | 4 | `region_count` (u32) | ≤ `ILIM.max_roi_regions` |
| 0x04 | … | `regions[]` | 28-byte records |

**`region` (28 bytes):**

| Off | Size | Field | Notes |
|---|---|---|---|
| +0x00 | 4 | `x` (u32) | region rect in full-res (level 0) pixel coords |
| +0x04 | 4 | `y` (u32) | |
| +0x08 | 4 | `w` (u32) | |
| +0x0C | 4 | `h` (u32) | |
| +0x10 | 4 | `priority` (u32) | 0 = highest; ordering for streaming |
| +0x14 | 4 | `quality_uplift` (f32) | declared metric delta vs background quality |
| +0x18 | 4 | `source_id` (u32) | provenance of the region (advisory): `0=MANUAL, 1=SALIENCY, 2=FACE`; never changes decode |

IROI is **input that the encoder already folded into the coded bytes** (the region's tiles/passes simply arrive earlier and finer in `progression_order`); a decoder needs nothing extra to render — IROI only *informs* a streaming reader which ranges to fetch first. Because it does not change canonical pixels, IROI is skippable.

### 9.5 IANI / IFRM — Animation / multi-frame

Animation is designed into the family (no APNG-style bolt-on). Timing is in **declared ticks**, blend and disposal are **closed enums with no default**, reference frames are **explicit indices**, and the number of reference buffers is **declared up front** so memory is bounded.

#### 9.5.1 IANI — animation header (one per animated image)

| Off | Size | Field | Notes |
|---|---|---|---|
| 0x00 | 4 | `frame_count` (u32) | total frames; ≤ `ILIM.max_frames` |
| 0x04 | 4 | `loop_count` (u32) | `0 = LOOP_INFINITE` (declared sentinel, documented — not implicit) |
| 0x08 | 4 | `tick_num` (u32) | time base numerator: one tick = `tick_num / tick_den` seconds |
| 0x0C | 4 | `tick_den` (u32) | time base denominator; both > 0 (reject 0 ⇒ `E_CSIF_TICKBASE`) |
| 0x10 | 4 | `canvas_w` (u32) | animation canvas width |
| 0x14 | 4 | `canvas_h` (u32) | animation canvas height |
| 0x18 | 4 | `n_reference_slots` (u8 in low byte; rest reserved) | how many reference-frame buffers a player must keep; ≤ `ILIM.max_ref_slots` — **this is the memory bound** |
| 0x1C | 8 | `canvas_bg` (u64) | background fill, declared in the file's color encoding (RGBA components packed; semantics per ColorEncoding) |
| 0x24 | 4 | `default_frame_index` (u32) | which frame is the **canonical default rendition** for still readers (§9.5.4) |

Every animation frame is also an ITOC unit (`FRAME_BASE` or `FRAME_DELTA`, with `frame_index`), so any frame is directly seekable and a delta frame's dependencies are its reference frames (transitively closed to a base frame).

#### 9.5.2 IFRM — per-frame control record

There is one IFRM chunk per frame (or one IFRM chunk carrying a `frame_count`-long array; either layout is legal and declared by the chunk length). Each frame record:

| Off | Size | Field | Notes |
|---|---|---|---|
| +0x00 | 4 | `frame_index` (u32) | 0..frame_count-1 |
| +0x04 | 4 | `duration_ticks` (u32) | display duration in IANI ticks (≥ 0) |
| +0x08 | 4 | `crop_x` (u32) | frame sub-rect on the canvas (frame need not cover the whole canvas) |
| +0x0C | 4 | `crop_y` (u32) | |
| +0x10 | 4 | `crop_w` (u32) | |
| +0x14 | 4 | `crop_h` (u32) | |
| +0x18 | 1 | `blend_op` (u8) | closed enum: `0=REPLACE, 1=OVER (alpha-composite), 2=ADD, 3=MUL` — drawn when compositing onto the canvas |
| +0x19 | 1 | `dispose_op` (u8) | closed enum (applied **after** display): `0=KEEP (leave as-is), 1=CLEAR_TO_BG (clear crop rect to `canvas_bg`), 2=RESTORE_PREVIOUS (restore the snapshot taken before this frame)` |
| +0x1A | 1 | `is_reference` (u8) | `1` ⇒ this frame may be referenced by later frames; it occupies a reference slot |
| +0x1B | 1 | `reference_slot` (u8) | which of the `n_reference_slots` buffers it occupies (if `is_reference`) |
| +0x1C | 4 | `ref_count` (u32) | number of reference frames this frame predicts from (0 ⇒ self-contained `FRAME_BASE`) |
| +0x20 | … | `ref_frame_indices[]` | `ref_count` × u32, the explicit reference set (also mirrored as ITOC deps) |

**Disposal semantics are spec-fixed and declared** (no APNG "restore-to-previous" ambiguity): `RESTORE_PREVIOUS` requires the player to have snapshotted the canvas region before drawing this frame; the snapshot depth a player must support equals the maximum chain of consecutive `RESTORE_PREVIOUS` frames, which is bounded by `n_reference_slots` accounting. Inter-frame prediction is the codec's policy; the timeline (timing, blend, dispose, references) is the container's mechanism.

#### 9.5.3 Bounded-memory playback

A player needs only: the canvas (`canvas_w × canvas_h`), at most `n_reference_slots` reference buffers, and the current frame's working buffer. All sizes are known from IANI/IFRM/IHDR before any decode. To seek to frame *N*, the reader follows `ref_frame_indices` (= ITOC deps) back to a `FRAME_BASE` and decodes forward — a stated traversal, not codec-internal magic.

#### 9.5.4 Canonical default rendition

For forward compatibility, a reader that does **not** implement animation MUST be able to produce a valid still: it renders `IANI.default_frame_index` (a `FRAME_BASE` by construction — the loader enforces this) and ignores all other frames and the IFRM/IANI timing. Because IANI/IFRM carry `CHUNK_SKIPPABLE`, a still-only reader skips them and decodes the default frame's ITOC units directly. This is forward-compat by **declared flag**, not by lowercase-letter magic.

### 9.6 ICMP — Layered / composited still images

ICMP declares a still image as a **DAG of composition nodes** — the codec-agnostic equivalent of HEIF derived images (grid / overlay / identity / transform). It lets a huge image be stored as a grid of independently-coded tile-items, a poster be built from layers, and a coded sub-image be shared across multiple presentations without re-encoding pixels. The container composites by reading fields; it never infers layout. The composition target node is the **primary** rendition.

**ICMP chunk payload:**

| Off | Size | Field | Notes |
|---|---|---|---|
| 0x00 | 4 | `node_count` (u32) | ≤ `ILIM.max_comp_nodes` |
| 0x04 | 4 | `primary_node` (u32) | which node is the default image |
| 0x08 | … | `nodes[]` | variable-length records, each `{ node_id:u32, node_kind:u8, out_w:u32, out_h:u32, param_len:u32, params[param_len] }` |

A composition node is also represented as an ITOC `DERIV` unit (its `params` are the unit bytes) so its inputs appear as ITOC dependencies.

**`node_kind` closed derivation registry** (parallel to the codec registry — the mechanism/policy seam at the container level): `0 = CODED` (a leaf: `params` = the set of ITOC `unit_id`s that form a coded sub-image), `1 = GRID`, `2 = OVERLAY`, `3 = IDENTITY`, `4 = TRANSFORM`. Unknown `node_kind` ⇒ `E_CSIF_DERIV_KIND` (load-bearing — never silently skipped).

**Per-kind `params`:**

- **GRID** — `{ rows:u32, cols:u32, out_w:u32, out_h:u32, child_ids:u32[rows*cols] }`. Cells laid row-major; tile size is **explicit** (= each child's declared geometry), never inferred from the first tile; output clipped to `out_w×out_h`. Reconciliation: `rows*cell_w ≥ out_w` etc. (`E_CSIF_GEOM_MISMATCH` otherwise).
- **OVERLAY** — `{ canvas_w:u32, canvas_h:u32, fill_rgba:u64, item_count:u32, items:[{ child_id:u32, dx:i32, dy:i32, blend_op:u8, opacity:u8 }] }`. Composited bottom-to-top in declared order over the declared fill.
- **IDENTITY** — `{ child_id:u32 }`. The node's pixels ARE the child's; used to attach a different transform/property set to a shared coded image.
- **TRANSFORM** — `{ child_id:u32, op_count:u8, ops:[{ op:u8, p0:i32, p1:i32, p2:i32, p3:i32 }] }`. `op` closed enum: `0=CROP(x,y,w,h)`, `1=ROTATE(quadrants 0/1/2/3 = 0/90/180/270)`, `2=MIRROR(0=h,1=v)`. **Transform application order is the declared `ops[]` order** and the encoder MUST store ops in canonical order (crop → rotate → mirror) — killing the ISOBMFF irot-vs-imir interop ambiguity; two readers can never disagree.

**DAG-by-construction:** every `child_id` MUST reference a lower-indexed node (`child_id < node_id`), guaranteeing acyclicity statically; fan-in ≤ `ILIM.max_comp_fanin`. Each leaf converts to the master color encoding (declared in IHDR) before blending — explicit, no implicit assume-sRGB. A shared coded sub-image referenced by multiple nodes is decoded once (DRY). GRID decodes one cell at a time (bounded). If ICMP is absent, the image is the single codec stream (the common case stays simple).

### 9.7 Auxiliary channels — alpha (premult), depth, HDR gain map

Auxiliary and extra channels are declared in the **ICHN** per-channel descriptor table (defined in earlier sections: each channel carries `role`, `sample_type`, `bit_depth`, `is_color_managed`, subsampling, per-channel `codec_id`, and for alpha an explicit association flag). This section specifies the three roles whose *application math* is part of the container contract.

#### 9.7.1 Alpha association (the #1 silent-corruption trap, closed)

Alpha is one declared channel with an explicit association. ICHN's alpha descriptor carries `alpha_mode` (closed enum): `0 = ALPHA_NONE`, `1 = ALPHA_STRAIGHT` (unassociated), `2 = ALPHA_PREMUL` (associated, in the coded space), `3 = ALPHA_PREMUL_LINEAR` (associated, in linear light). The compositing "over" formula is **selected by this declared flag**, never sniffed:

- straight: `out = src.a · src.rgb + (1 − src.a) · dst.rgb`
- premultiplied: `out = src.rgb + (1 − src.a) · dst.rgb`

`ALPHA_PREMUL_LINEAR` requires the compositor to operate in linear light (using the declared `ColorEncoding` transfer function). For GPU-uploadable block payloads, this flag also tells the compositor whether to pre-divide for editing or upload as-is. There is no default that "usually works".

#### 9.7.2 Depth and other typed aux channels

A depth channel is an ICHN entry with `role = DEPTH` (or `DEPTH_BACK`, `DISPARITY`, `NORMAL_X/Y/Z`, `OBJECT_ID`, `MOTION_X/Y`, `MASK`, `SPOT`, `CUSTOM`), `is_color_managed = 0` (the color transform MUST NOT be applied to it), its own `sample_type` (incl. `FLOAT16`/`FLOAT32`), its own `codec_id` (typically the lossless MODULAR codec — DRY), and a possibly-reduced resolution declared in its own ITOC/ILVL units. A reader can fetch only the depth plane's ITOC `CHANNEL_PLANE` units (e.g. an AR app wanting depth, not color). Aux channels bind to the master image by being members of the same item; the channel `role` is the declared semantics — a reader never assumes "channel 4 is alpha".

#### 9.7.3 IGMP — HDR gain map (backward-compatible single-file HDR)

A gain map is an **auxiliary ratio channel** (an ICHN entry, `role = GAINMAP`, possibly reduced-res, its own codec) plus a declared application recipe. A reader that ignores IGMP renders the honest SDR base (IGMP is skippable); a reader that applies it follows the declared math exactly — zero out-of-band knowledge, zero proprietary tone curve.

**IGMP chunk payload (per channel triple or single-channel; `channels` declared):**

| Off | Size | Field | Notes |
|---|---|---|---|
| 0x00 | 4 | `base_node_or_channels` (u32) | which ICMP node / channel set is the SDR base |
| 0x04 | 4 | `gainmap_channel_id` (u32) | the ICHN index of the gain-map plane |
| 0x08 | 1 | `gainmap_channels` (u8) | 1 (monochrome boost) or 3 (per-RGB boost) |
| 0x09 | 1 | `apply_space` (u8) | `0 = apply in linear`, `1 = apply in the declared base transfer space` |
| 0x0A | 2 | `reserved` (u16) | MUST be 0 |
| 0x0C | … | `params[gainmap_channels]` | per-channel application params, 32 bytes each |

**Per-channel gain params (32 bytes), all fixed-point/float, all declared (ISO 21496-1 class):** `gain_map_min` (f32, log2 boost floor), `gain_map_max` (f32, log2 boost ceiling), `gamma` (f32), `base_offset` (f32, epsilon), `alternate_offset` (f32), `base_hdr_headroom` (f32, stops), `alternate_hdr_headroom` (f32, stops), `reserved` (f32 = 0).

**Reconstruction (spec-fixed, reusing the shared color toolkit):** for each pixel,
`boost = exp2( lerp(gain_map_min, gain_map_max, map_decoded^(1/gamma)) )`, clamped by the display headroom interpolated between `base_hdr_headroom` and `alternate_hdr_headroom`; `hdr = (base + base_offset) · boost − alternate_offset`, evaluated in `apply_space`. The gain map is built entirely on the aux-channel mechanism (DRY) — no bolted-on path.

### 9.8 ITHM — Embedded multi-resolution thumbnails / mipmaps

Thumbnails are **real addressable units**, not an opaque baked blob, and the file declares each thumbnail's provenance so a reader knows whether a preview is bit-consistent with the full image or a curated separate asset.

**ITHM chunk payload:**

| Off | Size | Field | Notes |
|---|---|---|---|
| 0x00 | 4 | `thumb_count` (u32) | ≤ `ILIM.max_thumbs` |
| 0x04 | … | `thumbs[]` | 24-byte records |

**`thumb` (24 bytes):**

| Off | Size | Field | Notes |
|---|---|---|---|
| +0x00 | 4 | `width` (u32) | declared thumbnail geometry (reader ranks by this) |
| +0x04 | 4 | `height` (u32) | |
| +0x08 | 1 | `source` (u8) | `0 = DERIVED_FROM_LEVEL` (the thumbnail IS a declared pyramid/LF level of the primary), `1 = INDEPENDENT` (its own coded sub-image, possibly a different codec/colorspace) |
| +0x09 | 1 | `codec_id` (u8) | for INDEPENDENT thumbnails (e.g. a tiny QOI); ignored for DERIVED |
| +0x0A | 2 | `reserved` (u16) | MUST be 0 |
| +0x0C | 4 | `unit_id` (u32) | for DERIVED: the ITOC unit (an LF pass or an ILVL level) that IS the thumbnail; for INDEPENDENT: the ITOC `THUMBNAIL` unit holding its bytes |
| +0x10 | 8 | `reserved2` (u64) | MUST be 0 |

**DERIVED thumbnails are pure index traversal** — no duplicated low-res data, always bit-consistent with the full image, reusing the §9.2/§9.3 machinery (DRY). **INDEPENDENT thumbnails** reuse the same codec seam (a thumbnail can be RAW/QOI). A reader picks a thumbnail by declared `width/height`, never by guessing. Multiple thumbnails and a full resolution pyramid are the same pattern. (This **replaces** the v1 single opaque `THUM` chunk; the first thumbnail entry, if present, is the conventional default preview and is NOT skippable, while additional entries are skippable.)

### 9.9 LAYOUT & integrity for the multi-unit world

**Layout profile.** The file header carries an explicit `layout` enum (no sniffing): `0 = RANDOM_ACCESS` (ITOC and all metadata chunks precede the IDAT-class chunks; reader mmaps, reads the index, seeks) or `1 = STREAMING` (units appear in `IPRG.progression_order`; a minimal forward index lets a reader render each prefix as it arrives; the full ITOC sits at the end with a back-pointer). The header carries an explicit `itoc_offset` (u64, forward); for `STREAMING`, the terminal `IEND` carries `itoc_back_offset`. A reader chooses mmap-and-seek vs decode-as-it-arrives from the declared `layout`, never by probing.

**Per-unit integrity.** Each ITOC entry MAY carry a `crc32c` (CRC-32C / Castagnoli) over its bytes, flagged by `HAS_CRC`. Because tiles/passes/frames are independent decode units, a corrupt unit fails **loudly and locally** (`E_CSIF_UNIT_CRC` naming the `unit_id`); the rest decodes (honest partial result, never silent garbage). The integrity algorithm is declared in the file header (`checksum_algo`), never assumed. A bad unit is reported with its `unit_id`, `byte_offset`, and computed-vs-stored CRC — register-level error reporting, matching the project's fail-loud stance.

### 9.10 Bounds, validation, and error codes

All counts in this section are bounded by the mandatory **ILIM** descriptor (declared in the file before any IDAT-class chunk), which carries at least: `max_toc_entries`, `max_passes`, `max_levels`, `max_frames`, `max_ref_slots`, `max_comp_nodes`, `max_comp_fanin`, `max_dep_depth`, `max_roi_regions`, `max_thumbs`, `max_aux_channels`. The loader's `validate_structure` pass runs **before any codec**, in widened (u64) arithmetic, and rejects loudly with a numbered code:

| Code | Condition |
|---|---|
| `E_CSIF_TOC_KIND` | unknown `unit_kind` in an ITOC entry |
| `E_CSIF_TOC_RANGE` | `byte_offset+byte_length` outside any declared IDAT-class chunk, or overlapping/dangling |
| `E_CSIF_TOC_DEP` | dependency references a non-existent `unit_id` |
| `E_CSIF_GRAPH_CYCLE` | a dependency / composition graph contains a cycle |
| `E_CSIF_GRAPH_DEPTH` | dependency / composition depth or fan-in exceeds ILIM |
| `E_CSIF_GEOM_MISMATCH` | a level / grid / overlay / frame declared geometry ≠ geometry computed from inputs |
| `E_CSIF_TICKBASE` | `tick_num` or `tick_den` is 0 |
| `E_CSIF_FRAME_DEFAULT` | `default_frame_index` is not a `FRAME_BASE`, or out of range |
| `E_CSIF_DERIV_KIND` | unknown composition `node_kind` (load-bearing, cannot skip) |
| `E_CSIF_REF_SLOTS` | a frame's `reference_slot` ≥ `n_reference_slots`, or a referenced reference frame lacks `is_reference` |
| `E_CSIF_UNIT_CRC` | a unit's bytes fail their declared CRC |
| `E_CSIF_LIMIT` | any count exceeds its ILIM ceiling |

Unknown **skippable** chunks (animation/gain-map/ROI/extra-thumbnails on a reader that lacks the feature) are skipped by declared length and the canonical default rendition (§9.5.4) is produced. Unknown **non-skippable** chunks (a critical composition node kind a reader cannot perform) fail loudly (`E_CSIF_UNKNOWN_CRITICAL`) — a reader never produces a partial/broken render in place of an honest refusal.

---

Spec file conventions matched against `/home/caua/Documentos/Projetos-Pessoais/causticos/docs/CSE_FORMAT.md` (byte-exact `Off/Size/Field/Value` tables, little-endian-once, fail-loud loader with numbered reject codes, mechanism/policy framing).

---

I now have the exact CSE family conventions: 32-byte header with `magic + version + arch + flags`, fixed-width little-endian tables, explicit offset/size validation (`reject if file_off+file_size > cst_size`), numbered loader algorithm, "fail loud" stance, and the errno set. I have everything needed to write section 10 consistent with the dossier and the Caustic philosophy.

```markdown
## 10. Segurança, resiliência, conformance, test vectors

This section is the **trust contract** of CSIF. It specifies what a conformant
decoder MUST do *before* it touches a single pixel, how a damaged file fails
(loudly, locally, never silently), exactly which features a decoder of a given
profile/level is obligated to implement, and the normative golden corpus that
proves an independent implementation is correct and safe.

It is the most Caustic section of the spec, by construction. Image decoders are
the single most-attacked code path in modern computing — WebP CVE-2023-4863 (a
Huffman-table heap overflow weaponized as the BLASTPASS zero-click iMessage
exploit), the JBIG2 overflow behind NSO's FORCEDENTRY, and a continuous stream
of libpng/libjpeg-turbo/OpenEXR/libtiff CVEs — and in *every* case the root
cause was the format permitting something a decoder then trusted: a size product
that overflowed, an offset that dangled, a recursion with no bound, a color
field that meant "guess." The Caustic philosophy ("explicit, no magic, bounded
memory, honest closed op-set, mechanism vs policy, fail loud") **is** the modern
image-security playbook. CSIF therefore makes *mandatory* what its reference
formats made optional: every limit declared, every chunk integrity-checked,
every tile independent, every color/transfer/geometry field explicit with no
heuristic fallback, every byte range validated against the file size before use,
and a frozen golden-vector suite shipped with the spec.

The discipline mirrors the sibling format `kernel/cse.cst`, which already
rejects `mem_size < file_size` and `file_off + file_size > cst_size`, caps
`CSE_MAX_SEGS`, and returns enumerated negative error codes rather than
best-effort loading. CSIF generalizes that exact posture to a far richer
structure.

---

### 10.1 Error model — enumerated, negative, register-level

All decoder/validator failures are reported as enumerated `i64` negative codes,
in the same family as the kernel errnos (`abi.cst`). A conformant decoder NEVER
substitutes a default, clamps a value, or produces "best-effort" pixels for any
condition listed as a hard error. It returns the precise code AND the offending
locus (chunk type + chunk index + byte offset, or tile/level/item coordinates).

The CSIF error codes occupy a dedicated block (negative, little-endian `i64`):

| Code | Name | Meaning |
|---|---|---|
| 0 | `E_CSIF_OK` | success |
| -1 | `E_CSIF_MAGIC` | bad file magic or transmission-probe mismatch |
| -2 | `E_CSIF_VERSION` | unsupported container `version` |
| -3 | `E_CSIF_ENDIAN` | `endianness` field is not the declared little-endian value |
| -4 | `E_CSIF_TRUNCATED` | declared structure runs past end of file |
| -5 | `E_CSIF_CHUNK_LEN` | chunk `size` exceeds remaining file or `ILIM.max_chunk_size` |
| -6 | `E_CSIF_CRC` | chunk integrity hash mismatch |
| -7 | `E_CSIF_HASH` | whole-file / strong-hash mismatch |
| -8 | `E_CSIF_UNKNOWN_CRITICAL` | unknown chunk with `CHUNK_CRITICAL` set |
| -9 | `E_CSIF_ORDER` | chunk-ordering grammar violated |
| -10 | `E_CSIF_DUP` | illegal duplicate of a singleton chunk |
| -11 | `E_CSIF_DIMS` | dimension / size-product overflow or over-ceiling |
| -12 | `E_CSIF_ALLOC_CEILING` | required buffer exceeds `ILIM.max_alloc_bytes` or level cap |
| -13 | `E_CSIF_PROFILE` | file's required profile not implemented by decoder |
| -14 | `E_CSIF_LEVEL` | file's required level exceeds decoder/declared caps |
| -15 | `E_CSIF_CODEC` | unknown or unsupported `codec_id` |
| -16 | `E_CSIF_DERIV_CYCLE` | derivation / dependency graph contains a cycle |
| -17 | `E_CSIF_DERIV_DEPTH` | derivation depth exceeds `ILIM.max_deriv_depth` |
| -18 | `E_CSIF_GEOM_MISMATCH` | derived item output geometry ≠ geometry computed from inputs |
| -19 | `E_CSIF_REF` | item/frame/property reference target does not exist |
| -20 | `E_CSIF_RANGE` | declared byte range not ⊆ its container chunk; dangling/overlap |
| -21 | `E_CSIF_COLOR_UNDECLARED` | color signaling incomplete or uses a forbidden "Unspecified" code point |
| -22 | `E_CSIF_COLOR_INCONSISTENT` | CICP matrix inconsistent with channel model |
| -23 | `E_CSIF_TILE_CORRUPT` | a tile's integrity/decode failed (localized; see §10.3) |
| -24 | `E_CSIF_PASS_PARTIAL` | a progressive pass is incomplete (truncation; see §10.3) |
| -25 | `E_CSIF_AUX_BOUND` | aux-channel count / feature-layer bound exceeded |
| -26 | `E_CSIF_DICT_MISSING` | a referenced external dictionary is absent or hash-mismatched |
| -27 | `E_CSIF_MIN_DECODER` | file declares a `min_decoder_level` the decoder cannot meet |
| -28 | `E_CSIF_FEATURE_BOUND` | a declared feature-layer count (splines/patches/frames/MA-tree nodes) exceeds its header-declared maximum |

`E_CSIF_TILE_CORRUPT` and `E_CSIF_PASS_PARTIAL` are the only two codes that are
**recoverable**: per §10.3 the decoder MAY continue and return a *partial*
result alongside a status record, BUT only when the corruption is confined to
non-critical, independently-decodable units. Every other code is a **hard,
total** failure.

---

### 10.2 Decoder security requirements

A conformant decoder MUST perform the following, **in this order**, and MUST NOT
allocate any pixel/codec buffer until step (5) completes successfully. This is
the "the file is provably bounded before the codec runs" guarantee.

#### 10.2.1 Single-pass, offset-driven, non-scanning parse

CSIF is pure TLV (see container section): the parser advances by
`header + size + crc`, **never** scanning for a sync pattern, marker, or
recovery byte. Each chunk's `size` is validated against *remaining file length*
BEFORE the parser advances (the cse.cst `file_off + file_size > cst_size` guard,
generalized to every chunk). Marker-scanning parsers are a DoS and
parser-differential surface (baseline JPEG's `0xFFxx` hunt); CSIF forbids them.

**Canonical encoding invariant.** No two distinct byte sequences may parse to
the same logical image structure, and a given logical structure has exactly one
valid serialization (fixed field order, fixed integer widths, no optional
padding ambiguity outside explicitly-declared reserved holes). This kills the
parser-differential bug class and is what makes the golden vectors of §10.7
meaningful — re-serialization is bit-identical.

**Endianness is fixed and declared, never selected.** All container and codec
fields are little-endian (matching CSE / x86_64). The header carries an explicit
`endianness` byte whose only legal value is the declared little-endian constant;
any other value is `E_CSIF_ENDIAN`. CSIF deliberately bans a per-file byte-order
flag — TIFF's `II`/`MM` switch flips the entire parser and is a known
parser-differential nightmare. One endianness, declared, not runtime-selected.

#### 10.2.2 Mandatory limits descriptor (`ILIM`) and the bounded-decode contract

Every CSIF file MUST carry an `ILIM` (limits) descriptor (in IHDR's pre-IDAT
region; it is a `CHUNK_CRITICAL` chunk). `ILIM` states the worst-case resource
cost a reader may incur, in declared `u64` fields, so a reader knows its memory
budget from the header alone — before reading IDAT:

| Field | Type | Meaning |
|---|---|---|
| `max_width` | u32 | ≥ IHDR.width |
| `max_height` | u32 | ≥ IHDR.height |
| `max_pixels` | u64 | ≥ width·height (canvas pixel-count cap) |
| `max_tile_pixels` | u64 | ≥ tile_w·tile_h (bounds the per-tile working set) |
| `max_alloc_bytes` | u64 | the single largest buffer a conformant decode of this file requires |
| `max_components` | u16 | total color + aux/named channels |
| `max_aux_channels` | u16 | aux/named channels alone |
| `max_chunk_size` | u64 | largest legal chunk payload (bounds every skip/seek) |
| `max_items` | u32 | item-table entry count cap |
| `max_deriv_depth` | u16 | max depth of the DERIVED_FROM / dependency graph |
| `max_deriv_fanin` | u16 | max inputs to any one derived item |
| `max_frames` | u32 | animation frame count cap |
| `max_reference_slots` | u16 | live reference-frame buffers (bounds animation memory) |
| `max_feature_count` | u32 | per-kind cap for splines/patches/MA-tree nodes/regions |
| `max_decoded_dims` | u64 | declared max output W·H after any derivation/upscale |

The `ILIM` ceilings of a file MUST be ≤ the normative caps of the **level** it
declares (§10.5). A decoder rejects (`E_CSIF_LEVEL`) if any `ILIM` field exceeds
its supported level; it rejects (`E_CSIF_ALLOC_CEILING`) if `max_alloc_bytes`
exceeds the memory it is willing to commit.

#### 10.2.3 Integer-overflow-safe size math (widened arithmetic, mandatory)

All buffer-size computations are performed in widened arithmetic (u128
intermediate, or a checked-multiply that detects overflow) and compared against
the relevant `ILIM` ceiling BEFORE any allocation:

```
pixel_bytes  = ceil(bit_depth / 8) · channels          // per pixel, widened
row_bytes    = checked_mul(width,  pixel_bytes)          // u128
plane_bytes  = checked_mul(row_bytes, height)            // u128
total_bytes  = checked_add over all planes/aux/tiles     // u128
reject (E_CSIF_DIMS) if any intermediate overflowed
reject (E_CSIF_DIMS) if width  > ILIM.max_width  || height > ILIM.max_height
reject (E_CSIF_DIMS) if width·height > ILIM.max_pixels
reject (E_CSIF_ALLOC_CEILING) if total_bytes > ILIM.max_alloc_bytes
```

For float sample formats (`FLOAT16`/`FLOAT32`) `pixel_bytes` uses 2/4 per
sample. Tile working sets are computed the same way against `max_tile_pixels` so
the per-tile buffer is bounded **independent of full-image size** — this is the
exact gap that produced WebP CVE-2023-4863, closed structurally.

#### 10.2.4 Bounded memory from declared dimensions — no hidden allocation

CSIF's decode is freestanding-stdlib style: the **caller** supplies output and
scratch buffers (or a byte budget), and the codec writes only into them. A
conformant decoder MUST be able to decode:

- **any single tile** using memory bounded by `max_tile_pixels · pixel_bytes`
  plus the codec's *declared* scratch (alias table = `1<<precision` entries,
  ring window = `1<<window_log` bytes, MA-tree = declared node cap, color cache =
  `2^cache_bits · 4`, reference slots = `max_reference_slots` buffers). Every one
  of these is a header-declared field, so the working set is computable up front.
- **any single resolution level / mip level** sized from its declared `width`,
  `height` in the level/mip index.
- **any single requested region (ROI)** as the set of tiles intersecting it, one
  tile at a time.

No codec may allocate from header-controlled fields without the matching `ILIM`
ceiling check. The feature/animation/sub-image metadata layers (splines,
patches, MA-tree nodes, reference frames, derivation fan-in) are likewise capped
by declared fields (`max_feature_count`, `max_frames`, `max_reference_slots`,
`max_deriv_fanin`) — `E_CSIF_FEATURE_BOUND` / `E_CSIF_AUX_BOUND` on exceed. v1's
tiling bounded only the *pixels*; CSIF bounds the metadata too.

#### 10.2.5 Container invariants validated before any codec runs

The loader MUST verify the following and reject loudly on any violation. These
turn "parse defensively" into "the file is provably bounded" — the libavif /
libheif hardening checklist made *mandatory* rather than reader policy:

1. **Range containment** (`E_CSIF_RANGE`): every item / tile / level / stream
   byte range `[offset, offset+length)` is ⊆ its declared IDAT-class chunk in
   THIS file. No `construction_method` indirection, no `mdat`-anywhere, no
   external-file payload. Dangling and overlapping ranges are rejected. (Direct
   generalization of cse.cst's segment-range guard.)
2. **Identifier uniqueness** (`E_CSIF_DUP` / `E_CSIF_REF`): item ids, frame
   indices, property indices are unique; every reference target exists.
3. **Acyclic, depth-bounded derivation** (`E_CSIF_DERIV_CYCLE` /
   `E_CSIF_DERIV_DEPTH`): the DERIVED_FROM + dependency-mask graph is a DAG;
   composition nodes are DAG-by-construction (child index < parent index); depth
   ≤ `max_deriv_depth`, fan-in ≤ `max_deriv_fanin`. This is the decompression-
   bomb-by-recursion guard.
4. **Geometry reconciliation** (`E_CSIF_GEOM_MISMATCH`): each derived item's
   declared output geometry MUST equal the geometry computed from its inputs
   (grid: `rows·tile_w × cols·tile_h` clipped to `out_w × out_h`; overlay:
   canvas size). Mismatch is a hard reject, never "best effort."
5. **Primary present and closed** (`E_CSIF_REF`): the primary item exists, is a
   coded or derived image, and its full transitive dependency closure is present
   and itself valid.
6. **Pre-sized decode** (`E_CSIF_ALLOC_CEILING`): the declared
   `max_decoded_dims` reconciles with the assembled output so a reader pre-sizes
   (or pre-rejects) without speculative allocation.
7. **Singleton + ordering** (`E_CSIF_DUP` / `E_CSIF_ORDER`): the chunk-ordering
   grammar holds (IHDR first; `ILIM`, color, `ICOD`, property/aux/index chunks
   before the first IDAT; IDAT/tile chunks contiguous; IEND last); singletons
   appear at most once.

#### 10.2.6 Per-tile / per-unit isolation (the trusted-surface shrink)

Each tile (and each entropy stream, code-block, and item) is an **independent**
decode unit: its entropy coder state is reset at unit start (declared invariant;
no cross-unit prediction/context carry unless an explicit `cross_tile_prediction
= declared-neighbors` field says so), it is addressable via an explicit
offset/size index, and it carries an optional per-unit integrity hash. A
decoder MUST be able to decode one unit without reading another. Consequences:
(a) a corrupt unit damages only itself (§10.3); (b) parallel decode is a reader
policy that falls out for free; (c) the per-unit working set is the bound.

#### 10.2.7 Metadata trust boundary

EXIF / XMP / ICC / provenance blobs are treated as **opaque, length-bounded
bytes** for rendering purposes. The trusted decode core NEVER parses them to
make a geometry, memory, or color decision (it reads geometry from IHDR, color
from the explicit color chunks, orientation from the native IHDR field — see
§10.4). Their lengths are capped by `ILIM.max_chunk_size`. EXIF parsers are
their own CVE class; CSIF keeps them out of the trusted path entirely. The
native orientation field is authoritative; an embedded EXIF Orientation tag is
informational-only and MUST be ignored for rendering (the double-rotation
footgun, closed by declared precedence).

---

### 10.3 Error resilience and recovery

CSIF's resilience is *structural*, derived from the same independence that
delivers parallel/partial decode. There is no separate "error mode" — the
mechanisms below are always present; only their parameters are declared.

#### 10.3.1 Integrity layer

- **Per-chunk integrity.** Every chunk ends with a trailing checksum over
  `type ‖ flags ‖ payload` (flags are load-bearing in CSIF, so unlike PNG they
  are covered). The algorithm is a declared header field
  `checksum_algo ∈ {0=NONE, 1=CRC32-IEEE (poly 0xEDB88320), 2=CRC32C
  (Castagnoli)}`. A mismatch is `E_CSIF_CRC`, reported with chunk type + offset.
  A reader NEVER guesses whether a chunk is protected — `checksum_algo` says so.
- **Per-unit integrity.** The tile / level / stream index MAY carry, per entry,
  a `{offset, stored_size, uncompressed_size, checksum}` record (the algorithm
  is the same declared enum). The decoder verifies before decoding the unit.
- **Whole-file strong hash.** An optional terminal `IEND` field (and/or an
  `IHSH` chunk) carries a strong content hash (declared enum, e.g.
  `3=BLAKE3-256`, `4=SHA-256`) for end-to-end tamper-evidence and transport
  integrity, distinct from the per-chunk CRC's accidental-corruption role.
  Mismatch is `E_CSIF_HASH`. (Provenance §-level signing builds on this; the
  bare hash is the non-cryptographic floor.)
- **Transmission probe.** The file magic embeds a CRLF/lone-LF/EOF byte pattern
  (documented, not folklore) so transit damage from text-mode transfer is caught
  at byte 0 (`E_CSIF_MAGIC`), not at pixel 0. `IEND` is mandatory; its absence
  means a truncated file (`E_CSIF_TRUNCATED`).

One CRC/hash routine lives in the shared toolkit and is reused by container and
codecs (DRY).

#### 10.3.2 Localized corruption — the two recoverable codes

Because tiles/units are independent (§10.2.6), corruption is *contained*. The
decoder's behavior on a damaged unit is governed strictly by chunk criticality
and unit independence:

- **Critical-chunk corruption** (IHDR, `ILIM`, `ICOD`, color chunks, the chunk
  directory, a primary's required dependency): **hard, total failure** with the
  precise code. There is no rendering a header you cannot trust.
- **Ancillary / independent-unit corruption** (one tile of an independently-
  tiled image; one non-required aux channel; one animation frame that is not a
  keyframe dependency of the requested frame; one metadata blob): **recoverable**
  — the decoder MAY skip the unit and continue, returning `E_CSIF_TILE_CORRUPT`
  in a status record (§10.3.4) naming the exact `(item/tile/level/frame)`. The
  failing unit's pixels are filled with a **declared sentinel** (the format
  states the fill: either the canvas background color or a flagged "undefined"
  region in the status), NEVER silent garbage and NEVER a heuristic in-paint.

This is the honest middle ground between PNG (one bad byte can be unrecoverable)
and "best effort" (silent garbage). A reader gets *either* the correct pixels
*or* an explicitly-flagged hole — the JPEG2000 / AV1-tile localization property,
made an explicit, declared status.

#### 10.3.3 Truncation / streaming resilience

The progression structure (declared in `IPRG` / pass tables / quality layers)
makes truncation a **first-class declared state**, not a guess:

- Each pass / layer / resolution level is a self-delimited unit with an explicit
  offset+length in the index. A decoder reading a truncated file decodes only
  **complete** units and NEVER reads past a declared boundary (the cse.cst
  "never copy past file_size" discipline applied to passes).
- The minimum decodable unit (the DC/LF pass, or resolution level 0) is
  declared, so a reader knows what it gets from the first N bytes.
- On truncation the decoder returns `E_CSIF_PASS_PARTIAL` plus an honest status:
  "decoded K of N passes, output valid at resolution level L / quality M." The
  result is a *valid lower-fidelity image*, explicitly labeled — never a
  silently-degraded image pretending to be complete.

#### 10.3.4 Verification / decode result model — no magic boolean

A conformant verifier/decoder produces a **structured result**, never a single
pass/fail boolean:

```
{ container_valid     : bool,                // header/grammar/ranges/CRC all OK
  pixels_complete      : bool,                // no recoverable holes
  truncation           : { passes_decoded, passes_total, level, quality } | none,
  corrupt_units        : [ (kind, coords, code) ],   // localized failures
  unknown_skipped      : [ chunk_type ],      // forward-compat skipped chunks
  color_complete       : bool,                // §10.4
  first_hard_error     : code | E_CSIF_OK }   // the loud, total failure if any
```

"No file present," "present but a unit is corrupt," "present but truncated," and
"fully valid" are **distinct declared states**. Missing data is never
fabricated; a hard error is loud and specific. This mirrors the kernel's
fail-loud, bounded-error, register-level reporting stance.

---

### 10.4 Color & signaling conformance (fail-closed, no heuristics)

This is the strongest Caustic-vs-magic rule and it is a **correctness**
requirement, not a nicety. The single largest source of color bugs in the wild
is decoders silently assuming sRGB when signaling is absent.

- **Color is 100% determined by the explicit color chunks** (CICP triple +
  range, or an ICC profile, with an explicit `color_authority ∈ {CICP, ICC,
  ICC_WITH_CICP_HINT}` precedence field). A decoder NEVER infers gamma,
  primaries, the YCbCr↔RGB matrix, range, or sample numeric format from pixel
  data, channel count, or file extension.
- **"Unspecified" is FORBIDDEN.** A writer MUST commit to a real value for
  `color_primaries`, `transfer_characteristics`, and `matrix_coefficients`
  (CICP code point `2 = Unspecified` is illegal in CSIF). A decoder encountering
  an "Unspecified" or an out-of-range enum value FAILS CLOSED with
  `E_CSIF_COLOR_UNDECLARED` and the offending field — it does NOT substitute a
  default. Absence of all color signaling is the same hard error.
- **Consistency is checked, not assumed** (`E_CSIF_COLOR_INCONSISTENT`):
  `matrix_coefficients` MUST agree with the channel model (RGB ⇒ identity
  matrix; YCbCr ⇒ non-identity); an HDR transfer function (PQ) that requires
  color-volume metadata for correct rendering MUST carry it (declared
  dependency, not "HDR usually has this").
- **Sample format, endianness, packing, and float specials are declared.**
  Integer-vs-float, bit depth, byte order, and channel packing are explicit
  fields; lossless codecs MUST round-trip the exact bit pattern including
  NaN/Inf/signed-zero, and lossy codecs MUST declare their treatment of
  non-finite values.

`color_complete` in the result model is true only when every color axis the file
uses is fully and legally declared. A conformant encoder is **forbidden** from
emitting "Unspecified" — this is the encoder-side half of the contract.

---

### 10.5 Conformance profiles and levels

CSIF defines **profiles** (which codecs/features a decoder MUST implement) and
**levels** (numeric resource caps a decoder may refuse). A file declares its
required `profile : u8` and `level : u8` in IHDR. A decoder checks the match
FIRST and refuses cleanly (`E_CSIF_PROFILE` / `E_CSIF_LEVEL`) **before**
allocating, rather than attempting a partial, dangerous decode. This bounds the
attack surface and makes interop testable (the AV1-levels / HEVC-profiles
model). It also lets a file declare a `min_decoder_level` — the minimum decoder
capability required to render it correctly (e.g. for lossless transforms that
**cannot** be skipped) — and a decoder below that level refuses with
`E_CSIF_MIN_DECODER` rather than silently mis-decoding.

#### 10.5.1 Profiles (codec/feature subsets — closed enumerations)

A profile is a fixed enumeration over the codec registry and the feature layers
— never open-ended. All profiles defined now (no deferral), even where a slot
ships later as a real interface (never a fake decoder).

| `profile` | Name | MUST decode (codecs) | Features |
|---|---|---|---|
| 0 | `CORE` | `RAW(0)`, `QOI(1)`, `MODULAR(2)` | 8/16-bit int, single image, tiling, CICP color, alpha, per-chunk CRC, partial/ROI decode |
| 1 | `BASELINE` | CORE + `DCT(3)` | + lossy DCT, adaptive quant, progressive (DC→AC) passes, thumbnails-as-items |
| 2 | `ADVANCED` | BASELINE + `BLOCK(4)`, wavelet/`DWT`, `INDEXED`, `BILEVEL`, `VECTOR` | + VarDCT, resolution scalability, named aux channels, animation, derived images (grid/overlay/identity), feature layers (patches/splines/noise), float HDR (F16/F32), HDR color-volume + gain maps |
| 3 | `GPU` | ADVANCED + the hardware block-format codecs and transcodable supercompression | + mip/array/cube/3D, direct-upload layout, transcode targets |
| 4 | `PRO` | ADVANCED + `RAW_LOSSLESS`, `JPEG_TRANSCODE` | + deep images, multipart/parts, multi-illuminant raw + develop opcodes, byte-exact JPEG reconstruction |
| 5 | `FULL` | every registered codec incl. `NEURAL(5)` and `CMIX` | every feature; requires an inference runtime for `NEURAL` |

A decoder advertises the highest profile it implements; it MUST decode every
profile ≤ that, at the level it advertises. An unknown `codec_id` in a chunk it
must render is `E_CSIF_CODEC` (loud, no guessing) — but a file MAY only use codec
ids inside its declared profile, which the validator checks.

#### 10.5.2 Levels (numeric caps)

Levels cap worst-case decoder work so a decoder can refuse out-of-bounds files
deterministically. The `ILIM` ceilings of a conformant file MUST be ≤ the caps
of its declared level. (Numbers below are the v1 normative caps; they are part
of the frozen spec.)

| `level` | max_pixels | max_alloc_bytes | max_tile_pixels | max_aux | max_items | max_deriv_depth | max_frames | max_ref_slots |
|---|---|---|---|---|---|---|---|---|
| 0 (`L0`) | 2²⁰ (1 MP) | 64 MiB | 2¹⁶ | 1 | 64 | 2 | 1 | 1 |
| 1 (`L1`) | 2²⁴ (16 MP) | 512 MiB | 2¹⁸ | 4 | 1024 | 4 | 256 | 4 |
| 2 (`L2`) | 2²⁸ (256 MP) | 4 GiB | 2²⁰ | 16 | 65536 | 8 | 65536 | 16 |
| 3 (`L3`) | 2³² (4 GP) | 32 GiB | 2²² | 64 | 2²⁰ | 16 | 2²⁰ | 64 |

A decoder MUST refuse (`E_CSIF_LEVEL`) any file whose declared level — or whose
`ILIM` fields — exceed what it supports, before allocating. This is the explicit
capability negotiation that makes "the decoder advertises exactly what it
supports" true.

---

### 10.6 Conformance obligations summary (normative checklist)

A decoder is **conformant at (profile P, level L)** iff it:

1. Parses offset-driven, never scanning; validates every chunk `size` against
   remaining file length before advancing; treats the file as canonical.
2. Rejects bad magic/version/endianness, missing/extra singletons, and
   ordering-grammar violations with the precise code.
3. Verifies the declared `checksum_algo` on every chunk it reads; verifies
   per-unit and whole-file hashes when present; reports mismatches with locus.
4. Validates ALL §10.2.5 container invariants (range containment, id uniqueness,
   acyclic+depth-bounded derivation, geometry reconciliation, primary closure,
   pre-sizing) before running any codec.
5. Computes every size in widened/checked arithmetic against `ILIM`; allocates
   nothing before validation; decodes any single tile/level/ROI in bounded,
   caller-provided memory with only declared scratch.
6. Implements every codec and feature in profile ≤ P; refuses
   `E_CSIF_PROFILE`/`E_CSIF_LEVEL`/`E_CSIF_MIN_DECODER` cleanly otherwise.
7. Determines color 100% from explicit signaling; fails closed on
   Unspecified/underspecified/inconsistent color; assumes nothing.
8. For lossless codecs: reproduces the reference output **bit-exactly**
   (max abs error 0), preserving float bit patterns incl. NaN/Inf/−0.
9. For lossy codecs: implements the **spec-frozen, fixed-point inverse**
   (IDCT/dequant/inverse-wavelet/filters), so decode is deterministic and
   reproduces the reference output within the stated tolerance (§10.7).
10. On unknown chunks: skips with `CHUNK_CRITICAL=0` (recording the skip),
    fails `E_CSIF_UNKNOWN_CRITICAL` with `CHUNK_CRITICAL=1`.
11. On corruption/truncation: localizes per §10.3, returns the structured result
    model, never emits silent garbage and never hangs.

A conformant **encoder** additionally: emits canonical serialization; never
emits "Unspecified" color; sets `ILIM` ≥ the true cost and ≤ the declared level;
sets `is_lossless` consistently (`near_lossless_delta = 0 ⇔ is_lossless`);
declares `min_decoder_level` whenever it uses an unskippable transform; and lands
within the declared metric band for its quality target (§10.7.4).

---

### 10.7 Reference test vectors

The normative conformance corpus ships **in-repo**, frozen at self-host like the
syscall ABI, and is exercised by a `verify.sh`-style harness (the same discipline
the OS already uses: reuse a built image, run many checks fast, assert exact
results). The corpus has four parts. Determinism is a hard prerequisite: a lossy
codec is only testable against a "golden" image because CSIF mandates the
spec-frozen fixed-point inverse — the *decoder* is deterministic even though the
*encoder* is free (the only float freedom is the encoder's quality search).

#### 10.7.1 Corpus layout

```
testvectors/
  lossless/      <name>.csif  +  <name>.ref.raw  +  <name>.ref.hash   (per vector)
  lossy/         <name>.csif  +  <name>.ref.raw  +  <name>.tol.txt    (tolerance)
  corruption/    <name>.csif  +  <name>.expect   (expected error code + locus)
  fuzz/          seed/*.csif  +  the structural mutation grammar (§10.7.5)
  MANIFEST       sha256 of every file + the spec version it was frozen at
```

`*.ref.raw` is a raw pixel dump with a sidecar declaring exact
`{width, height, channels, sample_format, endianness, colorspace}` so the
comparison is unambiguous. `*.ref.hash` is the BLAKE3-256 of the canonical raw
dump.

#### 10.7.2 Bit-exact lossless vectors

For every lossless codec (`RAW`, `QOI`, `MODULAR`, `RAW_LOSSLESS`,
`BILEVEL`-lossless, `INDEXED`-lossless, the GPU block→RGBA unpack,
`JPEG_TRANSCODE`'s `reconstruct_source`) the corpus provides input pixels, the
`.csif`, and the reference decoded bytes. **Pass = bit-exact**: decoded output
hash equals `.ref.hash`, max-abs-error = 0. Coverage matrix (each a vector):

- every bit depth (8/10/12/16) and float (F16/F32) the codec supports, with
  float specials (NaN/Inf/−0) present and required to round-trip exactly;
- every channel model (Gray/GrayA/RGB/RGBA/CMYK) + ≥1 named-aux (depth, alpha-
  as-aux) vector;
- every reversible transform in the MODULAR stack (each RCT family member,
  PALETTE, DELTA_PALETTE, SQUEEZE) and the full predictor set (None/Sub/Up/
  Average/Paeth/Gradient/Weighted) + MA-tree contexts + LZ window + color cache;
- single-tile and multi-tile (independence proof: per-tile decode == whole-image
  decode);
- a Squeeze/responsive vector where every truncation prefix decodes to the
  declared lower-resolution image bit-exactly.

#### 10.7.3 PSNR/tolerance-bounded lossy vectors

For lossy codecs (`DCT`, `BLOCK`/VarDCT, `DWT`-irreversible, near-lossless
MODULAR, the lossy-float GPU schemes) the corpus provides the `.csif` and the
reference output of the **spec-frozen fixed-point inverse**. Two assertions:

1. **Decoder determinism (bit-exact against the reference decode).** Because the
   inverse transform/dequant/filter arithmetic is frozen, a conformant decoder
   MUST reproduce `*.ref.raw` bit-exactly. A hollow decoder cannot pass — it
   must hit exact pixels. This is the JPEG T.83 lesson taken to its limit (CSIF
   mandates *one* inverse, not "any reasonable IDCT").
2. **Quality-bound vs source (encoder-conformance, optional but defined).** Each
   lossy vector's `.tol.txt` declares `{metric_id, target, eps}`; the achieved
   metric of the encoded `.csif` measured against the *original source* MUST lie
   in `[target−eps, target+eps]`. Metrics are the closed registry (PSNR,
   PSNR-HVS-M, MS-SSIM, SSIMULACRA2, butteraugli max/3-norm); the metric's input
   colorspace transform (e.g. → XYB) is frozen so the score is reproducible.

#### 10.7.4 Per-pass / scalability vectors

Vectors that assert the *progressive* and *scalable* contracts: a single `.csif`
plus a table of `(prefix_bytes → expected output hash, declared quality/level)`.
Truncating at each declared pass/layer/resolution boundary MUST decode to the
labeled output (bit-exact for lossless responsive; tolerance-bound for lossy
passes), and the decoder MUST return `E_CSIF_PASS_PARTIAL` with the correct
"K of N" status when truncated mid-pass.

#### 10.7.5 Corruption corpus (fail-safe assertions)

The corruption corpus is as important as the golden images — it proves decoders
fail **predictably and safely**. Each vector pairs a deliberately-malformed
`.csif` with an `.expect` file naming the exact error code AND locus. Mandatory
categories (each with multiple instances):

| Category | Asserted result |
|---|---|
| truncated at every chunk boundary and mid-chunk | `E_CSIF_TRUNCATED` |
| flipped bit in a chunk body / type / flags | `E_CSIF_CRC` (located) |
| whole-file hash mismatch | `E_CSIF_HASH` |
| `width·height·channels·bytes` overflowing u64 | `E_CSIF_DIMS` (no allocation occurs) |
| `ILIM` field over the declared level | `E_CSIF_LEVEL` |
| dimension/`ILIM` over decoder limit | `E_CSIF_ALLOC_CEILING` |
| item byte range dangling / overlapping / outside its IDAT | `E_CSIF_RANGE` |
| derivation cycle / depth > `max_deriv_depth` | `E_CSIF_DERIV_CYCLE` / `E_CSIF_DERIV_DEPTH` |
| derived geometry ≠ computed-from-inputs | `E_CSIF_GEOM_MISMATCH` |
| dangling item/frame/property reference | `E_CSIF_REF` |
| unknown chunk with `CHUNK_CRITICAL=1` | `E_CSIF_UNKNOWN_CRITICAL` |
| unknown chunk with `CHUNK_CRITICAL=0` | skipped + recorded, decode succeeds |
| out-of-order / duplicate singleton | `E_CSIF_ORDER` / `E_CSIF_DUP` |
| color = "Unspecified" / out-of-range / inconsistent | `E_CSIF_COLOR_UNDECLARED` / `E_CSIF_COLOR_INCONSISTENT` |
| unknown `codec_id` in a required chunk | `E_CSIF_CODEC` |
| `min_decoder_level` above tester's level | `E_CSIF_MIN_DECODER` |
| corrupt single tile of an independently-tiled image | `E_CSIF_TILE_CORRUPT`, rest decodes, hole flagged |
| oversized EXIF/XMP/ICC blob | `E_CSIF_CHUNK_LEN`, decode succeeds (metadata skipped) |
| missing referenced external dictionary | `E_CSIF_DICT_MISSING` |
| TIFF-style attempt at a second endianness value | `E_CSIF_ENDIAN` |

A decoder passes a corruption vector iff it returns the exact expected code and
locus AND does not allocate, hang, read out of bounds, or emit pixels for any
hard-error case. The harness runs every decoder under a memory ceiling and a
bounded wall-clock deadline; an OOM, a sanitizer trip, or a deadline overrun is
a **failure** even if the return code is correct (resource-bound conformance).

#### 10.7.6 Fuzz corpus and structural mutation grammar

Beyond the fixed corruption vectors, CSIF ships a **structural mutation grammar**
for continuous fuzzing: a description of every field's legal range and the
relationships the validator checks (range containment, size products, graph
acyclicity, color consistency), from which a fuzzer derives both *structurally-
valid-but-extreme* inputs (max dims, deep derivation chains at the depth cap,
maximum aux channels, maximum tiles) and *targeted-invalid* inputs (each
relationship violated in isolation). The harness asserts the same fail-safe
invariants as §10.7.5: **no hard-error input may ever crash, hang, OOM, read
out of bounds, or emit pixels.** Seeds include one minimal valid file per codec
and per profile so a coverage-guided fuzzer starts from the whole feature
surface. Because parsing is canonical and offset-driven, the fuzzer cannot wedge
the parser into an unbounded scan — every mutation either parses bounded or is
rejected at the first invalid field.

---

### 10.8 Why this section is the format's strongest Caustic expression

Every guarantee above is one of the seven non-negotiables made structural rather
than aspirational:

- **Explicit / no magic:** every limit, every byte range, every color axis, every
  integrity algorithm, every error is a declared field or an enumerated code. The
  decoder reads facts; it never guesses, never defaults, never sniffs.
- **Honest closed op-set:** profiles and levels are closed enumerations over the
  codec registry and feature layers; the error set is enumerated; "Unspecified"
  is banned. No escape hatch, no side channel.
- **Mechanism vs policy:** the container validates ranges, graphs, and hashes
  (mechanism); how a viewer tone-maps, what it does with a skipped chunk, which
  metric an encoder optimizes (policy) lives above the trusted core.
- **No workarounds / no hollow impls:** a hollow decoder cannot pass §10.7 — the
  golden vectors demand bit-exact pixels via the spec-frozen inverse, and the
  corruption corpus demands exact codes with no allocation.
- **Bounded memory / no hidden allocation:** `ILIM` + widened size math + per-unit
  isolation make the worst-case working set computable from the header and
  enforced before the codec runs; tiling delivers partial decode in bounded
  memory.
- **DRY:** one CRC/hash routine, one error model, one result model, one corpus
  harness, shared by container and every codec.
- **Family of causticos's own formats:** magic+version+flags header, fixed-width
  little-endian tables, explicit offset/size validation, enumerated negative
  error codes, fail-loud-never-hang — the exact discipline of `cse.cst`,
  generalized from a static executable loader to a world-class image container.
```

---

I have a clear picture of the CSE family conventions: little-endian, fixed-width byte tables with Off/Size/Field/Value columns, numbered loader algorithms, explicit error codes, fail-loud posture, declared everything. Now I'll write section 11 — the GPU texture & transcoding spec — fully consistent with the Caustic philosophy and the established CSIF chunk/codec model referenced throughout the dossier.

I have everything I need. Here is the spec section.

---

## 11. Texturas GPU & transcoding (KTX2/Basis-class)

This section specifies the **GPU-texture codec family** and the **texture storage model** of CSIF: how the format carries block-compressed texels (BC/ETC/EAC/ASTC) or a transcodable intermediate (UASTC/ETC1S-class) that becomes the running GPU's native block format at load, with an explicit mip/array/cube/3D layout, declared sRGB-vs-linear texel interpretation, declared alpha association, and a declared zero-copy upload contract for the compositor.

The whole point of this family is one sentence: **the bytes on disk ARE the texels the GPU samples** (for the direct block formats) or **transcode block-to-block with no pixel decode** (for the intermediate formats). The container stays pure **MECHANISM** — it dispatches by `codec_id`, validates byte ranges, and advertises geometry — while every codec is **POLICY** behind the uniform `{decode, encode}` vtable. Nothing in this section adds a side channel, an implicit default, or a heuristic: every block format, mip level, face, transfer function, alpha mode, and alignment is a declared field a reader reads.

This section is **normative**. All multi-byte fields are **little-endian** (the CSIF container endianness declared in §2, IHDR). All scalar struct fields are `i64`-or-smaller as the byte tables state and are laid out exactly as written.

---

### 11.1 Position in the container model (recap of the seams it reuses)

CSIF already defines (earlier sections) the substrate this family plugs into. This subsection states precisely which existing seams are reused so that **nothing is reimplemented** (DRY) and the GPU path is honestly part of the one container:

- **Codec registry + ICOD** (§3): a `codec_id` selects a codec; ICOD carries the closed, versioned, codec-owned `params` blob whose layout is fixed by `(codec_id, codec_version)`. GPU block formats and transcodable intermediates are new `codec_id` values in that same registry (§11.3). The container never learns what BC7 or ASTC *are* — it hands the payload to the codec, exactly as it hands DCT data to codec 3.
- **Item table (`ITBL`) + byte-range validation** (§ HEIF-model section): each coded unit (here: each mip level / layer / face slice) is an item or an `IDAT`-resident range with a declared `{offset, length}` that the loader validates ⊆ its `IDAT` chunk before any allocation. The GPU path reuses this exact discipline for the level index (§11.5).
- **Color encoding (`COLR`/CICP)** (§ color section): the texel transfer function and primaries are the same closed CICP enums declared in `COLR`; the GPU descriptor (§11.7) does **not** redeclare color — it adds only the GPU-specific *interpretation hint* (UNORM vs SRGB *view*) and a hard consistency rule against `COLR`.
- **Tiling** (§ JPEG2000/HEIF sections): tiling composes with mips — the largest mip levels MAY be tiled with the existing tile machinery. A GPU texture is, structurally, an array of levels each of which is an array of (layer, face, slice) sub-resources, each of which MAY be tiled.
- **Integrity (`crc` per chunk / per tile)** (§ security section): each level/sub-resource range carries the same declared checksum field as every other CSIF unit. A corrupt level fails loud and localized.
- **Shared toolkit** (§ toolkit): the supercompression entropy stage (Zstd-class / rANS) is the **same** `entropy` module the lossless codecs use; the software-decode fallback (unpack blocks → RGBA) reuses the `color` module. The GPU family adds no private entropy coder.

A CSIF file is a **GPU texture** when its primary coded item's `codec_id` is in the GPU block-format range or the transcodable-intermediate range (§11.3) **and** it carries an `ITEX` chunk (§11.4) and an `IMIP` chunk (§11.5). The presence of `ITEX` is the explicit, declared signal — there is no inference of "this looks like a texture."

---

### 11.2 Design invariants (the contract every reader and writer obeys)

1. **Block format is declared, never inferred.** The exact hardware format is a `codec_id` (a closed registry member), and its block geometry (`block_w`, `block_h`, `bytes_per_block`) is a declared field in the `GPUBLK` descriptor (§11.6). A reader knows the full block layout from the headers alone — zero out-of-band knowledge (no `vkFormat`-elsewhere indirection).
2. **The mip chain is an explicit index.** Per-level `{file_off, stored_size, vram_size, width, height, depth}` are all written. No "mips are contiguous", no "each level halves", no "level dimensions are derived and trusted" — dimensions are written *and* must equal the formula `max(1, base >> level)` under the declared `rounding_mode`; a mismatch is a hard error (§11.5).
3. **Dimensionality is declared.** `tex_kind` (2D / 2D_ARRAY / CUBE / CUBE_ARRAY / 3D) is an explicit enum; `depth`, `layer_count`, `face_count` are explicit; the iteration order within a level is a declared constant (`SUBRES_ORDER`), and the cube face order is a declared constant (`FACE_ORDER`). No geometry is inferred from counts.
4. **Texel transfer + primaries are declared and consistent.** The texel transfer function is the CICP `transfer` from `COLR`; the GPU descriptor adds only `view_kind` (UNORM vs SRGB hardware decode) and the loader **enforces** that `view_kind == SRGB ⇒ COLR.transfer` is an sRGB-class curve. Inconsistency is a loud error, never a silent pick. There is no implicit "RGB means sRGB."
5. **Alpha mode is the declared 4-way enum** (`ALPHA_NONE | ALPHA_STRAIGHT | ALPHA_PREMUL | ALPHA_PREMUL_LINEAR`), required for any GPU-texture payload. The compositor selects its blend/filter path from this field with no guess.
6. **Transcoding target is an explicit argument, never a guess.** A transcodable-intermediate codec's `decode` takes the **target** block format `codec_id` as an argument (`decode(target_codec_id, …)`). The codec never inspects the GPU; the caller — which knows the device's supported formats from a separate device query — names the target. The producible target set is declared in `ICAP` (§11.10).
7. **Supercompression is a separable, declared layer.** A container-level `supercompress_id` (NONE / ZSTD / RAW) applied over level payloads is orthogonal to the codec; `stored_size` vs `vram_size` in `IMIP` makes the on-disk-vs-in-VRAM delta explicit.
8. **Bounded memory, no hidden allocation.** A `decode` call names a single `(level, layer, face)` sub-resource and writes into a **caller-provided** buffer of declared `vram_size`. The decoder never materializes the whole pyramid. Smallest-first on-disk ordering (when declared) makes progressive streaming a forward read.
9. **Direct upload is a positively-advertised capability, never probed.** The `DIRECT_UPLOADABLE` bit in `GPUBLK` is set **only** when (a) `codec_id` is a hardware block format and (b) the layout/alignment invariants of §11.8 hold. A reader takes the zero-copy DMA path *because the file says it may*, not because it sniffed the bytes.
10. **Honest sequencing for slots that need a GPU/encoder backend.** Every GPU codec exposes a **real** software-decode `decode` (block-unpack to RGBA) so screenshots and non-GPU display always work. An `encode` (a real block compressor) MAY ship later as an honestly-sequenced interface slot returning `E_CSIF_UNSUPPORTED` until implemented — **never a fake encoder, never a stub that pretends to compress.** The transcode `decode(target)` is real from day one for any target in the declared `ICAP` set; a target not in that set returns `E_CSIF_UNSUPPORTED` loudly.

---

### 11.3 Codec registry additions (closed, contiguous block ranges)

The GPU-texture codecs occupy a **reserved, contiguous** region of the closed codec registry. They are ordinary CSIF codecs behind the same `{decode, encode}` vtable; the only interface extension is that `decode` for a transcodable intermediate takes a target `codec_id` (§11.9). Unknown `codec_id` fails loud (`E_CSIF_UNKNOWN_CODEC`) as for any codec — the GPU range is **not** special-cased by the container.

> **Disambiguation (mandatory):** the existing `codec_id = 4 = BLOCK` is the **CPU** AVIF/VarDCT-class codec (recursive partition, ADST/IDTX, CDEF, etc.). It is **not** a GPU hardware block format. The hardware block formats below get their **own** `codec_id` range and MUST never be conflated with codec 4.

**Direct hardware block formats** (the bytes ARE the texels; decode = software unpack, the GPU samples them natively):

| codec_id | Name | Block | Bytes/blk | Channels carried | Notes |
|---|---|---|---|---|---|
| 10 | `BC1` | 4×4 | 8 | RGB (+1-bit A) | DXT1 |
| 11 | `BC2` | 4×4 | 16 | RGBA (4-bit A) | DXT3 |
| 12 | `BC3` | 4×4 | 16 | RGBA | DXT5 |
| 13 | `BC4` | 4×4 | 8 | R | 1-channel (height/mask) |
| 14 | `BC5` | 4×4 | 16 | RG | tangent normals |
| 15 | `BC6H` | 4×4 | 16 | RGB half-float | HDR; `view_kind` MUST be LINEAR |
| 16 | `BC7` | 4×4 | 16 | RGBA | high quality |
| 20 | `ETC2_RGB` | 4×4 | 8 | RGB | |
| 21 | `ETC2_RGBA` | 4×4 | 16 | RGBA | |
| 22 | `ETC2_RGB_A1` | 4×4 | 8 | RGB (+1-bit A) | punch-through alpha |
| 23 | `EAC_R11` | 4×4 | 8 | R | |
| 24 | `EAC_RG11` | 4×4 | 16 | RG | |
| 30 | `ASTC` | variable | 16 | RGBA | footprint in `params` (`block_w`,`block_h`); always 128-bit blocks |

**Transcodable intermediate formats** (decode = block-to-block transcode to a declared target; or software unpack to RGBA as the universal fallback):

| codec_id | Name | Basis | Quality / size | Notes |
|---|---|---|---|---|
| 31 | `UASTC_INTERMEDIATE` | ASTC-4×4 superset | high quality, larger | transcodes to ASTC directly + down to BC7/BC1/etc. |
| 32 | `ETC1S_INTERMEDIATE` | ETC1-subset + global codebook | small | transcodes to BC1/BC3/ETC2/ASTC via codebook remap |

**Reserved ranges:** `33..39` reserved for future transcodable intermediates; `40..63` reserved for future hardware block formats (e.g. PVRTC, ASTC-3D, future BCn). A reserved-but-unimplemented `codec_id` is **not** present in any file until defined; encountering an undefined `codec_id` is `E_CSIF_UNKNOWN_CODEC` (loud), never a guess.

ASTC's footprint is **not** baked into the `codec_id` (one `ASTC` id, footprint in `params`) precisely to keep the registry closed and small while making the variable footprint an explicit declared field; readers MUST read `block_w`/`block_h` from `GPUBLK`, never infer footprint from the id.

---

### 11.4 `ITEX` — texture geometry descriptor (chunk)

`ITEX` declares the full multi-dimensional geometry of the texture. It is **mandatory** for any GPU-texture file and MUST appear before the first `IDAT`-class chunk (per the §ordering grammar). It is a critical chunk (`CHUNK_CRITICAL` set): a reader that does not understand `ITEX` MUST NOT attempt to render the texture.

**`ITEX` payload (fixed 48 bytes, little-endian):**

| Off | Size | Field | Type | Valid range / meaning |
|---|---|---|---|---|
| 0x00 | 4 | `itex_version` | u32 | `1` |
| 0x04 | 4 | `tex_kind` | u32 (enum) | `0`=TEX_2D, `1`=TEX_2D_ARRAY, `2`=TEX_CUBE, `3`=TEX_CUBE_ARRAY, `4`=TEX_3D |
| 0x08 | 4 | `base_width` | u32 | level-0 width, ≥ 1 |
| 0x0C | 4 | `base_height` | u32 | level-0 height, ≥ 1 |
| 0x10 | 4 | `base_depth` | u32 | level-0 depth; MUST be `1` unless `tex_kind==TEX_3D` |
| 0x14 | 4 | `layer_count` | u32 | array layers; ≥ 1; MUST be `1` unless `tex_kind` is ARRAY or CUBE_ARRAY |
| 0x18 | 4 | `face_count` | u32 | `1` (non-cube) or `6` (CUBE / CUBE_ARRAY); any other value = reject |
| 0x1C | 4 | `level_count` | u32 | number of mip levels; ≥ 1; ≤ `1 + floor(log2(max(base_width,base_height,base_depth)))` |
| 0x20 | 4 | `subres_order` | u32 (enum) | iteration order inside a level; `0`=LAYER_FACE_SLICE (canonical) |
| 0x24 | 4 | `face_order` | u32 (enum) | `0`=POSX_NEGX_POSY_NEGY_POSZ_NEGZ (canonical) |
| 0x28 | 4 | `slice_order` | u32 (enum) | `0`=ASCENDING_Z (canonical) |
| 0x2C | 4 | `reserved0` | u32 | MUST be `0` |

**Validation (loader, before any allocation):**
- `tex_kind` MUST be a defined enum value, else `E_CSIF_TEX_KIND`.
- The `base_depth`/`layer_count`/`face_count` constraints above MUST hold for the declared `tex_kind`, else `E_CSIF_TEX_GEOM`.
- `level_count` MUST be within the stated bound, else `E_CSIF_TEX_LEVELS`.
- `subres_order`, `face_order`, `slice_order` MUST be the canonical declared constants for `itex_version = 1` (other values are reserved for future versions and reject loudly now). The orders are written even though only one value is currently legal, so they are never *assumed* — a future version may add orders without changing how a v1 reader reasons.

**Sub-resource count per level** = `layer_count × face_count × depth(level)`, where `depth(level) = max(1, base_depth >> level)` under the declared rounding (§11.5). Array layers do **not** reduce across mips; 3D depth slices **do**. Cube faces are exactly `face_count` per (level, layer).

The canonical on-disk iteration **within one level** (when `subres_order = LAYER_FACE_SLICE`) is:

```
for layer in 0..layer_count:
    for face in 0..face_count:          # cube faces in FACE_ORDER
        for z in 0..depth(level):       # 3D slices in SLICE_ORDER
            <one (level,layer,face,z) sub-resource of block bytes>
```

This order, the face order, and the slice order are **declared**, not assumed, so an independent reader reconstructs the exact layout from the header alone.

---

### 11.5 `IMIP` — mip/sub-resource index (chunk)

`IMIP` is the explicit level index: it makes every level — and, at finer granularity, every `(level, layer, face)` sub-resource — independently addressable by `{file_off, stored_size, vram_size}` and declares each level's dimensions. It is **mandatory** for GPU-texture files, critical, and MUST precede the first `IDAT`. It mirrors CSE's explicit segment table (vaddr/file_off/file_size/mem_size all spelled out, nothing inferred).

**`IMIP` header (16 bytes):**

| Off | Size | Field | Type | Meaning |
|---|---|---|---|---|
| 0x00 | 4 | `imip_version` | u32 | `1` |
| 0x04 | 4 | `level_order` | u32 (enum) | `0`=LARGEST_FIRST, `1`=SMALLEST_FIRST (streaming-friendly) |
| 0x08 | 4 | `granularity` | u32 (enum) | `0`=PER_LEVEL, `1`=PER_SUBRESOURCE |
| 0x0C | 4 | `rounding_mode` | u32 (enum) | `0`=DOWN (floor), `1`=UP (ceil) — how odd dimensions halve |

Then **per-level records** (`level_count` of them, ordered by the *logical* level index 0..level_count-1 regardless of `level_order`; `level_order` describes only the **on-disk byte placement**, not the table order):

**Per-level record (`granularity == PER_LEVEL`, 40 bytes each):**

| Off | Size | Field | Type | Meaning |
|---|---|---|---|---|
| +0x00 | 4 | `level_index` | u32 | logical level, 0 = full-res |
| +0x04 | 4 | `level_width` | u32 | MUST equal `max(1, base_width >> level_index)` under `rounding_mode` |
| +0x08 | 4 | `level_height` | u32 | MUST equal the analogous formula |
| +0x0C | 4 | `level_depth` | u32 | MUST equal the analogous formula (3D only; else 1) |
| +0x10 | 8 | `file_off` | u64 | byte offset of this level's data, **within its declared `IDAT` chunk** |
| +0x18 | 8 | `stored_size` | u64 | bytes on disk (post-supercompression) |
| +0x20 | 8 | `vram_size` | u64 | bytes after supercompression is undone = the size the GPU resource needs for this level |

When `granularity == PER_SUBRESOURCE`, each level record is **followed** by `sub_count = layer_count × face_count × depth(level)` sub-resource records, in the declared `subres_order`:

**Per-sub-resource record (28 bytes each):**

| Off | Size | Field | Type | Meaning |
|---|---|---|---|---|
| +0x00 | 4 | `layer` | u32 | array layer index |
| +0x04 | 4 | `face` | u32 | cube face index (FACE_ORDER) or 0 |
| +0x08 | 4 | `slice` | u32 | 3D z-slice (SLICE_ORDER) or 0 |
| +0x0C | 8 | `file_off` | u64 | offset within the `IDAT` chunk |
| +0x14 | 8 | `stored_size` | u64 | on-disk bytes for this sub-resource |

> Note: when `granularity == PER_SUBRESOURCE`, `vram_size` per sub-resource is **computed** (not stored) as `blocks_x × blocks_y × bytes_per_block` for that sub-resource's dimensions (from `GPUBLK`, §11.6), because for a fixed block format the uncompressed size is fully determined by geometry. The per-level `vram_size` remains the authoritative total for the level. This avoids storing a derivable number while keeping the on-disk (`stored_size`, possibly supercompressed) explicit.

**Per-level integrity:** each level record (and each sub-resource record when present) is covered by the chunk's CRC (§security). For finer error localization a writer MAY additionally emit an `IMIP`-parallel `ITCK` (texture-checksum) chunk: one `crc32`/declared-hash per level or per sub-resource, keyed identically. A mismatch reports the exact `(level, layer, face, slice)` loudly (`E_CSIF_TEX_CORRUPT`) and the rest of the texture still decodes.

**Validation (loader, before allocation):**
- For every record: `file_off + stored_size ≤ (declared IDAT chunk length)`, else `E_CSIF_RANGE` (dangling/overflow rejected in widened u64 arithmetic).
- `level_width/height/depth` MUST equal the rounding formula exactly, else `E_CSIF_MIP_DIMS` (dimensions are written **and** checked — never stored-and-blindly-trusted, never silently recomputed-and-overwritten).
- The set of `level_index` values MUST be exactly `{0 .. level_count-1}` with no gaps/dupes, else `E_CSIF_MIP_SET`.
- `vram_size` (per level) MUST equal the sum of its sub-resources' computed sizes, else `E_CSIF_MIP_SIZE`.

**Bounded partial decode:** a reader requesting level *L* of `(layer, face)` looks up the record, allocates exactly its `vram_size` (or computed sub-resource size) in a caller buffer, reads only `stored_size` bytes from disk, undoes supercompression (if any) into the buffer, and uploads/decodes — touching no other level. `SMALLEST_FIRST` on-disk order makes "upload the small mips first, then refine" a forward read.

---

### 11.6 `GPUBLK` — block-format descriptor (ICOD `params` sub-block)

For a GPU block-format or transcodable-intermediate codec, the codec-owned `ICOD.params` blob (§3) **is** the `GPUBLK` descriptor. The container treats it as opaque and dispatches by `codec_id`; the codec parses it. Its layout is fixed by `(codec_id, codec_version)`. This is the KObject-vtable analogy: the codec is fully self-described, the container knows nothing of BC7/ASTC internals.

**`GPUBLK` payload (32 bytes, little-endian):**

| Off | Size | Field | Type | Meaning |
|---|---|---|---|---|
| 0x00 | 4 | `gpublk_version` | u32 | `1` |
| 0x04 | 2 | `block_w` | u16 | texels per block, X (e.g. 4; ASTC 4..12) |
| 0x06 | 2 | `block_h` | u16 | texels per block, Y (e.g. 4; ASTC 4..12) |
| 0x08 | 2 | `block_d` | u16 | texels per block, Z; `1` for all 2D block formats |
| 0x0A | 2 | `bytes_per_block` | u16 | 8 or 16 for current formats; MUST match the §11.3 table |
| 0x0C | 4 | `block_order` | u32 (enum) | `0`=ROW_MAJOR_BLOCKS (canonical) |
| 0x10 | 4 | `caps_flags` | u32 (bitfield) | see below |
| 0x14 | 4 | `view_kind` | u32 (enum) | `0`=UNORM, `1`=SRGB, `2`=SNORM, `3`=FLOAT (hardware sample interpretation) |
| 0x18 | 4 | `swizzle` | u32 | 4 nibble-pairs… see §11.9; `0` = identity RGBA |
| 0x1C | 4 | `reserved0` | u32 | MUST be `0` |

**`caps_flags` bits:**

| Bit | Name | Meaning |
|---|---|---|
| 0 | `DIRECT_UPLOADABLE` | set **only** if codec_id ∈ hardware block range AND §11.8 layout/alignment invariants hold |
| 1 | `IS_TRANSCODABLE` | set **only** if codec_id ∈ transcodable-intermediate range |
| 2 | `HAS_SOFTWARE_DECODE` | always set for this family (every GPU codec ships a real block-unpack to RGBA) |
| 3 | `PADDED_TO_BLOCK` | set if mips smaller than the block footprint are padded up to one full block (see below) |
| 4..31 | reserved | MUST be `0` |

**Consistency rules (loader, loud-fail):**
- `block_w/block_h/block_d/bytes_per_block` MUST match the §11.3 entry for the `codec_id` (for ASTC, `block_w`/`block_h` MUST be a legal ASTC footprint and `bytes_per_block == 16`), else `E_CSIF_BLOCK_DESC`.
- `DIRECT_UPLOADABLE` and `IS_TRANSCODABLE` are mutually exclusive; setting both is `E_CSIF_BLOCK_DESC`.
- `block_order` MUST be `ROW_MAJOR_BLOCKS` for `gpublk_version = 1`.
- `view_kind == SRGB` requires `COLR.transfer` to be an sRGB-class transfer code point; `view_kind == FLOAT` requires a float-capable format (BC6H / declared float ASTC); a violation is `E_CSIF_VIEW_MISMATCH` (§11.7).

**Sub-block raster within a sub-resource:** blocks are laid out `ROW_MAJOR_BLOCKS` — for a sub-resource of `W×H` texels there are `blocks_x = ceil(W / block_w)` blocks across and `blocks_y = ceil(H / block_h)` blocks down, stored row-major (`for by in 0..blocks_y: for bx in 0..blocks_x`). When `W` or `H` is not a multiple of the block footprint (the small mip levels), the trailing block is a full block with the out-of-image texels **padded** by the encoder; the decoder/uploader reads `blocks_x × blocks_y × bytes_per_block` bytes (= the computed `vram_size`) and crops on sample. `PADDED_TO_BLOCK` declares this is the case; it is always true for any mip whose dimension is below the footprint.

---

### 11.7 Texel color: transfer function, primaries, and the UNORM-vs-SRGB view

The GPU texture family **does not redeclare color**; it reuses the file's `COLR`/CICP block (§color section). What it adds is the single GPU-specific decision the hardware texture unit makes on sample: whether to apply the EOTF in hardware (an `_SRGB` format view returning linear floats) or not (a `_UNORM`/`_SNORM`/`_FLOAT` view returning raw values). This decision is the `view_kind` field in `GPUBLK` (§11.6).

**Normative rules:**

1. **The stored texel encoding is `COLR.transfer`.** A reader never guesses gamma. `COLR` MUST be present for a GPU-texture file (the §color "no Unspecified" rule applies); absence is `E_CSIF_COLR_REQUIRED`.
2. **`view_kind` declares how the GPU should sample, and MUST be consistent with `COLR`:**
   - `view_kind == SRGB` ⇒ `COLR.transfer` MUST be an sRGB-class curve (sRGB or BT.709-as-sRGB-equivalent per the CICP table). The OS picks the `*_SRGB` GPU format so the texture unit returns linear light. Violation: `E_CSIF_VIEW_MISMATCH`.
   - `view_kind == UNORM` ⇒ texels are sampled verbatim; the file MAY still declare any `COLR.transfer`, but the OS knows the hardware will **not** apply it — a shader or the compositor applies the EOTF explicitly using the declared `transfer`. This is the explicit, non-magic path for "data stored sRGB but I want the raw code values."
   - `view_kind == FLOAT` ⇒ `codec_id` MUST be a float-capable block format (BC6H, or an ASTC float profile declared in `params`); `COLR.transfer` for HDR MUST be `linear`/`PQ`/`HLG` as applicable. Violation: `E_CSIF_VIEW_MISMATCH`.
   - `view_kind == SNORM` ⇒ signed normalized (e.g. BC5 tangent normals mapped to [-1,1]); `COLR.transfer` MUST be `linear` (normal/data textures are never gamma-encoded). Violation: `E_CSIF_VIEW_MISMATCH`.
3. **Primaries** are `COLR.primaries` (BT.709 / BT.2020 / Display-P3 / custom-xy / ICC), used unchanged. Wide-gamut and HDR textures are just declared CICP values handled by the shared `color` toolkit — there is no GPU-specific gamut path.
4. **HDR color-volume metadata** (MaxCLL/MaxFALL, mastering display) for HDR textures rides in the existing `IHDV`/`IHDM` chunk (§color/§AVIF sections), unchanged; the GPU family adds nothing here.

There is **no implicit "RGB ⇒ sRGB" default**: a GPU-texture file that omits `COLR` is rejected, and the UNORM/SRGB choice is always an explicit `view_kind` the OS reads, never inferred from channel layout. This is rule #1 of the philosophy applied to the one place GPUs most often get color wrong.

---

### 11.8 Direct-upload layout & alignment contract (zero re-encode)

The value proposition — map the file region and DMA it straight into a GPU texture — holds only if the on-disk layout matches what drivers expect. CSIF makes the layout invariants **declared and validated**, and gates the zero-copy path behind a **positively advertised** capability bit so the OS never probes.

A GPU codec MAY set `DIRECT_UPLOADABLE` (`GPUBLK.caps_flags` bit 0) **iff all** of the following hold (and the loader re-checks them; a set bit that fails any check is `E_CSIF_DIRECT_UPLOAD`):

1. `codec_id` is a **hardware block format** (§11.3 direct range). Transcodable intermediates are never directly uploadable (they require a transcode pass first).
2. `supercompress_id == NONE` for the levels in question (a Zstd-compressed level must be inflated into a buffer first — its `stored_size ≠ vram_size`). Equivalently: `DIRECT_UPLOADABLE` requires `stored_size == vram_size` for every covered level.
3. `block_order == ROW_MAJOR_BLOCKS` and the sub-block raster of §11.6 is exactly followed (tightly packed blocks, no per-row padding beyond block alignment).
4. Each level's `file_off` (within the `IDAT` chunk) is aligned to `level_alignment`, a declared u32 in an `IGPA` (GPU-alignment) sub-block of `ITEX` (default and minimum **16**; recommended `LCM(bytes_per_block, 16)`), and the `IDAT` chunk payload itself begins at a **page-aligned** file offset so the OS can `mmap` the page-aligned region and feed it to the texture-upload path.
5. The sub-resource iteration order on disk equals the declared `subres_order`/`face_order`/`slice_order` (so the driver's expected face/slice ordering matches the bytes).

**`IGPA` sub-block (inside `ITEX`, 8 bytes, optional; absent ⇒ `level_alignment = 16`, `file_alignment = 4096`):**

| Off | Size | Field | Type | Meaning |
|---|---|---|---|---|
| 0x00 | 4 | `level_alignment` | u32 | byte alignment of each level's `file_off` within IDAT; power of two ≥ 16 |
| 0x04 | 4 | `file_alignment` | u32 | byte alignment of the IDAT chunk payload start in the file; power of two ≥ 4096 |

When `DIRECT_UPLOADABLE` is set and validated, the OS path is: locate the level via `IMIP`, `mmap` the page-aligned IDAT region, and DMA `vram_size` bytes straight into the GPU texture sub-resource (e.g. one `copy-buffer-to-image` per level/sub-resource) with **zero CPU decode**. This reuses the kernel's existing write-combining scanout discipline (the surface WC/PAT machinery, §display): the mapped texture region is uploaded with the same WC upload path the compositor already uses for `present`, so there is one upload discipline, not two.

When `DIRECT_UPLOADABLE` is **not** set, the OS MUST take the transcode path (§11.9) or the software-decode fallback (§11.11). The file always tells the OS, from headers alone, which paths are legal — no probing of pixel bytes.

---

### 11.9 Transcodable intermediate codecs (UASTC/ETC1S-class)

A transcodable-intermediate codec (`codec_id` 31/32) stores an intermediate-coded representation that **transcodes block-to-block** to a target hardware format at load — no pixel decode round-trip, bounded work per block. This is the "ship one asset, run on every GPU" mechanism, done the Caustic way: the **target is an explicit argument**, the **codebook is declared data**, and the **producible target set is declared** in `ICAP`.

**Interface extension (the only one in this family).** The uniform vtable is:

```
fn decode(self, target_codec_id: u32,
          level: u32, layer: u32, face: u32, slice: u32,
          out_buf: *u8, out_len: u64) -> i64
fn encode(...) -> i64        # real intermediate encoder, or honestly E_CSIF_UNSUPPORTED until shipped
```

- `target_codec_id` names which output the caller wants:
  - a **hardware block format** id (e.g. `BC7`=16, `ASTC`=30, `ETC2_RGBA`=21) ⇒ the codec **transcodes** the stored intermediate blocks to that format's blocks (codebook remap for ETC1S; ASTC-mode emit / down-convert for UASTC) and writes `vram_size`-for-the-target bytes into `out_buf`.
  - the sentinel `target_codec_id == 0` (RAW) ⇒ the codec performs the **software unpack to RGBA** fallback (always available, `HAS_SOFTWARE_DECODE`).
- The caller (the OS texture loader) chooses `target_codec_id` by intersecting the device's driver-reported supported formats with the file's declared `ICAP` producible set (§11.10) under a quality/size policy. **The codec never inspects the GPU.** This is the mechanism (the codec can produce target X) / policy (the OS decides X is best for this device) split, exact.
- A `target_codec_id` **not** in the declared `ICAP` producible set returns `E_CSIF_UNSUPPORTED` **loudly** (never a silent substitution, never a fake decode to a wrong format).
- `out_len` MUST be ≥ the computed target `vram_size` for that sub-resource; otherwise `E_CSIF_BUF_TOO_SMALL`. No hidden allocation — `out_buf` is the caller's.

**Codebook as declared data.** For `ETC1S_INTERMEDIATE`, the global codebook (endpoint + selector codebooks, RDO-built offline by the encoder) is a **declared sub-chunk** referenced by the codec's `params` — not hidden codec state. Its entry counts and per-entry sizes are explicit so a decoder pre-sizes its codebook buffers (bounded memory). The transcode of one block is a deterministic remap of its codebook indices into the target block layout; the remap rules per target are spec-fixed (frozen), so transcoding is bit-reproducible across implementations.

**Supercompression composes orthogonally.** A transcodable level MAY also be Zstd-supercompressed (`supercompress_id == ZSTD`): the OS first inflates `stored_size`→`vram_size`-of-intermediate (using the shared `entropy`/Zstd toolkit — DRY), then transcodes intermediate→target. `IMIP`'s `stored_size` vs `vram_size` already exposes the inflate delta; the transcode delta is implicit in the target geometry.

**ASTC footprint preservation.** `UASTC_INTERMEDIATE` is an ASTC-4×4 superset; transcoding to `ASTC` target MUST emit 4×4 ASTC (the lossless superset path), and transcoding to a coarser ASTC footprint or to BCn is a declared down-conversion. The target's `GPUBLK` (footprint, view_kind) is constructed by the codec for the chosen target and returned to the OS so the OS picks the matching GPU format view.

---

### 11.10 `ICAP` — capability / fallback descriptor (chunk)

`ICAP` lets the **file declare which GPU targets it can serve** so the OS picks a path deterministically from data, never from code-side probing. It is the texture analog of CSE's capability manifest direction. `ICAP` is **mandatory** for transcodable-intermediate primaries and **optional** (but recommended) for direct block primaries (where the producible set is the single native format). It is a critical chunk if the primary is transcodable (the OS must read it to know what it can produce).

**`ICAP` header (12 bytes):**

| Off | Size | Field | Type | Meaning |
|---|---|---|---|---|
| 0x00 | 4 | `icap_version` | u32 | `1` |
| 0x04 | 4 | `primary_codec_id` | u32 | the texture's stored codec (direct block id or transcodable id) |
| 0x08 | 4 | `producible_count` | u32 | number of producible-target records following |

Then `producible_count` **producible-target records (8 bytes each)**:

| Off | Size | Field | Type | Meaning |
|---|---|---|---|---|
| +0x00 | 4 | `target_codec_id` | u32 | a hardware block format id the codec can produce (or `0`=RAW/RGBA fallback) |
| +0x04 | 4 | `quality_rank` | u32 | author-declared preference, lower = higher quality (ties broken by smaller `vram_size`) |

**Rules:**
- For a **direct** block primary, `producible_count == 1` and the single record's `target_codec_id == primary_codec_id` (it serves itself only), and the **software fallback** (RAW=0) is *implicitly guaranteed* by `HAS_SOFTWARE_DECODE` — but a writer MAY also list it explicitly.
- For a **transcodable** primary, the records enumerate every hardware target the codec can transcode to **plus** the guaranteed `RAW`(0) software fallback. The set MUST include `RAW`(0); omitting the fallback is `E_CSIF_ICAP_NO_FALLBACK`.
- `target_codec_id` values MUST be from the closed registry (§11.3) or `0`; unknown ids are `E_CSIF_UNKNOWN_CODEC`.

**OS selection (policy, given the data):**

```
device_formats = driver_query_supported_block_formats()      # separate device mechanism, not in the file
candidates = ICAP.producible ∩ device_formats
if candidates non-empty:
    pick the candidate with the lowest quality_rank (then smallest vram)
    if pick is DIRECT_UPLOADABLE and supercompress==NONE: zero-copy DMA (§11.8)
    else: transcode via decode(pick, …) (§11.9), or direct copy if pick == primary direct format
else:
    use RAW(0) software fallback → decode to RGBA → upload as uncompressed (§11.11)
```

This makes "all GPUs work from one file" an **architectural property declared in the file**: the producible set is data, the device support is a separate query, and the choice is pure policy over explicit data. There is no fake decoder anywhere in this flow — the RAW fallback is a real RGBA unpack, and any out-of-set target fails loud.

---

### 11.11 Software-decode fallback & honest sequencing

Every GPU codec in this family **MUST** ship a real software decode that unpacks blocks to RGBA (`HAS_SOFTWARE_DECODE` is always set):

- For a **direct** block format, `decode(target_codec_id = RAW, …)` (or the codec's `decode` with no GPU target) unpacks the BCn/ETC/EAC/ASTC blocks to RGBA samples in a caller buffer. This is what powers screenshots, non-GPU display, and any reader without a GPU. It is **real and complete** — not a stub.
- For a **transcodable** intermediate, `decode(RAW, …)` software-unpacks the intermediate to RGBA (the universal fallback when no device format matches).

**Honest sequencing of encoders / backends.** A given GPU codec's `encode` (a real block **compressor** — e.g. a BC7 encoder, an ASTC encoder, a UASTC/ETC1S intermediate encoder) is a **real interface slot**. If a particular encoder has not shipped yet, its `encode` returns `E_CSIF_UNSUPPORTED` **loudly** — it is never a fake that emits garbage or claims success. The decode side (block-unpack + transcode for declared targets) is real from day one for every codec listed in §11.3, because decode is what the OS/compositor needs to *consume* textures, which is the primary use case. This honors the philosophy: real codecs or honestly-sequenced real interface slots, never a fake decoder, and the design is closed before any slot is built.

**Determinism.** All block-unpack and transcode math is integer/fixed-point and spec-fixed (the BCn/ETC/EAC/ASTC decode equations and the ETC1S codebook-remap rules are frozen constants in the codec spec), so software decode and transcode are **bit-reproducible** across implementations — a prerequisite for the conformance corpus (§security): golden RGBA dumps for each block format and golden transcoded blocks for each `(intermediate, target)` pair.

---

### 11.12 Channel semantics & swizzle for non-color textures

GPU textures are frequently **not** color: normal maps (BC5, 2-channel, Z reconstructed), packed roughness/metalness/AO masks, height/data LUTs. Sampling these with the wrong transfer or channel order corrupts rendering. CSIF declares this explicitly and reuses the existing per-channel descriptor mechanism (`ICHN`, § exr/aux section) rather than inventing a parallel one.

- **Per-channel semantics** live in the existing `ICHN` chunk: each stored channel declares `role` (from the closed enum `COLOR_R/G/B | ALPHA | NORMAL_X/Y/Z | DATA | MASK | …`), `sample_type`, and `is_color_managed`. For a normal/data texture, `is_color_managed = false` makes "do NOT apply the colorspace transform to this channel" an explicit fact, and `view_kind` (§11.6) MUST be `SNORM`/`UNORM` with `COLR.transfer = linear` (enforced, §11.7).
- **Swizzle** is the `swizzle` field in `GPUBLK` (§11.6): four nibble-pairs encoding the source channel for each of output R,G,B,A. Encoding: bits `[3:0]`→R source, `[7:4]`→G, `[11:8]`→B, `[15:12]`→A; each nibble ∈ `{0=R,1=G,2=B,3=A,4=zero,5=one}`. `swizzle == 0` (the all-`R`/identity-clash value) is reserved to mean **identity RGBA** for ergonomics; any non-identity remap MUST be written explicitly (e.g. `RRRG` for a BC5-packed mask, so a consumer reconstructs the intended channels). A reader applies the declared swizzle after block-unpack / on sample-shader generation — it never guesses "is this a normal map?"; the role + transfer + swizzle are all written down.
- **BC5 two-channel normals**: the reconstructed Z (`Z = sqrt(1 - X² - Y²)`) is a **renderer-side** convention; CSIF declares the texture as 2-channel SNORM normal data (`role = NORMAL_X/NORMAL_Y`, `view_kind = SNORM`, `transfer = linear`) and states in the spec that Z reconstruction is the consumer's deterministic step (the formula is spec-fixed for conformance). The file carries the truth (two channels, linear, normal-role); how the shader reconstructs Z is declared policy.

---

### 11.13 Alpha for GPU compositing

Alpha association is a notorious silent-corruption trap; the GPU family makes it the declared 4-way enum required for every GPU-texture payload, promoting the v1 `alpha_premul` bool (§IHDR) to:

| Value | Name | Meaning | Compositor `over` math |
|---|---|---|---|
| 0 | `ALPHA_NONE` | no alpha channel carried | opaque |
| 1 | `ALPHA_STRAIGHT` | unassociated; color is full under transparency | `out = src.a·src + (1−src.a)·dst` (pre-divide for filtering if needed) |
| 2 | `ALPHA_PREMUL` | premultiplied in the texel's coded space | `out = src + (1−src.a)·dst` |
| 3 | `ALPHA_PREMUL_LINEAR` | premultiplied **in linear light** | premultiply/blend performed in linear; `out = src + (1−src.a)·dst` after EOTF |

**Rules:**
- The alpha mode lives in `ITEX`'s companion alpha field (a `u32 alpha_mode` appended via an `ITAL` sub-block, or carried as the promoted `IHDR.alpha_mode` enum — the value is the single source of truth for the whole texture, DRY with the file's alpha semantics).
- For block formats carrying alpha (`BC2/BC3/BC7/ETC2_RGBA/ETC2_RGB_A1`/ASTC-with-alpha), `alpha_mode` tells the compositor whether to pre-divide for editing or upload as-is and which blend equation to use. The GPU's bilinear/trilinear filter **requires** premultiplied alpha to interpolate edges without fringing; `ALPHA_PREMUL`/`ALPHA_PREMUL_LINEAR` are the correct modes for filtered compositor textures (icons/cursors/window thumbnails). `ALPHA_STRAIGHT` is legal but the compositor MUST convert before filtered scaling.
- `ALPHA_PREMUL_LINEAR` requires `view_kind` such that the hardware returns linear values (`SRGB` view, or `UNORM` with explicit shader EOTF, or `FLOAT`) — premultiply-in-linear is meaningless on gamma-encoded samples; a contradiction is `E_CSIF_ALPHA_MODE`.
- There is no default that "usually works": the writer states the mode, the OS selects the blend/filter path with no guess. This is the closed, honest op-set for alpha — these four modes are the whole menu.

---

### 11.14 Error codes (added by this section)

All loud, negative, register-reportable (matching the CSE/loader fail-loud posture; each reports the offending field/level so a verifier names exactly what failed):

| Code | Name | Cause |
|---|---|---|
| (reuse) | `E_CSIF_UNKNOWN_CODEC` | `codec_id` not in the closed registry (incl. undefined reserved GPU ids) |
| (reuse) | `E_CSIF_RANGE` | a level/sub-resource `file_off+stored_size` exceeds its IDAT chunk |
| `E_CSIF_TEX_KIND` | — | `ITEX.tex_kind` not a defined enum |
| `E_CSIF_TEX_GEOM` | — | depth/layer/face constraints violated for the declared `tex_kind` |
| `E_CSIF_TEX_LEVELS` | — | `level_count` out of bound |
| `E_CSIF_MIP_DIMS` | — | a level's stored dimensions ≠ the rounding formula |
| `E_CSIF_MIP_SET` | — | `level_index` set has gaps/dupes |
| `E_CSIF_MIP_SIZE` | — | per-level `vram_size` ≠ sum of sub-resource sizes |
| `E_CSIF_TEX_CORRUPT` | — | per-`(level,layer,face,slice)` checksum mismatch (localized) |
| `E_CSIF_BLOCK_DESC` | — | `GPUBLK` block geometry inconsistent with `codec_id`, or DIRECT+TRANSCODABLE both set |
| `E_CSIF_VIEW_MISMATCH` | — | `view_kind` inconsistent with `COLR.transfer`/format |
| `E_CSIF_COLR_REQUIRED` | — | GPU-texture file missing the mandatory `COLR` block |
| `E_CSIF_DIRECT_UPLOAD` | — | `DIRECT_UPLOADABLE` set but a §11.8 invariant fails |
| `E_CSIF_ICAP_NO_FALLBACK` | — | transcodable `ICAP` omits the RAW(0) software fallback |
| `E_CSIF_UNSUPPORTED` | — | requested transcode target not in the declared `ICAP` set, or an unshipped `encode` slot |
| `E_CSIF_BUF_TOO_SMALL` | — | caller `out_len` < computed target `vram_size` |
| `E_CSIF_ALPHA_MODE` | — | `ALPHA_PREMUL_LINEAR` with a non-linear `view_kind`, or other alpha/view contradiction |

---

### 11.15 Worked layout example (cubemap, BC7, sRGB, direct-uploadable)

A 1024×1024 sRGB RGBA environment cubemap, BC7, full mip chain (11 levels), zero-copy uploadable:

- **`ITEX`**: `tex_kind=TEX_CUBE`, `base_width=base_height=1024`, `base_depth=1`, `layer_count=1`, `face_count=6`, `level_count=11`, canonical orders. `IGPA`: `level_alignment=16`, `file_alignment=4096`.
- **`COLR`**: CICP `primaries=BT.709`, `transfer=sRGB`, `matrix=identity`, full range.
- **ICOD** primary item: `codec_id=16 (BC7)`, `params = GPUBLK{ block_w=4, block_h=4, block_d=1, bytes_per_block=16, block_order=ROW_MAJOR_BLOCKS, caps_flags=DIRECT_UPLOADABLE|HAS_SOFTWARE_DECODE, view_kind=SRGB, swizzle=identity }`.
- **`ITAL`**: `alpha_mode=ALPHA_PREMUL` (filtered compositor texture).
- **`IMIP`**: `level_order=LARGEST_FIRST`, `granularity=PER_LEVEL`, `rounding_mode=DOWN`, 11 records. Level 0: `1024×1024`, `vram_size = (1024/4)·(1024/4)·16 · 6 faces = 256·256·16·6 = 6,291,456` bytes, `stored_size == vram_size` (no supercompression), `file_off` 16-aligned inside the page-aligned `IDAT`. Levels 1..10 halve down to 1×1 (padded to one 4×4 block: `1·1·16·6 = 96` bytes).
- **`ICAP`** (optional for direct): `primary_codec_id=16`, one producible record `{target=16, quality_rank=0}` + `{target=0 (RAW), quality_rank=255}`.
- **OS path**: driver supports BC7 → `DIRECT_UPLOADABLE` set and §11.8 holds → `mmap` the page-aligned `IDAT`, DMA each level/face `vram_size` bytes straight into the cube texture via the WC scanout upload path → **zero CPU decode**. A GPU without BC7 → fall back to RAW(0) software unpack → RGBA → upload uncompressed.

Same file, **portable variant**: change the primary `codec_id` to `31 (UASTC_INTERMEDIATE)`, set `caps_flags=IS_TRANSCODABLE|HAS_SOFTWARE_DECODE` (DIRECT clear), add `supercompress_id=ZSTD`, and an `ICAP` listing producible `{ASTC, BC7, BC1, ETC2_RGBA, RAW}`. The OS intersects with the device, picks the best by `quality_rank`, inflates each level (Zstd, shared toolkit) and `decode(target, …)` transcodes block-to-block into a caller buffer — one asset, every GPU, no re-encode and no source round-trip.

---

**Relevant file (conventions matched):** `/home/caua/Documentos/Projetos-Pessoais/causticos/docs/CSE_FORMAT.md` — little-endian fixed-width Off/Size/Field/Value byte tables, numbered loader algorithms, explicit negative error codes, and the fail-loud / declared-everything posture this section follows; the GPU-texture codecs slot into the same closed codec registry and chunk-TLV family as CSE.

---

Now I have the family conventions: little-endian, fixed-width field tables, explicit offsets, "reject if..." loud-fail loader rules, closed enums, version freeze. Let me write section 12.

This is a spec-writing task; the deliverable is the markdown content returned as my response. I'll write the full section now.

## 12. Modos de captura & especiais (RAW, bilevel, vetor)

This section specifies three codec families that the photographic codecs (DCT codec_id=3, BLOCK codec_id=4) are categorically wrong for, plus the format-wide decision on geometric vector data. Each is a real entry in the closed codec registry, dispatched by `codec_id` through the same uniform container↔codec vtable `{decode, encode}` as RAW/QOI/MODULAR/DCT — the container never knows what any of these codecs does (mechanism), and each codec is one closed, self-describing policy.

Per the CSIF family conventions (mirroring `CSE_FORMAT.md`): **all multi-byte fields are little-endian**, declared with explicit offset/size/type; all enums are **closed** (an out-of-range value is a loud error, never a guessed default or alias); all optional sub-structures carry an explicit *present* flag (absence is never an implicit default); all rationals are stored as **two `i64` fields** `{num, den}` (never a float, never a mixed-width packed bitfield — see the Caustic mixed-width-struct miscompile gotcha); every count is explicit and capped by a declared maximum so a decoder pre-sizes buffers (no hidden allocation, bounded memory).

This section depends on, and reuses without re-specifying:

- the **container** (§3): the chunk directory, `ITBL` item table, `IREF` reference graph, `PROP`/`PASC` property store, derived-image registry, `ITOC` index, and the per-chunk CRC + criticality flags;
- the **color model** (§7): the `COLR` block (CICP `{primaries, transfer, matrix, full_range}` or ICC), `sample_format` enum `{U8, U16, U32, F16, F32}`, and the `ColorEncoding` rules ("Unspecified" is forbidden);
- the **shared toolkit** (§6): `entropy` (rANS interleaved + the binary range coder / MQ-class + canonical-Huffman + run-length primitives + the hybrid-token front end), `predict` (PNG filters + self-correcting weighted predictor + MA-tree), `transform`, `color`, and the new `raster2d`/`geom` modules introduced here.

It assigns the following `codec_id` values (extending the registry of §5; RAW=0, QOI=1, MODULAR=2, DCT=3, BLOCK=4, NEURAL=5):

| codec_id | name | kind | lossless | shared-toolkit consumers |
|---|---|---|---|---|
| 6 | `RAW_LOSSLESS` | camera-RAW (CFA mosaic + develop metadata) | yes (mosaic is bit-exact; develop is decode policy) | `entropy` (rANS + hybrid token), `predict` (CFA-period predictors) |
| 7 | `BILEVEL` | 1-bit document/fax (symbol + generic + MMR/MH) | yes; lossy symbol substitution is an explicit opt-in flag | `entropy` (binary range coder, run-length, canonical-Huffman) |
| 8 | `INDEXED` | 1/2/4/8-bit palette-indexed | yes | `entropy` (rANS + context), `predict` (left/up index) |
| 9 | `VECTOR` | resolution-independent display list | n/a (rasterized at a declared target) | `raster2d`, `geom`, `color` |

`codec_version` independently gates forward-compat per codec. A reader encountering an unknown `codec_id`, or a known `codec_id` with an unknown `codec_version`, **fails loudly** with `E_CSIF_UNKNOWN_CODEC` / `E_CSIF_CODEC_VERSION` (it never attempts a partial or guessed decode).

---

### 12.1 Camera-RAW codec — `codec_id = 6` (`RAW_LOSSLESS`)

A RAW image is **two logically distinct things** welded into one self-describing item: (1) the **undeveloped** sensor measurement — the per-photosite integer counts under a Color Filter Array, still in the sensor's native, non-linear, black-offset, white-clipped space — and (2) a **fully-declared, ordered develop program** that turns those counts into a colorimetric image. The Caustic split is decisive and stated as a normative invariant:

> **RAW invariant (mechanism vs policy).** The `RAW_LOSSLESS` codec's `decode` op produces *only the integer mosaic*, bit-exactly. Demosaicing, white balance, camera→XYZ conversion, tone mapping, and every develop opcode are **decode-time POLICY** executed by the renderer above the codec. Two conformant renderers MAY legitimately produce different RGB pixels from the same RAW item (different demosaic quality); this is **correct and honest**, not a conformance failure. Conformance for `RAW_LOSSLESS` is defined only on the recovered integer mosaic (bit-exact) and on the deterministic, fixed-point develop opcodes whose output is mandated bit-exact (§12.1.7).

The codec is selected by `codec_id=6`. A RAW item carries:

- an **`IRAW`** chunk (raw sensor descriptor — the develop-independent geometry & levels & calibration), declared once per item, referenced from the item's `PASC` property associations;
- a **`DEVELOP`** chunk (the ordered develop program), optional;
- a **`CAPTURE`** chunk (structured shot metadata), optional;
- the mosaic payload itself in the item's `IDAT`-class data, compressed by codec 6.

`IHDR`/`CHNL` for a RAW item MUST declare exactly one stored sample plane with `role = ROLE_CFA_MOSAIC` (for mosaic sensors) or the appropriate non-mosaic role (§12.1.1), and `COLR` MUST declare `color_model = CM_SENSOR` (a sensor-native, not-yet-colorimetric space). `CM_SENSOR` is the only value for which `COLR`'s CICP primaries/transfer/matrix are *advisory of the develop target*, not of the stored samples; the actual stored-sample meaning is given entirely by `IRAW`.

#### 12.1.1 `IRAW` chunk — sensor descriptor

`IRAW` is a sibling of `IHDR`, present iff the item is RAW. All scalar fields are `i64` (per the mixed-width gotcha). The chunk is a sequence of declared sub-blocks; each sub-block carries an explicit `present` flag and an explicit length so a reader skips an unknown future sub-block by length (forward-compat) — except that the CFA, LEVELS, and COLORCAL sub-blocks are **required** (their absence is `E_CSIF_RAW_INCOMPLETE`).

**`IRAW` header (fixed, @ chunk payload start):**

| Off | Size | Field | Notes |
|---|---|---|---|
| +0x00 | 8 | `sensor_kind` (i64 enum) | CLOSED: 0=`SENSOR_BAYER_CFA`, 1=`SENSOR_XTRANS`, 2=`SENSOR_QUAD_BAYER`, 3=`SENSOR_LINEAR_RGB` (non-mosaic, already 3-plane), 4=`SENSOR_MONOCHROME`, 5=`SENSOR_FOVEON_STACKED`, 6=`SENSOR_MULTISHOT_RGB`. No `AUTO`/`UNKNOWN`. |
| +0x08 | 8 | `cfa_present` (i64 bool) | 1 for kinds 0/1/2; 0 for 3/4/5/6. If 1, a CFA sub-block MUST follow. |
| +0x10 | 8 | `frame_count` (i64) | ≥1. >1 ⇒ a `FRAMESET` sub-block MUST be present (§12.1.8). |
| +0x18 | 8 | `bit_depth_native` (i64) | sensor ADC bit depth (e.g. 12, 14, 16). Stored samples use `CHNL.sample_type` width ≥ this. |
| +0x20 | 8 | `subblock_count` (i64) | number of sub-blocks that follow. |

**Sub-block framing (each):** `{ subblock_id:i64, present:i64, payload_len:i64, payload:bytes }`. `subblock_id` is a CLOSED enum: 1=`CFA`, 2=`LEVELS`, 3=`COLORCAL`, 4=`GEOM`, 5=`FRAMESET`, 6=`GAINGRID`. Unknown id with `present=1` ⇒ skip by `payload_len` (forward-compat); unknown id MUST NOT be one a develop opcode references.

**CFA sub-block (`subblock_id=1`)** — the photosite→color mapping, never inferred:

| Field | Type | Notes |
|---|---|---|
| `cfa_rep_rows` | i64 | repeat-pattern height (Bayer=2, X-Trans=6) |
| `cfa_rep_cols` | i64 | repeat-pattern width |
| `cfa_layout` | i64 enum | CLOSED: 0=`CFA_RECTANGULAR`, 1=`CFA_STAGGERED` |
| `plane_color_count` | i64 | number of distinct primaries in the CFA (Bayer=3: R,G,B; G appears twice but is one color) |
| `plane_color[]` | i64[`plane_color_count`] | each = a CLOSED color code: 0=R,1=G,2=B,3=C(cyan),4=M,5=Y,6=W(clear),7=IR,8=G2-as-distinct (only if the sensor truly distinguishes the two greens) |
| `pattern_len` | i64 | = `cfa_rep_rows * cfa_rep_cols` |
| `pattern[]` | u8[`pattern_len`] | row-major; each byte is an index into `plane_color[]`. **No implicit RGGB.** |

Example Bayer RGGB: `cfa_rep_rows=2, cfa_rep_cols=2, plane_color=[R,G,B], pattern=[0,1,1,2]`.

**LEVELS sub-block (`subblock_id=2`)** — linearization & normalization, with a FIXED order of operations documented here (never heuristic):

Reconstruction of normalized scene-linear value from a stored raw count `v_raw`, applied in this exact order:

1. `v_lin = lin_table[v_raw]` if `lin_present`, else `v_lin = v_raw` (identity; absence is the declared `lin_present=0`, not a guess).
2. subtract the per-CFA-cell black: `v_b = v_lin - black(cell)`, where `black(cell)` is the repeat-pattern black plus optional row/col deltas.
3. normalize: `v_n = v_b / (white(plane) - black(cell))`, yielding `[0,1]` scene-linear.
4. apply per-plane analog gain: `v_g = v_n * analog_balance[plane]`.

| Field | Type | Notes |
|---|---|---|
| `black_rep_rows`, `black_rep_cols` | i64,i64 | black-level repeat dims (often = CFA dims) |
| `black_count` | i64 | = `black_rep_rows*black_rep_cols` |
| `black_level[]` | i64[`black_count`] | per-cell black pedestal |
| `black_delta_h_present` | i64 bool | per-column black deltas present |
| `black_delta_h[]` | i64[image_active_width] | only if present |
| `black_delta_v_present` | i64 bool | per-row black deltas present |
| `black_delta_v[]` | i64[image_active_height] | only if present |
| `white_count` | i64 | one per plane (or 1 global) |
| `white_level[]` | i64[`white_count`] | saturation/clip level |
| `lin_present` | i64 bool | linearization LUT present |
| `lin_entry_count` | i64 | size of `lin_table` (= 2^`bit_depth_native` when present) |
| `lin_table[]` | i64[`lin_entry_count`] | maps companded count → linear |
| `analog_balance_count` | i64 | one per raw plane |
| `analog_balance[]` | {num:i64,den:i64}[`analog_balance_count`] | rational hardware amp gain |
| `as_shot_neutral_count` | i64 | one per plane (the as-shot WB neutral) |
| `as_shot_neutral[]` | {num:i64,den:i64}[`as_shot_neutral_count`] | the gray point in camera space; the as-shot white balance |

**COLORCAL sub-block (`subblock_id=3`)** — camera-native → CIE XYZ calibration, dual- (or multi-) illuminant:

`{ cal_count:i64, then cal_count CalEntry records }`. A renderer estimates the scene correlated color temperature from `as_shot_neutral`, then interpolates between `CalEntry`s by inverse-CCT to build `camera_rgb → XYZ(D50)`.

**`CalEntry`:**

| Field | Type | Notes |
|---|---|---|
| `illum_kind` | i64 enum | CLOSED: 0=`ILLUM_STD` (standard illuminant code follows), 1=`ILLUM_XY` (explicit chromaticity), 2=`ILLUM_SPD` (spectral power distribution curve) |
| `illum_std_code` | i64 enum | only if `illum_kind=0`; CLOSED: 0=A,1=D50,2=D55,3=D65,4=D75,5=F2,6=F7,7=F11,8=Tungsten,9=Flash |
| `illum_xy` | {num,den}×2 | only if `illum_kind=1` |
| `illum_spd_len`, `illum_spd[]` | i64, {num,den}[] | only if `illum_kind=2` |
| `color_matrix_rows`, `cols` | i64,i64 | XYZ→camera matrix dims (3×3 for trichromatic; N×3 for >3 channels) |
| `color_matrix[]` | {num,den}[rows*cols] | the XYZ→camera inverse path |
| `forward_present` | i64 bool | |
| `forward_matrix[]` | {num,den}[3*cols] | camera(white-balanced)→XYZ(D50), numerically-robust path |
| `camera_cal_present` | i64 bool | |
| `camera_cal[]` | {num,den}[cols*cols] | per-camera calibration diagonal/matrix |
| `reduction_present` | i64 bool | |
| `reduction_matrix[]` | {num,den}[3*cols] | for >3-channel sensors → 3 |

The develop **output target** colorspace is the item's declared `COLR` (CICP or ICC) — the develop pipeline ends by mapping XYZ(D50) into that declared space. No second color path: `RAW_LOSSLESS` reuses §7's `COLR` machinery for its output exactly as direct-color codecs do (DRY).

**GEOM sub-block (`subblock_id=4`)** — the visible-image-inside-the-sensor contract; absolute integer sensor coordinates, no implicit "whole image is visible":

| Field | Type | Notes |
|---|---|---|
| `active_area` | i64×4 `{top,left,bottom,right}` | the imaging region; complement = masked/optical-black rows used for black-level estimation |
| `masked_rect_count` | i64 | reproducible black-level estimation regions |
| `masked_rects[]` | (i64×4)[count] | |
| `default_crop_origin` | i64×2 `{x,y}` | intended frame inside active area |
| `default_crop_size` | i64×2 `{w,h}` | |
| `user_crop_present` | i64 bool | |
| `user_crop` | i64×4 | |
| `default_scale_h`, `default_scale_v` | {num,den},{num,den} | non-square photosite / anamorphic correction |
| `best_quality_scale` | {num,den} | optional high-quality upsample factor |

Orientation is NOT duplicated here; the single source of truth is `IHDR.orientation` (§4), declared once.

**GAINGRID sub-block (`subblock_id=6`)** — lens-shading / flat-field correction grid (also reachable as a develop opcode; see §12.1.4):

`{ grid_planes:i64, grid_w:i64, grid_h:i64, interp:i64 enum (0=BILINEAR,1=BICUBIC), gains:{num,den}[grid_planes*grid_w*grid_h] }`. Applied multiplicatively per CFA plane at the `ON_LINEAR` stage.

#### 12.1.2 Mosaic payload coding (the `RAW_LOSSLESS` bitstream)

`decode` reconstructs the integer mosaic **bit-exactly**. The codec params (in `ICOD`, opaque to the container) declare:

| Field | Type | Notes |
|---|---|---|
| `plane_mode` | i64 enum | CLOSED: 0=`MOSAIC_INTERLEAVED` (predict stepping by the CFA period so same-color neighbors are used), 1=`PLANE_DEINTERLEAVED` (separate the CFA into per-color sub-planes, code each) |
| `predictor_id` | i64 enum | from the shared `predict` op-set: NONE/SUB/UP/AVERAGE/PAETH/WEIGHTED; for MOSAIC_INTERLEAVED the predictor's neighbor offsets are multiplied by the CFA period (declared) |
| `entropy_method_id` | i64 enum | from §6 (default 0 = rANS interleaved) |
| `hybrid_split` | {split_exponent:u8, msb_in_token:u8, lsb_in_token:u8} | the hybrid integer-token config (§6) so 12/14/16-bit residuals ride a small alphabet |
| `tile_w`, `tile_h` | i64,i64 | from §3 tiling; mosaic tiles align to a multiple of the CFA period |

The codec **only** outputs the mosaic; it never demosaics. It reuses the shared `entropy` and `predict` toolkit verbatim — no RAW-private entropy coder (DRY). Each tile is independently decodable (entropy reset per tile) with a per-tile CRC in the `ITOC` (§3), so a corrupt mosaic tile is localized and reported (`E_CSIF_TILE_CRC`), never silently wrong — essential for raw archival.

#### 12.1.3 `DEVELOP` chunk — the ordered, staged develop program

The develop recipe is **declared data**, not renderer secret knowledge. `DEVELOP` is an ordered list of opcode entries; the renderer executes them in order. Each opcode is tagged with the pipeline **stage** at which it runs, mirroring DNG's OpcodeList1/2/3 but made fully explicit:

**Stages (CLOSED enum `develop_stage`):** 0=`ON_RAW` (still-mosaiced integer counts), 1=`ON_LINEAR` (after linearization/normalization to scene-linear float), 2=`ON_DEMOSAICED` (after the renderer's demosaic), 3=`ON_COLOR` (after camera→output-colorspace conversion).

**`DEVELOP` header:** `{ opcode_count:i64, max_opcode_count:i64 }` (the cap is declared so a reader pre-sizes; `opcode_count > max_opcode_count` ⇒ `E_CSIF_RAW_BOUNDS`).

**Opcode entry:** `{ stage:i64, opcode_id:i64, opcode_version:i64, flags:i64, param_len:i64, params:bytes }`.

- `flags` bit0 = `OPCODE_REQUIRED`. If set and the renderer does not implement `opcode_id`/`opcode_version`, decode **fails loudly** (`E_CSIF_OPCODE_REQUIRED`) — no silent wrong render. If clear, an unknown opcode is skipped by `param_len` (forward-compat).
- `opcode_id` is a CLOSED op-set (the develop "vtable"), each with a fixed `{apply}` signature operating on caller-provided, tile-bounded buffers (no hidden allocation):

| opcode_id | name | stage(s) | params |
|---|---|---|---|
| 1 | `FIX_DEAD_PIXELS` | ON_RAW | `{coord_count:i64, coords:(i64×2)[], repair:i64 enum {0=NEIGHBOR_MEDIAN,1=BILINEAR_SAME_COLOR}}` |
| 2 | `FIX_VIGNETTE_RADIAL` | ON_LINEAR | radial polynomial coeffs `{num,den}[]` + optical center |
| 3 | `GAIN_MAP` | ON_LINEAR | references a `GAINGRID` (§12.1.1) by index |
| 4 | `WARP_RECTILINEAR` | ON_LINEAR | per-plane radial+tangential distortion coeffs `{num,den}[]` |
| 5 | `MAP_TABLE` | ON_RAW/ON_LINEAR | a per-plane value LUT |
| 6 | `TRIM_BOUNDS` | ON_LINEAR | rect (declares the trim after warp) |
| 7 | `DEMOSAIC` | ON_RAW→ON_DEMOSAICED (stage marker) | `{method_hint:i64 enum {0=BILINEAR,1=VNG,2=AHD,3=DCB,4=RCD}, hint_is_advisory:i64=1}` — the marker that mosaic→RGB happens here; the method is **advisory**, renderer policy MAY override (this is where the RAW invariant lives) |
| 8 | `HUESAT_MAP` | ON_COLOR | a 3-D HueSat correction lattice (the camera "look") — POLICY, applied only if present, never auto-synthesized |
| 9 | `TONE_CURVE` | ON_COLOR | piecewise points `{num,den}[]` |
| 10 | `WHITE_BALANCE` | ON_LINEAR | the chosen WB multipliers (defaults to `as_shot_neutral`; a renderer/editor MAY substitute) |
| 11 | `CAMERA_TO_XYZ` | ON_LINEAR→ON_COLOR (marker) | references the interpolated `COLORCAL`; the colorimetric core |

Opcodes 7 and 11 are **stage markers** that the renderer fills with its own policy implementation; all others are deterministic transforms whose math is fixed-point and **bit-exact** when `OPCODE_REQUIRED` is set (so an editor's non-destructive pipeline is reproducible across readers). The honest statement is normative: *`DEMOSAIC` (op 7) and the renderer's demosaic quality are policy; the file states WHAT corrections and in WHAT order, the renderer chooses HOW well to demosaic.*

#### 12.1.4 `CAPTURE` chunk — structured shot metadata (authoritative, machine-readable)

Distinct from the opaque EXIF/XMP blob (which stays in `IMET`/`PROV` for round-trip fidelity, §7/§11 and flagged preservation-only). `CAPTURE` carries the fields a good default develop and a physically-grounded denoiser actually consume, each explicitly typed:

| Field | Type | Notes |
|---|---|---|
| `exposure_time` | {num,den} | seconds |
| `iso` | i64 | |
| `f_number` | {num,den} | |
| `focal_length` | {num,den} | mm |
| `noise_profile_count` | i64 | one (a,b) pair per channel |
| `noise_profile[]` | {a_num,a_den,b_num,b_den}[] | variance = a·signal + b (Poisson+Gaussian); grounds denoisers |
| `baseline_exposure` | {num,den} | default tone shift (stops) |
| `baseline_noise` | {num,den} | |
| `baseline_sharpness` | {num,den} | |
| `make_len`,`make[]` / `model_len`,`model[]` / `lens_len`,`lens[]` | i64,UTF-8 | length-prefixed, bounded |

A camera "look" (HueSat/tone) is **never** auto-applied from `CAPTURE`; it lives only as the explicit `HUESAT_MAP`/`TONE_CURVE` develop opcodes (policy).

#### 12.1.5 Develop is policy — preview/thumbnail honesty

A RAW item MAY carry an embedded **developed preview** (a full-size rendering in any normal CSIF lossy codec) and a thumbnail, each a self-contained CSIF sub-image item (`ITBL`), bound to the RAW item by `IREF` edges of kind `THUMBNAIL_OF` / `PREVIEW_OF` (preview is a closed `ref_type`, §3) plus an explicit `develop_snapshot_id` recorded in the edge's payload — so a preview is **never mistaken for sensor truth** and a reader knows exactly which develop settings produced it. No implicit "the preview matches current settings" assumption; reuse of the item/reference mechanism means no new code path (DRY).

#### 12.1.6 Multi-frame / burst / pixel-shift / dual-gain

When `frame_count > 1`, the `FRAMESET` sub-block declares `{ frame_role:i64 enum {0=BURST,1=PIXEL_SHIFT,2=HDR_BRACKET,3=DUAL_GAIN}, primary_frame_index:i64, combine_op_count:i64, combine_ops:[...] }`. Each frame is a self-describing payload (its own `ITOC` tile ranges); frames are decoded tile-by-tile (bounded memory). `combine_ops` is an ordered, declared list (policy) consumed at the appropriate develop stage; for `DUAL_GAIN`, two planes are stored with a declared gain ratio (`{num,den}`) and a blend threshold. A reader that ignores the set MUST fall back to the explicit `primary_frame_index` (never "frame 0 by default").

#### 12.1.7 Conformance & error model (RAW)

- Decode of the integer mosaic is **bit-exact** against the reference vectors (§12 ships a RAW corpus: source CFA + `.csif` + expected mosaic dump, hash-checked).
- Deterministic develop opcodes (all except markers 7/11) are **bit-exact** in fixed-point.
- Markers 7/11 are explicitly NOT bit-exact across renderers (the RAW invariant); their reference outputs are provided per declared demosaic method for testability but a differing method is conformant.
- Loud errors: `E_CSIF_RAW_INCOMPLETE` (missing required sub-block), `E_CSIF_RAW_BOUNDS` (count exceeds declared cap), `E_CSIF_OPCODE_REQUIRED`, `E_CSIF_TILE_CRC`.

---

### 12.2 Indexed / bilevel codecs

#### 12.2.1 `INDEXED` codec — `codec_id = 8` (palette-indexed)

Indexed color is the correct representation for screenshots, UI, logos, maps, diagrams, and pixel art (≤256 distinct colors): pixels become small indices, and an index plane is far more compressible than RGB because the alphabet is tiny.

**Critical Caustic redesign vs GIF/PNG:** the palette is **NOT** embedded in the codec bitstream. It lives in a separate, self-describing **`IPAL`** chunk (§12.2.2). The `INDEXED` codec emits/consumes **only index values** — the container owns color (mechanism), the codec owns compression (policy).

`ICOD` params for `INDEXED`:

| Field | Type | Notes |
|---|---|---|
| `index_bits` | i64 | CLOSED {1,2,4,8}; explicit, NOT log2-of-palette-size implied |
| `pack_order` | i64 enum | CLOSED {0=`MSB_FIRST`}; sub-byte index packing order along x, declared (not assumed) |
| `row_major` | i64 bool | =1 (declared, not implicit) |
| `entropy_method_id` | i64 enum | from §6: 0=rANS+context (default; this is "MODULAR-over-indices"), 1=adaptive-CDF, 2=canonical-Huffman, **3=LZW** (the GIF-compatibility entropy method), 4=raw |
| `predictor_id` | i64 enum | from `predict`: NONE / LEFT-index / UP-index (2-D index prediction) |
| `context_model_id` | i64 enum | order-0 / order-1 index context (from §6) |

The index plane is a first-class plane fed through the **shared** `entropy` + `predict` toolkit (the same rANS/range coder and PNG/self-correcting predictors used by MODULAR) — `INDEXED` is essentially MODULAR-over-indices. LZW (method 3) is **one declared entropy-method value among others**, never the format itself; canonical Huffman, run-length, and the 2-D distance-remap table (§6) are all reused (DRY).

Bit-packing, MSB-first order, and row-major layout are **declared fields**, not the partly-implicit conventions GIF/PNG leave to folklore — the item is 100% self-describing.

#### 12.2.2 `IPAL` chunk — explicit, self-describing color table

A standalone chunk (sibling of `IHDR`), mirroring the CSE segment-table discipline: a fixed header then the entry array, all sizes explicit, little-endian.

| Off | Size | Field | Notes |
|---|---|---|---|
| +0x00 | 8 | `entry_count` (i64) | **explicit** (NOT implied by chunk byte length; no "768 bytes ⇒ 256 RGB triplets" inference). ≤ 2^`index_bits`, and ≤ a declared `max_palette_entries`. |
| +0x08 | 8 | `entry_channels` (i64) | e.g. 3 (RGB), 4 (RGBA), 1 (Gray), 4 (CMYK) — generalizes PNG's RGB-only PLTE |
| +0x10 | 8 | `entry_bit_depth` (i64) | per-channel depth of palette colors (8/10/12/16) |
| +0x18 | 8 | `entry_colorspace_ref` (i64) | index into the item's `COLR`/ICC machinery (§7); palette colors are color-managed identically to direct-color pixels — **no second color path (DRY)** |
| +0x20 | 8 | `palette_kind` (i64 enum) | CLOSED {0=`PALETTE_BINDING` (authoritative), 1=`PALETTE_SUGGESTED` (a quantization hint, e.g. PNG sPLT-equivalent)} — separately tagged so there is never ambiguity about which palette is binding |
| +0x28 | … | `entries[]` | `entry_count` tuples, each `entry_channels` × `entry_bit_depth`-bit components, tightly packed, little-endian |

`palette_kind=PALETTE_SUGGESTED` chunks are advisory and MUST NOT be used for decode unless the reader explicitly chooses a re-quantization policy; a binding decode always uses the `PALETTE_BINDING` chunk.

#### 12.2.3 Palette transparency / per-index alpha

CSIF subsumes GIF's single-magic-transparent-index and PNG's tRNS-side-table cleanly and **explicitly**: when `IHDR.channels`/`CHNL` declares an alpha channel (RGBA/GrayA), the `IPAL` entry format simply **includes the alpha channel** (`entry_channels` counts it) — a palette entry is a full RGBA tuple. There is:

- **no separate tRNS side-table**;
- **no "first M entries have alpha, rest opaque" implicit rule** — if a compact mostly-opaque palette is wanted, it is a declared variant: `palette_kind` is unaffected, but a `PASC` property `opaque_fill_count:i64` may declare an explicit count of trailing entries to treat as alpha=max (declared, never inferred from array length);
- **no "magic transparent index" concept at all** — transparency is just the alpha channel of the indexed color, fully visible in the data.

Premultiplication uses the single file-wide `IHDR.alpha_premul` semantic (§7) — one alpha rule for the whole item, no per-chunk surprise (DRY).

#### 12.2.4 `BILEVEL` codec — `codec_id = 7` (1-bit document/fax, JBIG2/CCITT-class)

Scanned documents, faxes, and line art are **structural** 1-bit images; DCT rings badly on text and is far larger than a symbol-matching coder. `BILEVEL` is a real codec with a closed `{decode, encode}` interface, dispatched purely by `codec_id` (the container never knows JBIG2 exists). It offers three region coding modes selected per region by an explicit field — **never auto-chosen**:

**`BHDR` (bilevel header) sub-block in `ICOD` params:**

| Field | Type | Notes |
|---|---|---|
| `region_count` | i64 | typed regions on the page (bounded; > `max_regions` ⇒ `E_CSIF_BILEVEL_BOUNDS`) |
| `lossy_symbols` | i64 bool | **explicit lossy/lossless bit.** Lossy symbol substitution (representative bitmap replaces an instance) can swap visually-similar glyphs (the Xerox digit-substitution class of bug) and therefore **changes pixels** — it is a declared field, never a silent default |
| `bit_order` | i64 enum | CLOSED {0=`MSB_FIRST`}; declared, killing the historic T.4 fill-bit ambiguity |
| `row_byte_aligned` | i64 bool | declared per spec |
| `arith_variant` | i64 enum | the binary range coder variant id, from the shared `entropy` toolkit |

**Region descriptor (each of `region_count`):** `{ region_type:i64, x:i64, y:i64, w:i64, h:i64, combine_op:i64, mode:i64, mode_params:bytes }`.

- `region_type` (CLOSED): 0=`GENERIC`, 1=`SYMBOL_TEXT`, 2=`HALFTONE`, 3=`REFINEMENT`.
- `combine_op` (CLOSED): 0=`OR`, 1=`AND`, 2=`XOR`, 3=`REPLACE` — region compositing is fully specified, no implicit OR.
- `mode` (CLOSED): 0=`GENERIC_ARITH`, 1=`MMR_2D` (CCITT G4), 2=`MH_1D` (CCITT G3).

**Mode 0 — `GENERIC_ARITH` (context-template, the JBIG2 generic-region coder).** For each pixel, gather a **fixed template** of N already-decoded causal neighbors (left on the current row + pixels in the 1–2 rows above; templates of 10–16 pixels), form an integer context from those bits, decode/encode the pixel under that context's adaptive probability state in the shared **binary range coder (MQ-class)**, then update the state. Purely causal ⇒ no side info. The template is **declared explicitly**: `mode_params` carries `template_id:i64` + `at_count:i64` + `at_offsets:(i64×2)[at_count]` (the adaptive-pixel (dx,dy) offsets for halftones) — no implicit template.

**Mode for `SYMBOL_TEXT` (region_type=1, mode=GENERIC_ARITH internally for dictionary bitmaps).** Connected-component segmentation (encoder side) clusters near-identical glyphs into a **symbol dictionary** of representative bitmaps; the dictionary bitmaps are coded once with the generic coder; the text region is then a stream of `(symbol_id, dx, dy [, refinement_bitmap])` triplets, the `symbol_id` coded by the shared arithmetic integer coder. The dictionary is **declared data** (a `SYMBOL_DICT` sub-block: `{ entry_count:i64, max_entry_count:i64, entries:[{w:i64,h:i64,bitmap_bytes}] }`) — fully reconstructable, bounded, no hidden allocation. With `lossy_symbols=0`, every instance carries a refinement bitmap (coded against its dictionary entry) so the page is bit-exact lossless; with `lossy_symbols=1`, instances are substituted by the representative (explicitly flagged).

**Modes 1/2 — `MMR_2D` / `MH_1D` (CCITT G4/G3 lossless fallback).** Each scanline is a sequence of black/white runs. `MH_1D` (G3): run lengths coded with the standard terminating + make-up canonical-Huffman tables (from the shared `entropy` run-length + Huffman primitives). `MMR_2D` (G4): each changing element on the current line is coded relative to the reference changing element on the line above — Pass / Horizontal / Vertical(−3..+3) modes — with an imaginary all-white line above the first row. This is the simple, fast, arithmetic-coder-free honest floor that guarantees `BILEVEL` works on noisy/dithered scans where symbol matching finds no structure. An optional declared row-sync field (rather than EOL magic bytes) gives error resilience.

**Shared binary range coder (toolkit).** The MQ-class binary range coder lives in the shared `entropy` toolkit as a sibling primitive to rANS: it maintains a code interval; each binary decision uses a context's current probability state (an index into an LPS/MPS state table with a fixed, versioned transition machine declared as toolkit constants). Contexts are computed by the codec (pixel template here) and passed in — clean mechanism (coder) vs policy (context). The context state array size is a declared function of template size, pre-allocated, bounded. `BILEVEL` ships **no** private coder (DRY); the same primitive is available to transform codecs that want CABAC-style coding.

Each region is tiled and independently decodable (entropy reset per tile/region) with per-region/per-tile CRC in the `ITOC`, so a huge scanned page decodes region-by-region within bounded memory and supports partial/ROI decode; a corrupt region fails loudly (`E_CSIF_TILE_CRC`) and the rest decodes.

#### 12.2.5 Animation for indexed/bilevel content (the GIF/APNG lineage, done the Caustic way)

CSIF carries animation as **explicit** chunks layered on the item model (this is the same `ANIM`/`FRAME` machinery defined in §11 / the container, summarized here for the indexed/animation lineage and stated with the GIF/APNG sins fixed):

- **`IANM`** (animation header): `{ frame_count:i64, loop_count:i64 (0 ⇒ named INFINITE constant, explicit), timebase_hz:i64, max_snapshot_depth:i64, background:RGBA }`. `timebase_hz` is declared (no implicit 10 ms centisecond unit).
- **Per-frame `IFRM`**: `{ x:i64, y:i64, w:i64, h:i64, delay_num:i64, delay_den:i64, dispose_op:i64, blend_op:i64, sequence_number:i64, codec_ref:i64 }`.
  - `dispose_op` (CLOSED, defined at the pixel level in this spec — **no "restore to previous" ambiguity**): 0=`NONE` (leave), 1=`BACKGROUND` (clear rect to canvas background), 2=`PREVIOUS` (restore the pre-frame snapshot).
  - `blend_op` (CLOSED): 0=`SOURCE` (replace pixels), 1=`OVER` (alpha-composite onto canvas).
  - delay is an exact rational (arbitrary precision), not centiseconds.
- Each frame references its codec by `codec_ref` → normal `codec_id` dispatch, so frame 0 MAY be `INDEXED`, a later frame `DCT`, etc. (the animator is structure/mechanism; each frame's compression is policy).
- Frames MAY share one global `IPAL` OR carry a local one (declared per frame) — generalizing GIF's global/local color tables **explicitly**.
- `PREVIOUS` disposal requires the decoder to snapshot; `max_snapshot_depth` is declared so memory is **bounded** (no hidden unbounded frame buffer).
- All animation chunks carry `CHUNK_CRITICAL=0` (skippable): a still-image reader decodes the canonical default frame (the primary item) and skips the rest — forward-compat by **declared flag**, not APNG's lowercase-letter magic.

#### 12.2.6 Authoring-intent metadata (advisory only)

A reader/encoder choosing among RAW/INDEXED/BILEVEL/DCT does so by an encoder-side heuristic, but the **decision** — `codec_id` + the codec's explicit params + `lossy_symbols` + palette — is what the file records; the decoder does exactly what the fields say. There is **no `AUTO` codec_id and no in-file heuristic** (rule 1). An optional, clearly-non-binding `content_class` enum MAY be recorded in `IMET` (CLOSED {DOCUMENT, SCREENSHOT, LINEART, PHOTO, PIXELART}) to record authoring intent for tools, but it is declared **advisory** and **NEVER changes decode**.

---

### 12.3 The vector decision — recommendation and justification

**Recommendation: a HYBRID — raster core PLUS an explicit, optional `VECTOR` codec (`codec_id = 9`) and an explicit composition chunk — NOT raster-only-with-mipmaps.**

This is chosen over the alternative ("raster-only core with multi-resolution mipmaps for icons") and justified strictly the Caustic way below. The hybrid is the *more honest and more complete* design, and — critically — it does **not** make raster-only readers pay: vector is one more `codec_id` behind the same vtable, and a decoder that cannot rasterize fails loudly and precisely (or falls back to a declared raster cache), exactly like the kernel returning `E_NOENT` for an unregistered device index.

#### 12.3.1 Why hybrid, and why not raster-only-mipmaps

1. **Mechanism vs policy makes vector free of container cost (rule 3).** No SOTA *container* fork is needed: vector is `codec_id=9` dispatched by the identical `{decode, encode}` seam. The container stays pure mechanism; the rasterizer is pure policy inside codec 9. Raster-only-mipmaps would *also* satisfy the container, but it cannot deliver resolution independence — only a finite ladder of pre-baked sizes. The physics of icons/cursors (must stay crisp at *every* DPI: 1×/1.5×/2×/3× and arbitrary fractional scaling on HiDPI compositors) means a mipmap ladder is always either too coarse (blurry between rungs) or wasteful (store many sizes). A 1 KB vector path beats a stack of PNG mipmaps and recolors/themes without re-authoring. The concrete causticos motivation: the WM today hardcodes a 10×16 arrow + procedural resize/ibeam/move shapes in `userspace/wm/compositor.cst`; a vector cursor/icon set replaces those and scales to any DPI from one declared asset.

2. **The honest cost is real but contained (rules 4, 5).** A vector codec drags in a 2-D rasterizer — curve flattening, scan conversion, anti-aliasing, fill rules, gradient evaluation, stroke expansion — a large, security-sensitive policy surface. The Caustic answer is not to refuse it (that would leave icons forever as pixel mipmaps) nor to bolt on SVG (an open, scripting-adjacent, interop-cursed surface). It is to define a **small, closed, binary, Turing-incomplete display list** with a **fully-specified deterministic rasterization**, and to confine it to codec 9 behind the vtable, reusing a shared `raster2d`/`geom` toolkit (so the compositor links the *same* rasterizer instead of reinventing primitive drawing). Memory stays bounded (caller-provided target buffer + bounded scratch; bounded graphics-state stack).

3. **Resolution-independence as an explicit input, never magic (rule 1).** The only interface change vs raster codecs: `decode` for codec 9 needs the output raster geometry. For raster codecs that equals `IHDR` width/height; for `VECTOR` the **caller supplies `target_w, target_h, dpi`** and decode rasterizes the display list into that buffer. This is the same explicitness CSIF already applies to endianness/gamma/colorspace, now applied to the rendering target. The raster-only-mipmaps design has no way to express "rasterize at exactly this DPI" — it can only pick the nearest pre-baked rung, which is precisely the magic/heuristic the philosophy forbids.

4. **The hybrid *includes* the mipmap idea, made explicit — so nothing is lost.** A `VECTOR` master MAY be accompanied by a declared, pre-rasterized raster cache (icon-set), and a raster-only image MAY be a declared scale-factor collection. The **consumer** picks a size from the **declared** list given its DPI — the format never silently rescales. Thus the hybrid is a strict superset: it gives the raster-only-mipmaps capability *and* true vector, both stated explicitly, the reader choosing by capabilities it knows from the chunk declarations.

5. **Family discipline (rule 7) and no speculative half-features (rule 4).** Vector v1 is a **still-image display list**. Animation (Lottie-class) is recognized as a *separate axis* and kept OUT of v1, but as a **named, capability-gated future** chunk that does not exist in the file until built (not a reserved-but-undefined field inviting guesses) — matching CSE's "frozen now, versioned later" discipline.

#### 12.3.2 `VECTOR` codec — `codec_id = 9`

Behind the existing vtable. Its `IDAT` payload is a **binary display list** (not XML, not JSON, not PostScript text). `decode(display_list, target_w, target_h, dpi, header) → pixels` is the only interface delta. `encode` serializes a display list emitted by an authoring tool.

**`VHDR` (vector header) in `ICOD` params — the determinism contract:**

| Field | Type | Notes |
|---|---|---|
| `coord_format` | i64 enum | CLOSED {0=`Q16_16`}; fixed-point coordinate Q-format, declared bit width — no implicit unit system |
| `state_stack_depth` | i64 | declared max PUSH/POP depth (bounded); overflow ⇒ `E_CSIF_VEC_STACK` |
| `aa_mode` | i64 enum | CLOSED {0=`AA_NONE`, 1=`AA_COVERAGE_AREA` (analytic signed-area coverage), 2=`AA_SUPERSAMPLE_N` with `aa_n` declared} |
| `aa_n` | i64 | only if `aa_mode=2` |
| `flatten_tolerance` | {num,den} | curve-flattening tolerance in target device pixels |
| `gradient_interp_space` | i64 enum | CLOSED {0=`GRAD_FILE_COLORSPACE`, 1=`GRAD_LINEAR_LIGHT`} — **explicit**, because interpolating sRGB vs linear gives visibly different ramps (the #1 source of "wrong" gradients) |
| `stroke_model_version` | i64 | the stroke-to-fill expansion math version (declared) |
| `paint_count` | i64 | size of the paint table |
| `op_count`, `max_op_count` | i64,i64 | bounded straight-line program |

**Determinism invariant (normative):** decode is a deterministic function of `(display_list, target_w, target_h, dpi, VHDR)`. Same inputs ⇒ same pixels on any conformant decoder. The AA model, flattening tolerance, gradient interpolation space, fill rules, and stroke geometry are all **declared fields / spec-fixed math**, not a renderer's private choice — a non-deterministic rasterizer is a "hollow impl" the philosophy forbids. The §12 conformance corpus ships `.csif` vector items + reference pixel dumps at declared `(target_w, target_h, dpi)`, hash-checked.

**The closed op-set (the vector codec's contract, frozen and versioned like the syscall set).** Each op = 1-byte opcode + fixed-arity operands (coords in `coord_format`). **No conditionals, no loops, no scripting** — a straight-line program, decode O(ops), allocation-free:

| opcode | name | operands |
|---|---|---|
| 0x01 | `MOVE` | x, y |
| 0x02 | `LINE` | x, y |
| 0x03 | `QUAD` | cx, cy, x, y |
| 0x04 | `CUBIC` | c1x, c1y, c2x, c2y, x, y |
| 0x05 | `CLOSE` | — |
| 0x06 | `FILL` | fill_rule (enum {0=`NONZERO`,1=`EVENODD`} — never a default), paint_ref |
| 0x07 | `STROKE` | width, cap (enum {0=BUTT,1=ROUND,2=SQUARE}), join (enum {0=MITER,1=ROUND,2=BEVEL}), miter_limit, paint_ref |
| 0x08 | `PUSH` | — (graphics-state stack, bounded by `state_stack_depth`) |
| 0x09 | `POP` | — |
| 0x0A | `TRANSFORM` | affine 2×3 (6 fixed-point) |
| 0x0B | `CLIP` | path_ref, clip_rule (enum) |

Operands are an explicit fixed-arity per opcode; a reader knows **every** operation that can appear (the file is 100% self-describing). Paints are indexed into a **paint table**: each `Paint` = `{ paint_kind:i64 enum {0=SOLID,1=LINEAR_GRADIENT,2=RADIAL_GRADIENT}, ... }`. A solid paint is a color in the item's declared `COLR` space (no implicit sRGB). A gradient = `{ stop_count:i64, stops:[{offset:Q,color:RGBA_in_file_colorspace}], spread:i64 enum {0=PAD,1=REPEAT,2=REFLECT}, placement_affine:2×3 }`. Gradient color interpolation happens in the `gradient_interp_space` declared above, reusing the shared `color` module's linearization (DRY).

**Shared toolkit additions (`geom`, `raster2d`).** `geom`: fixed-point affine, centripetal Bézier flattening to `flatten_tolerance`, bounding boxes. `raster2d`: active-edge-table / signed-area scan conversion with analytic AA, nonzero/evenodd accumulation, linear/radial gradient sampling (via the `color` module), stroke-to-outline expansion with declared caps/joins. Both are **non-allocating** (caller passes target buffer + bounded scratch) and stateless (no hidden global rasterizer state) — every function an explicit, visible operation. The WM/compositor links the same `raster2d` to draw resolution-independent cursors instead of hardcoded bitmaps (DRY).

#### 12.3.3 Hybrid composition — `ICMP` chunk (vector over/under raster)

An optional composition chunk (skippable; absent ⇒ the image is a single codec stream, the common case stays simple). `ICMP` is an ordered list of layer records, composited bottom-to-top into the final buffer:

`{ layer_count:i64, max_layer_count:i64, layers:[{ source_item:i64 (an ITBL item index, in-file, the honest closed seam), placement_affine:2×3 fixed-point, blend_op:i64 enum, opacity:{num,den} }] }`.

A raster layer references a tiled raster item; a vector layer references a `VECTOR` item rasterized at the composite's target resolution. Each referenced item declares its own `COLR`; the compositor converts to the master `COLR` (`IHDR`) **explicitly** before blending (no implicit assume-sRGB). Composition is mechanism (the container orders + blends declared layers); how each layer is coded stays policy (its codec). The layer DAG is acyclic by construction (`source_item` indices must reference already-defined items; the §3 container invariants — acyclic derivation, geometry reconciliation, bounded fan-in — apply unchanged). This delivers the feature JXL/AVIF cannot: a DCT photo carrying a crisp vector logo/annotation/UI chrome that stays sharp at any zoom.

#### 12.3.4 Multi-resolution icon assets (the raster-fallback / responsive path)

Two complementary, fully-declared mechanisms; the **consumer** selects, the format never silently rescales:

1. **Raster-only icon set.** A scale-factor collection: an entity group (`GRPS`, §3) of kind `ICON_SET` whose members are raster items each declaring `{ width, height, scale_factor:{num,den} }` (e.g. {1×,1.5×,2×,3×} or {16,32,…,1024} px). The consumer picks the entry matching its DPI by the **declared** size — never auto-scaled from one (rule 1).
2. **Hybrid master + cache.** A `VECTOR` master item PLUS an optional cache of pre-rasterized sizes (each a raster item bound by `THUMBNAIL_OF`/an `ICON_SET` group). A reader that can rasterize uses the master at exact target DPI; one that cannot (or wants speed, e.g. a per-frame cursor blit) uses the nearest cached raster, declared as a derived/auxiliary item. The selection is the consumer's explicit choice given declared sizes.

Each level/size is a separate item decoded on demand (partial decode, bounded memory) — never the whole pyramid at once.

#### 12.3.5 Capability / conformance declaration (fail loud, never mis-render)

A file declares the set of `codec_id`s it uses, and for `VECTOR` the **op-set version + which optional op groups are used** (gradients, clipping), in an `ICAP` chunk (§ container): `{ required_codec_count:i64, required_codec_ids:i64[], vector_opset_version:i64, vector_optional_groups:i64 (bitmask: bit0=gradients, bit1=clip, …) }`.

Anything that **changes pixels** is a **required capability** the reader must positively support. A decoder that does not implement every required codec/op group MUST either (a) fall back to a declared raster cache if `ICMP`/the icon set provides one, or (b) **refuse with a precise error naming the missing capability** (`E_CSIF_VEC_UNSUPPORTED_OP`, `E_CSIF_CAP_UNSUPPORTED`) — never a "best effort partial render that looks broken." This mirrors causticos' fail-loud boot rule and the device-model honesty (out-of-range index = `E_NOENT`, not an alias). Forward-compat via skippable chunks still applies for truly optional, pixel-irrelevant metadata.

#### 12.3.6 Vector animation — explicit future, absent in v1

Vector v1 = one static display list. Animation is a **named future** `codec_id`/chunk (`VANIM`, capability-gated by its own `ICAP` bit) that references display-list deltas or keyframed transforms/paints, reusing the same op-set with a time axis added. Until built it **does not exist in the file** (no reserved-but-undefined field). This respects "no speculative hooks" while leaving an honest, explicit slot, matching CSE's frozen-now/versioned-later discipline and the rule to close the still-vector design before building the time extension.

---

### 12.4 Summary of new `codec_id`s, chunks, and error codes (this section)

**Codec registry additions:** 6=`RAW_LOSSLESS`, 7=`BILEVEL`, 8=`INDEXED`, 9=`VECTOR` — each behind the uniform `{decode, encode}` vtable (codec 9's `decode` additionally takes `target_w,target_h,dpi`), each reusing the shared toolkit (no codec ships a private entropy/raster engine; DRY).

**New chunks:** `IRAW` (+ sub-blocks CFA/LEVELS/COLORCAL/GEOM/FRAMESET/GAINGRID), `DEVELOP`, `CAPTURE` (RAW); `IPAL`, `IANM`/`IFRM`, `BHDR`/`SYMBOL_DICT` (indexed/bilevel); `VHDR`, `ICMP`, `ICAP` (vector). All follow the CSE-family TLV discipline: explicit little-endian fields, per-chunk CRC, `CHUNK_CRITICAL`/skippable flags, declared counts with declared caps.

**New error codes (loud, register-reported, like cse.cst):** `E_CSIF_UNKNOWN_CODEC`, `E_CSIF_CODEC_VERSION`, `E_CSIF_RAW_INCOMPLETE`, `E_CSIF_RAW_BOUNDS`, `E_CSIF_OPCODE_REQUIRED`, `E_CSIF_TILE_CRC`, `E_CSIF_BILEVEL_BOUNDS`, `E_CSIF_VEC_STACK`, `E_CSIF_VEC_UNSUPPORTED_OP`, `E_CSIF_CAP_UNSUPPORTED`.

**Normative invariants introduced:** the RAW mechanism/policy invariant (decode = bit-exact mosaic; develop = renderer policy; demosaic legitimately differs); the explicit `lossy_symbols` honesty bit for bilevel; the palette-is-not-in-the-bitstream rule for indexed; the vector determinism invariant (declared AA/flatten/gradient-space/fill-rule ⇒ reproducible pixels); the capability-declaration fail-loud rule (pixel-changing features are required capabilities, never best-effort).

The relevant spec file to integrate this into is `/home/caua/Documentos/Projetos-Pessoais/causticos/docs/CSIF_FORMAT.md` (sibling of `/home/caua/Documentos/Projetos-Pessoais/causticos/docs/CSE_FORMAT.md`), matching the family conventions in the latter.

---

I now have the family's conventions: byte-offset tables, little-endian, enumerated error codes, "fail loud" posture, frozen-at-self-host. I have everything needed to write section 13. Let me produce the spec content.

## 13. Proveniência (C2PA), métricas & tuning

This section specifies three orthogonal but tightly-related subsystems of CSIF:

1. **§13.1–§13.9 — `PROV`**: a signed, tamper-evident provenance manifest store, cryptographically hash-bound to the exact codec payload, with AI-generation disclosure wired to the `NEURAL` codec.
2. **§13.10–§13.15 — `IQMT` / `IRCM` / `QLYR`**: the CSIF perceptual quality scale — how a lossy quality parameter maps to a *named, reproducible metric target*, and which metrics gate conformance.
3. **§13.16–§13.20 — `IAQ` / `IROI` / RDO seam**: encoder-side tuning hooks (adaptive-quantization map, region quality) expressed as explicit declared params, never magic.

§13.21 ties all of this into the conformance / test-vector plan (cross-references §security and §metrics).

All multi-byte integers are **little-endian** (the CSIF container invariant, matching CSE; §0). All floats are **IEEE 754 binary32 (`f32`) or binary64 (`f64`), little-endian**, as declared per field. All rationals are **two `i64` fields `{num, den}`** (the Caustic mixed-width-struct miscompile gotcha forbids packing narrower scalars in a struct; den MUST be `> 0`). Every chunk and sub-record in this section follows the CSIF TLV grammar: `{ type:u32, flags:u32, size:u64, payload[size], crc32:u32 }` (§container). All structures declared here are subject to the container's `ILIM` bounds (§security): a reader pre-sizes from declared counts and rejects anything exceeding the declared ceiling **before** allocating.

---

### 13.1 Design stance: mechanism vs policy, fail-loud

CSIF carries provenance and quality the Caustic way:

- **Mechanism (container):** locate manifests, compute byte-range hashes, verify signature math over declared bytes, parse the metric/tuning records, dispatch the AI-disclosure cross-check. The container **never** decides trust, **never** re-derives a quality from pixels, **never** silently substitutes a default.
- **Policy (verifier / encoder / renderer):** *which* signing roots to trust, *how* an encoder searched for a quant, *whether* a viewer paints a Content-Credentials badge, *which* watermark algorithm to embed. None of this is baked into the format.

A verifier and an encoder are **separate programs** from the decoder. The decoder's trusted core never parses C2PA semantics, EXIF, or cert chains — it only needs `IHDR`/`ICOD`/`IDAT` to produce pixels. This shrinks the attack surface to the same posture as the kernel's `cse.cst` loader.

**Result model (normative, §13.20):** every check yields a distinct declared status. There is no boolean "ok". `no manifest`, `present-but-untrusted`, `tampered`, and `valid` are four different states, each reported with the offending field/range, matching the project's bounded, register-level error ethos.

---

### 13.2 `PROV` chunk — the manifest store

`PROV` is an **optional, skippable** chunk (its container `flags` has `CHUNK_CRITICAL=0`, `CHUNK_PUBLIC=1`; §png-flags). A reader that does not implement provenance skips it by `size` and still decodes pixels. An unsigned CSIF simply omits `PROV` — provenance is **never** synthesized.

```
PROV payload:
  prov_version : u16   = 1
  reserved     : u16   = 0
  manifest_count : u32         # bounded by ILIM.max_manifests
  manifest_offsets[manifest_count] : u64   # offset of each MANIFEST sub-record, relative to PROV payload start
  active_manifest_index : u32  # which manifest's HASHBIND binds the live bytes (§13.3); 0xFFFFFFFF = none
  MANIFEST[0] ...
  MANIFEST[manifest_count-1]
```

- `manifest_offsets[]` is an explicit directory (mirrors CSE's segment table): a reader seeks each manifest by declared offset, never by scanning. Each offset+inferred-length MUST lie wholly within the `PROV` payload; out-of-range = loud `E_PROV_RANGE` (§13.20).
- `active_manifest_index` names the manifest whose `HASHBIND` (§13.3) MUST validate against the current file bytes. All other manifests are **ingredients** (prior versions, §13.7) carried for lineage. If `manifest_count > 0` then `active_manifest_index` MUST be valid (`< manifest_count`) or the chunk is rejected `E_PROV_NO_ACTIVE`.

Each `MANIFEST` is a TLV record:

```
MANIFEST payload:
  manifest_id_len : u16        # length of the URN below
  manifest_id     : manifest_id_len bytes   # content-addressed URN: "csif:manifest:<hashalg>:<hex-digest-of-this-MANIFEST-with-CSIG-zeroed>"
  ASRT  sub-block   (§13.6 — assertion store)
  CLAIM sub-block   (§13.4)
  CSIG  sub-block   (§13.5)
```

`manifest_id` is the manifest's stable key (the "everything is a key" rule). It is computed over the manifest bytes with the `CSIG` signature region zeroed (so the id is stable before *and* after signing). Ingredient references (§13.7) point at a manifest by this exact URN.

---

### 13.3 `HASHBIND` — the hard binding (signature ↔ pixels)

`HASHBIND` is the cryptographic core: it ties the manifest to the **exact** bytes a decoder consumes, so any pixel/codec tamper breaks verification. It is one assertion in the `ASRT` store (§13.6, `assertion_type = ASRT_HASHBIND` or `ASRT_HASHBIND_TILES`), but its layout is normative here.

#### 13.3.1 Whole-asset binding (`ASRT_HASHBIND`)

```
HASHBIND payload:
  hash_alg     : u8     # closed enum, §13.3.3
  pad          : u8[3]  = 0
  exclusion_count : u32             # bounded by ILIM.max_exclusions
  exclusions[exclusion_count] : { start_offset : u64 ; length : u64 }   # absolute file offsets, ascending, non-overlapping
  digest_len   : u32                # = hash output length in bytes
  digest       : digest_len bytes
```

**Hashed input** = the entire CSIF file, in file order, **with the byte ranges in `exclusions[]` removed** (the non-excluded ranges are concatenated and fed to `hash_alg`).

Normative rules (all loud on violation):

- `exclusions[]` MUST be sorted ascending by `start_offset`, MUST NOT overlap, and each range MUST lie within `[0, file_size)` → else `E_PROV_EXCL_RANGE`.
- The exclusion set MUST cover **exactly** the `CSIG` signature region of this manifest plus any reserved zero-padding hole (§13.9). A signature cannot sign itself; the hole lets the manifest be embedded after signing.
- Chunk **headers and lengths outside the exclusions ARE hashed** (anti-insertion: copying a manifest into a fresh hole elsewhere changes a hashed length and is detected). Only the explicitly-excluded bytes escape the hash.
- `digest_len` MUST equal the output length of `hash_alg` → else `E_PROV_DIGEST_LEN`.

#### 13.3.2 Tile-granular binding (`ASRT_HASHBIND_TILES`)

For partial / streaming decode, a manifest MAY *additionally* carry a per-tile binding so a reader verifies only the tiles it touches (bounded memory; DRY with CSIF tiling, §tiling).

```
HASHBIND_TILES payload:
  hash_alg    : u8
  pad         : u8[3] = 0
  tile_count  : u32              # MUST equal ICOD.n_tiles
  tile_digest_len : u32
  tile_digests[tile_count] : tile_digest_len bytes   # digest of each tile's IDAT byte range, in tile index order
  root_alg    : u8               # closed enum, §13.3.3 — algorithm for the Merkle root below
  pad2        : u8[3] = 0
  root_digest_len : u32
  root_digest : root_digest_len bytes   # binary Merkle root over tile_digests[] (tree shape fixed in §13.3.4)
```

- Each `tile_digests[i]` is the hash of tile `i`'s exact IDAT byte range as given by the `ITOC`/tile index (§index). A reader decoding tile `i` verifies `tile_digests[i]` only.
- `root_digest` binds all tiles; the signing `CLAIM` (§13.4) references `root_digest` (not each tile) so one signature covers all tiles. `HASHBIND_TILES` does **not** replace `ASRT_HASHBIND`; if both are present, both MUST validate (whole-asset hash AND root). A manifest MAY carry only `ASRT_HASHBIND` (simplest), only `ASRT_HASHBIND_TILES` (streaming), or both.

#### 13.3.3 `hash_alg` / `root_alg` closed enum

| Value | Algorithm | digest_len |
|---|---|---|
| 0 | **reserved / invalid** (never "none" — a binding must name a real hash) | — |
| 1 | SHA-256 | 32 |
| 2 | SHA-384 | 48 |
| 3 | SHA-512 | 64 |
| 4 | BLAKE3-256 | 32 |

Value `0` and any value `≥ 5` → loud `E_PROV_HASH_ALG`. There is no escape hatch / "vendor hash". The hash routine lives once in the shared toolkit (`entropy`/`hash` module, DRY) and is reused by the container CRC, the integrity chunks (§security), and here.

#### 13.3.4 Merkle tree shape (frozen)

The tile Merkle tree is a **binary tree over `tile_digests[]` in tile-index order**, leaf-to-root, computed with `root_alg`:

- `leaf[i] = root_alg( 0x00 || tile_digests[i] )` (domain-separation prefix `0x00`).
- Internal node `= root_alg( 0x01 || left || right )` (prefix `0x01`).
- If a level has an odd node count, the last node is **promoted unchanged** to the next level (no duplication). The single remaining node is `root_digest`.

This is fully specified so any verifier reproduces the root bit-exactly.

---

### 13.4 `CLAIM` — Merkle root over the assertion store

The `CLAIM` enumerates **every** assertion by path + hash; the signature (§13.5) signs the serialized `CLAIM` bytes only. This lets one signature cover an arbitrary, extensible set of assertions, while any single assertion can be independently re-hashed.

```
CLAIM payload:
  claim_version  : u16 = 1
  hash_alg       : u8                # §13.3.3 — algorithm used for the REFs below
  pad            : u8 = 0
  generator_len  : u16
  generator      : generator_len bytes   # UTF-8 "producer-name/version (os-string)" — informational, but IT IS hashed in the claim
  instance_id_len: u16
  instance_id    : instance_id_len bytes # content-version id (URN); changes when pixels change
  ref_count      : u32                    # bounded by ILIM.max_assertions
  REFS[ref_count] : CLAIM_REF
```

```
CLAIM_REF:
  ref_kind    : u8     # 0 = LOCAL (assertion in THIS manifest's ASRT store)
                       # 1 = INGREDIENT (assertion is an external manifest, identified by URN)
  redacted    : u8     # 0 = present, 1 = redacted (bytes removed, hash retained — §13.4.1)
  pad         : u16 = 0
  target_index_or_urn_len : u32   # if LOCAL: assertion index within ASRT; if INGREDIENT: byte length of the URN that follows
  urn         : (present only when ref_kind==INGREDIENT) target_index_or_urn_len bytes
  digest_len  : u32
  digest      : digest_len bytes   # hash_alg over the assertion's EXACT TLV bytes (type+flags+size+payload), §13.4.2
```

**Verification of the claim** (mechanism):

1. For each `CLAIM_REF` with `redacted==0`: locate the target assertion, recompute `hash_alg(assertion-TLV-bytes)`, compare to `digest`. Mismatch → `E_PROV_CLAIM_REF` naming the ref index.
2. Verify the signature over the `CLAIM` bytes (§13.5).
3. Verify `HASHBIND`/`HASHBIND_TILES` over the pixels (§13.3).

Any assertion in `ASRT` that is **not** referenced by a `CLAIM_REF` is treated as **unsigned** and MUST be reported `present-but-unsigned` (§13.20) — it is detectably outside the signature's scope. There is no implicit "all assertions are signed".

#### 13.4.1 Redaction (tamper-evident deletion)

To remove a sensitive assertion (privacy) while keeping the proof tamper-evident: set `redacted=1` and **keep `digest`**; the assertion's payload bytes are removed from `ASRT` (the slot becomes an `ASRT_REDACTED` placeholder, §13.6). The claim still proves *what was there* (by hash) and that exactly one assertion was removed. Silent deletion (dropping both the assertion and its `CLAIM_REF`) is detectable as a claim/signature mismatch and is therefore impossible to do undetected. Redaction is an **explicit recorded act**, never a quiet drop.

#### 13.4.2 Assertion hashing scope

An assertion's hash covers its **complete TLV serialization**: the 4-byte `type`, 4-byte `flags`, 8-byte `size`, and the full `size`-byte payload — **excluding** the trailing container `crc32` (which is a transport check, not content). This makes the hash stable across re-CRC and makes assertion type+length insertion attacks detectable.

---

### 13.5 `CSIG` — claim signature (detached)

```
CSIG payload:
  sig_alg        : u8        # closed enum, §13.5.1
  pad            : u8[3] = 0
  signature_len  : u32
  signature      : signature_len bytes        # detached signature over the CLAIM payload bytes (§13.4)
  cert_count     : u32                          # bounded by ILIM.max_certs
  certs[cert_count] : { der_len : u32 ; der : der_len bytes }   # X.509 DER, leaf-first ... root-last
  has_timestamp  : u8        # 0 / 1
  pad2           : u8[3] = 0
  TIMESTAMP      : (present iff has_timestamp==1) §13.5.2
  has_revocation : u8        # 0 / 1
  pad3           : u8[3] = 0
  REVOCATION     : (present iff has_revocation==1) §13.5.3
```

- The signature is **detached** and covers exactly the `CLAIM` payload bytes — the claim is stored once, not duplicated in the signature.
- `certs[]` is an explicit leaf-first chain. The verifier parses it, validates the math (signature valid over the claim by the leaf cert's key), then applies a **policy trust list** (which roots are trusted) supplied separately by the verifier program — **never** baked into the format.

#### 13.5.1 `sig_alg` closed enum

| Value | Algorithm |
|---|---|
| 0 | **reserved / invalid** |
| 1 | Ed25519 |
| 2 | ECDSA P-256 (SHA-256) |
| 3 | ECDSA P-384 (SHA-384) |
| 4 | RSA-PSS (SHA-256, MGF1-SHA-256) |

Value `0` or `≥ 5` → loud `E_PROV_SIG_ALG`. No "unknown key type" guessing.

#### 13.5.2 `TIMESTAMP` (RFC-3161-style countersignature)

```
TIMESTAMP:
  token_len  : u32
  token      : token_len bytes      # TSA token over the `signature` value (§13.5)
  tsa_cert_count : u32              # bounded by ILIM.max_certs
  tsa_certs[tsa_cert_count] : { der_len : u32 ; der }
```

The timestamp proves the signature existed at a given time; a verifier MAY use it to accept a signature whose leaf cert later expired/revoked (the signature provably predated revocation). Whether to require a timestamp is **policy**.

#### 13.5.3 `REVOCATION` (offline-complete verification)

```
REVOCATION:
  ocsp_len : u32 ; ocsp : ocsp_len bytes   # stapled OCSP response (0-length = absent)
  crl_len  : u32 ; crl  : crl_len bytes    # CRL data (0-length = absent)
```

Embedding revocation data makes verification offline-complete. Its **presence** is declared (`has_revocation`), never assumed.

#### 13.5.4 Honest verify slot

A conformant CSIF *verifier* MUST implement at least one `sig_alg` and MUST return a precise status. A reader that ships **no** crypto MUST return `signature_valid = UNVERIFIED` for the relevant fields (§13.20) — it MUST NOT return a fabricated `valid`. There is no fake "always valid" stub (the no-hollow-impl rule).

---

### 13.6 `ASRT` — the assertion store

```
ASRT payload:
  assertion_count : u32             # bounded by ILIM.max_assertions
  assertions[assertion_count] : ASSERTION   # each is a TLV record (type+flags+size+payload+crc32)
```

Each `ASSERTION` is a typed TLV. The `assertion_type` (its `type` field) is drawn from a **label namespace** to stay collision-free:

- `cstos.*` — CSIF-native assertion types (closed registry, §13.6.1).
- `ext.*` — third-party assertion types (declared 4-byte tag); still hashed by the `CLAIM`, hence still signed and tamper-evident, but reported `present, unrecognized` (§13.13) — never interpreted, never silently trusted as meaningful.

An assertion whose `type` is unknown to a verifier is **skipped-but-recorded** (forward-compat, exactly like CSE skippable segments). It is never dropped from the hash and never guessed.

#### 13.6.1 Native assertion-type registry (closed)

| `assertion_type` | Symbol | Section |
|---|---|---|
| `cstos.hash.data` | `ASRT_HASHBIND` | §13.3.1 |
| `cstos.hash.tiles` | `ASRT_HASHBIND_TILES` | §13.3.2 |
| `cstos.disclose` | `ASRT_DISCLOSE` | §13.7.1 (AI / algorithmic source) |
| `cstos.actions` | `ASRT_ACTIONS` | §13.7.2 (edit log) |
| `cstos.ingredient` | `ASRT_INGREDIENT` | §13.7.3 (lineage) |
| `cstos.softbind.fp` | `ASRT_SOFTBIND_FINGERPRINT` | §13.8.1 |
| `cstos.softbind.wm` | `ASRT_SOFTBIND_WATERMARK` | §13.8.2 |
| `cstos.thumbnail` | `ASRT_THUMBNAIL` | thumbnail of the asset at sign time (reuses §thumbnail codec dispatch) |
| `cstos.redacted` | `ASRT_REDACTED` | §13.4.1 placeholder (carries only the original `assertion_type` tag) |

Adding a native assertion = one registry entry + a `prov_version` bump (family forward-compat), never a free-form string.

---

### 13.7 AI disclosure, edit log, lineage

#### 13.7.1 `ASRT_DISCLOSE` — AI / algorithmic-source disclosure (wired to `NEURAL`)

The signed, standardized statement that content was AI-generated, AI-edited, or composited — the AI-era hook (EU AI Act-class transparency leans on exactly this).

```
ASRT_DISCLOSE payload:
  digital_source_type : u8     # closed enum, §13.7.1.1
  pad                 : u8[3] = 0
  model_id_len        : u16 ; model_id  : model_id_len bytes    # UTF-8, may be 0-length
  model_ver_len       : u16 ; model_ver : model_ver_len bytes
  region_count        : u32                                      # 0 = whole image
  regions[region_count] : { x:u32 ; y:u32 ; w:u32 ; h:u32 }      # AI-affected rects (pixel coords); MAY be tile-aligned
```

##### 13.7.1.1 `digital_source_type` closed enum

| Value | Meaning |
|---|---|
| 0 | `humanCapture` (camera/scanner, no AI) |
| 1 | `humanEdit` (human edits, no AI) |
| 2 | `algorithmicEdit` (deterministic algorithmic edit, non-generative) |
| 3 | `trainedAlgorithmicMedia` (generative AI produced the content) |
| 4 | `compositeWithAI` (mix of captured + AI-generated regions) |
| 5 | `algorithmicMedia` (fully synthetic, non-trained, e.g. rendered) |

Value `≥ 6` → `E_PROV_DISCLOSE_TYPE`. AI involvement is a **declared enum + model id**, never inferred.

##### 13.7.1.2 `NEURAL` codec cross-check (normative)

A learned codec is itself an algorithmic transform of the pixels and MUST be disclosed:

> **MUST:** If `ICOD.codec_id == 5` (`NEURAL`) is used for any tile/plane of the active image, the active manifest MUST contain at least one `ASRT_DISCLOSE` whose `digital_source_type ∈ {2,3,5}` and whose `regions[]` cover (or are empty ⇒ whole-image) the `NEURAL`-coded area, and whose `model_id` matches the `NEURAL` `ICOD` params' declared `model_id` (§neural-codec).

A verifier that finds `NEURAL` in `ICOD` but **no** matching `ASRT_DISCLOSE` MUST report `E_PROV_NEURAL_UNDISCLOSED` (a distinct status, §13.20). This makes learned compression refuse to be an undisclosed black box — the format is honest about how the pixels came to be. (A CSIF *encoder* emitting `NEURAL` without disclosure produces a non-conformant file; the corruption corpus, §13.21, asserts the exact error.)

#### 13.7.2 `ASRT_ACTIONS` — explicit, ordered, signed edit log

```
ASRT_ACTIONS payload:
  action_count : u32             # bounded by ILIM.max_actions; MUST be ≥ 1 (a standard manifest needs an origin action)
  actions[action_count] : ACTION
```

```
ACTION:
  action_kind   : u8     # closed enum, §13.7.2.1
  has_timestamp : u8     # 0/1
  digital_source_type_link : u8   # 0xFF = none, else index into this manifest's ASRT_DISCLOSE list (links this action to its AI disclosure)
  pad           : u8 = 0
  agent_len     : u16 ; agent : agent_len bytes      # UTF-8 software-agent "name/version"
  timestamp     : (iff has_timestamp) i64            # seconds since 1970-01-01T00:00:00Z (signed; pre-epoch allowed)
  region_count  : u32 ; regions[region_count] : { x:u32 ; y:u32 ; w:u32 ; h:u32 }
  param_count   : u32 ; params[param_count] : TYPED_KV   # typed key/value TLV (reuses §metadata IMET value-type enum)
```

##### 13.7.2.1 `action_kind` closed enum

| Value | Action | Value | Action |
|---|---|---|---|
| 0 | `created` (origin) | 7 | `recompressed` |
| 1 | `opened` (origin) | 8 | `watermarked` |
| 2 | `cropped` | 9 | `inpaintedAI` |
| 3 | `resized` | 10 | `outpaintedAI` |
| 4 | `colorAdjusted` | 11 | `redacted` |
| 5 | `filtered` | 12 | `convertedFormat` |
| 6 | `composited` | 13 | `metadataEdited` |

**MUST:** `actions[0].action_kind ∈ {0 created, 1 opened}` (the chain has a root) → else `E_PROV_NO_ORIGIN`. Unknown future actions get a new enum value + `prov_version` bump — no free-form "misc" string that defeats honesty. Value `≥ 14` in a file claiming `prov_version=1` → reported `present, unrecognized action` (skippable within the assertion if its `flags` allow; otherwise loud).

#### 13.7.3 `ASRT_INGREDIENT` — lineage (parentOf / componentOf)

```
ASRT_INGREDIENT payload:
  relationship : u8     # 0 = parentOf (derived-from)  ;  1 = componentOf (composited-from)
  pad          : u8[3] = 0
  ingredient_manifest_urn_len : u16 ; ingredient_manifest_urn : ... bytes   # URN of an embedded prior MANIFEST in THIS PROV chunk
  pinned_csig_digest_alg : u8 ; pad2 : u8[3] = 0
  pinned_csig_digest_len : u32 ; pinned_csig_digest : ... bytes             # hash of the ingredient manifest's CSIG (pins the exact signed version)
  has_thumbnail : u8 ; pad3 : u8[3] = 0
  thumbnail_assertion_index : (iff has_thumbnail) u32                       # index of an ASRT_THUMBNAIL for this ingredient
  validation_status : u8       # the producer's recorded validation result at import time (advisory; §13.20 enum)
  pad4 : u8[3] = 0
```

- Prior manifests are stored as additional `MANIFEST` records in the **same** `PROV` chunk (§13.2) and referenced here by their content-addressed URN; `pinned_csig_digest` pins exactly *which signed version* was imported (so a later re-sign of the source can't silently retro-change history).
- A verifier walks `parentOf`/`componentOf` edges to reconstruct the provenance tree and reports per-link validity (§13.20). Re-importing an already-present manifest: compare by URN+`pinned_csig_digest`; re-id only on genuine byte difference (deterministic, explicit). Lineage is recorded data referenced by stable id+hash — never inferred from filenames or timestamps. The `parentOf` graph MUST be **acyclic** (a manifest cannot be its own ancestor); cycle → `E_PROV_INGREDIENT_CYCLE`, bounded recursion depth = `ILIM.max_ingredient_depth`.

---

### 13.8 Soft binding — durable credentials (codec-agnostic, registry-recoverable)

Hard bindings die when metadata is stripped (screenshot, re-save). Soft bindings let the manifest be **re-discovered from a registry** by matching a mark/fingerprint computed over the **pixels**. Both descriptors are signed assertions (so even the invisible mark is *announced* — no covert side channel), while the actual embed/extract algorithm is a **policy module**, dispatched by a registry id exactly like a codec (`scheme_id` ≈ `codec_id`).

#### 13.8.1 `ASRT_SOFTBIND_FINGERPRINT` (perceptual hash)

```
ASRT_SOFTBIND_FINGERPRINT payload:
  fp_scheme_id : u16    # closed registry id naming a perceptual-hash family (NOT a cryptographic hash)
  pad          : u16 = 0
  fp_value_len : u32 ; fp_value : fp_value_len bytes   # the perceptual digest, stable under recompression
```

`fp_scheme_id` selects a perceptual-hash family from the **soft-binding registry** (distinct from `hash_alg` §13.3.3, because perceptual hashing ≠ cryptographic hashing). Unknown `fp_scheme_id` → reported `softbind unrecognized`, not an error (a verifier without that scheme simply can't re-discover).

#### 13.8.2 `ASRT_SOFTBIND_WATERMARK`

```
ASRT_SOFTBIND_WATERMARK payload:
  wm_scheme_id : u16    # closed registry id naming a watermark family (the SCHEME is declared; the algorithm is pluggable POLICY)
  strength     : u16    # scheme-defined embed strength
  wm_payload_ref_len : u16 ; wm_payload_ref : ... bytes   # what the mark encodes (typically the manifest_id URN)
  region_count : u32 ; regions[region_count] : { x:u32 ; y:u32 ; w:u32 ; h:u32 }   # 0 = whole image
```

The mark itself lives in the pixels (embedded by the watermark policy module); only its **descriptor** is a signed assertion. Recovery: a verifier with the matching `wm_scheme_id` extracts the mark → `manifest_id` URN → fetches the manifest from a registry/sidecar. "All watermark algorithms work" architecturally, mirroring "all codecs work": the registry id is the seam, the embed/extract is policy. The mark is **never** covert — it is always declared by this assertion.

---

### 13.9 Sign-then-embed: the reserved hole + deterministic serialization

Signing a file that contains its own signature is solved with an explicit, pre-sized, hash-excluded hole and a canonical serialization.

**Encoder procedure (normative):**

1. Lay out all chunks. Reserve the active manifest's `CSIG` `signature`/`certs`/`timestamp` region **plus a growth pad** as a contiguous **zero-filled** region of declared size `hole_len` at a known `hole_off`.
2. Record `{ start_offset = hole_off, length = hole_len }` as the (or part of the) exclusion set in `ASRT_HASHBIND` (§13.3.1). The hole is **declared**, not discovered.
3. Compute the binding digest over everything else (§13.3).
4. Build and sign the `CLAIM` (§13.4–§13.5).
5. Write the signature, cert chain, and (optional) timestamp into the reserved hole; zero any unused pad tail.

**Canonical serialization (normative):** fixed field order, fixed integer encoding (LE), no optional padding/alignment ambiguity beyond what this spec mandates, all "absent" optionals encoded by their explicit `has_*`/count=0 form. Re-serialization MUST be **bit-identical**, so the binding digest is reproducible by any verifier from the declared exclusion ranges. The pad size is chosen and written explicitly (no hidden allocation), matching the project's byte-identical-reproducibility discipline. Solving the sign-then-embed loop is part of closing the design — not deferred.

---

### 13.10 The CSIF perceptual quality scale — `IQMT`

CSIF defines a single canonical quality scale **CQ (Caustic Quality)** in which a lossy encoder's target is expressed as an explicit **(metric, target value)** pair — never an opaque "q-number". `'-q 80'` means nothing portable; the CSIF quality knob *is* a named-metric target, declared in the file.

`IQMT` (Image Quality / Metric Target) is **mandatory for any lossy image** (`ICOD.is_lossless == 0`) and **forbidden for lossless** (`ICOD.is_lossless == 1` ⇒ metric is `NONE` and `IQMT` MUST be absent or `metric_id==0`). It is a chunk in `ICOD` scope (one `IQMT` per coded image; for multi-part / multi-image files, one per part).

```
IQMT payload:
  metric_id          : u8     # closed registry, §13.11
  target_polarity_hint : u8   # informational copy of the metric's polarity (0=higher-better, 1=lower-better); MUST match the registry
  achieved_is_measured : u8   # 0 = encoder estimate ; 1 = measured against the source at encode time
  pad                : u8 = 0
  target_value       : f32    # the requested target on metric_id's scale
  achieved_value     : f32    # the encoder's achieved value (estimate or measured per the flag above)
  metric_colorspace_ref : u32 # index into the declared color model the metric ran in (§13.14); 0xFFFFFFFF = metric's registry-default space
```

- **Lossy ⇒ `IQMT` mandatory.** A lossy file without `IQMT`, or with `metric_id==0`, is non-conformant → `E_IQMT_MISSING`.
- `metric_id==0` (`NONE`) is the lossless sentinel and is the **only** value allowed to coexist with `is_lossless==1`.
- The **achieved** value is recorded, not just the target — the encode decision trail is visible (§13.15). `achieved_is_measured` distinguishes a true measurement from an encoder estimate honestly.
- The metric is **policy** (an encoder chose it); the container only records the explicit fact — **mechanism**.

#### 13.10.1 Anchored target semantics (reproducible mapping)

The quality knob maps to a reproducible target by *definition of the metric's scale* (§13.11), with these spec-fixed anchors:

- `BUTTERAUGLI_MAXNORM` `target_value = 1.0` ≈ 1 JND ≈ "visually lossless" (the libjxl distance-1 anchor).
- `SSIMULACRA2` `target_value = 90.0` ≈ "visually lossless"; `70.0` ≈ "high quality"; `30.0` ≈ "low".
- `PSNR` `target_value` in dB.

An encoder hitting a `(metric, target)` MUST iterate quantization (globally and/or via the AQ field, §13.16) until the **achieved** metric crosses the target, then record both. Two encoders may legitimately reach the same target with different bytes/quant — that is correct; the *file* declares what "this quality" means, reproducibly, via the metric definition.

---

### 13.11 Perceptual-metric registry (closed; mirrors the codec registry)

Metrics get the same closed-registry / vtable treatment as codecs, so "all quality models work" is architecturally true and the quality scale is never silently welded to one metric. Each metric is a `{ compute, polarity, unit, input_colorspace, frozen_params }` interface.

| `metric_id` | Symbol | Polarity | Unit | Input colorspace (§13.14) | Frozen params |
|---|---|---|---|---|---|
| 0 | `NONE` (lossless) | — | — | — | — |
| 1 | `PSNR` | higher-better | dB | linear-light over file primaries | peak = sample max for declared bit depth |
| 2 | `PSNR_HVS_M` | higher-better | dB | luma + DCT-domain CSF | CSF table v1, masking constants v1 |
| 3 | `MS_SSIM` | higher-better | [0,1] | luma (declared transfer) | 5-scale weights v1 |
| 4 | `SSIMULACRA2` | higher-better | (-∞, 100] | XYB (§13.14) | scale weights v1, error-map asymmetry v1 |
| 5 | `BUTTERAUGLI_MAXNORM` | lower-better | JND | XYB (§13.14) | frequency/masking constants v1, max-norm reducer |
| 6 | `BUTTERAUGLI_3NORM` | lower-better | JND | XYB (§13.14) | constants v1, p=3 norm reducer |

- `frozen_params` are **declared, versioned constants in the spec** (no hidden tuning) so a score is reproducible across implementations. A metric's parameter set is identified by `(metric_id, prov/metric version)`.
- The metric interface is exactly `{ compute(reference_pixels, decoded_pixels, region) -> scalar }` — an honest closed op-set, no side channels. The `compute`/`polarity`/`unit`/`input_colorspace`/`frozen_params` live in the shared toolkit's `perceptual` module (DRY).
- Adding a metric = one registry entry + frozen params + a version bump. Value `≥ 7` (in `metric_version=1`) → `E_IQMT_METRIC_ID`. **No vendor-metric escape hatch.**
- The seam container↔metric mirrors container↔codec mirrors the kernel KObject vtable — one uniform pattern across the system.

---

### 13.12 `IRCM` — rate-control mode & bitrate provenance

`IRCM` (Image Rate-Control Mode) records *how the bits were chosen*, so a viewer/transcoder can reason about quality without re-measuring and avoid double-lossy mistakes. It is **mandatory whenever `IQMT` is present** (i.e. for lossy images).

```
IRCM payload:
  rc_mode        : u8     # closed enum, §13.12.1
  pad            : u8[3] = 0
  target_a       : f32    # primary target (meaning depends on rc_mode)
  target_b       : f32    # secondary target/cap (meaning depends on rc_mode); NaN = unused
  achieved_bpp   : f32    # achieved bits-per-pixel over the active image (declared, not guessed)
  # the achieved METRIC value lives in IQMT.achieved_value (single source of truth, no duplication)
```

#### 13.12.1 `rc_mode` closed enum

| Value | Mode | `target_a` | `target_b` |
|---|---|---|---|
| 0 | `FIXED_QUANT` | quantizer index | unused (NaN) |
| 1 | `CONSTANT_QUALITY` | `IQMT.target_value` (metric target) | unused (NaN) |
| 2 | `CONSTANT_RATE` | target bpp | unused (NaN) |
| 3 | `CONSTRAINED_QUALITY` | metric target | max bpp cap |

Value `≥ 4` → `E_IRCM_MODE`. Every number is explicit — "every operation is visible" applied to the encode decision trail. Mechanism (recording the fact) in the container; policy (which mode, how to search) in the encoder.

---

### 13.13 `QLYR` — quality-scalable layers with per-pass metric checkpoints

`QLYR` is **optional, skippable**. It labels each progressive pass/layer (DC→AC, or wavelet quality layers; §progressive) with the **cumulative achieved metric** it reaches, so a streaming decoder knows when it has hit "visually lossless" and can stop fetching bytes. There is no "decode until it looks ok" — the file declares the quality of every prefix.

```
QLYR payload:
  metric_id      : u8     # MUST equal IQMT.metric_id (same scale for all checkpoints)
  pad            : u8[3] = 0
  layer_count    : u32                          # bounded by ILIM.max_quality_layers
  layers[layer_count] : {
     byte_offset            : u64               # absolute offset into IDAT of this layer's start
     byte_length            : u64
     cumulative_achieved    : f32               # metric value if the decoder stops after THIS layer
     cumulative_achieved_is_measured : u8       # 0 estimate / 1 measured
     pad                    : u8[3] = 0
  }
}
```

- `byte_offset/length` are explicit byte ranges into `IDAT` — a decoder reads exactly the declared prefix (bounded memory, partial decode by construction; this extends CSIF tiling to the *quality* axis).
- The bit-ordering policy (most-visible-error-reducing bits first) is the encoder's; the layer map is mechanism. `cumulative_achieved` MUST be **monotonic** in `metric_id`'s improving direction (per `polarity`); non-monotonic → `E_QLYR_NONMONOTONIC` (an encoder contract violation, caught by the encoder-conformance corpus, §13.21).

---

### 13.14 Specified perceptual colorspace for metric computation (declared, not assumed)

`SSIMULACRA2` and `BUTTERAUGLI` do **not** operate in sRGB; they run in a perceptually-uniform opponent space (**XYB**, an LMS-cone + gamma model). If CSIF says "SSIMULACRA2 target 90" without pinning the colorspace the metric runs in, the number is not reproducible.

Therefore:

- Each metric in the registry (§13.11) **declares** its input colorspace and the **exact** transform from the file's declared color model (`IHDR`/`ICLR` CICP, §color) into that space. For the XYB metrics that is: file-RGB(declared primaries+transfer) → linear-light → **XYB** via the **frozen XYB matrix and gamma constants v1** (in the shared `color` toolkit, DRY).
- Because `IHDR`/`ICLR` already mandate explicit primaries / transfer / matrix (Caustic rule: colorspace always declared, "Unspecified" banned — §color), the metric has **zero degrees of freedom**: it cannot pick a gamma or primaries heuristically. This is the anti-magic principle making perceptual scoring reproducible by construction.
- `IQMT.metric_colorspace_ref` MAY override the registry-default input space only with another **declared** color model in the file; `0xFFFFFFFF` selects the registry default. The conversion is total and reproducible either way.

---

### 13.15 Achieved-quality honesty rules

- A lossy CSIF MUST record `IQMT.achieved_value` and `IRCM.achieved_bpp`. These are declared facts about *this* encode, not re-derivable guesses from the data.
- `achieved_is_measured == 1` means the encoder measured the achieved metric against the **source** at encode time (with the §13.14 colorspace). `== 0` means it is the encoder's internal estimate. A file MUST NOT claim `measured` if it was not.
- This makes generation loss visible: a transcoder reading `IRCM`/`IQMT` knows the prior quality and can refuse a needless re-lossy pass.

---

### 13.16 `IAQ` — adaptive-quantization map (explicit tuning hook, not magic)

The single biggest perceptual lever is spatial bit allocation: hide error where masking is strong (texture, high contrast), spend bits where it is visible (smooth gradients, faces, edges). CSIF carries this as an **explicit per-block quant multiplier field** that the decoder needs to invert quantization exactly — it is **codec payload, not a side channel**.

The AQ field is itself stored as a declared sub-image / field in `IDAT` for codecs that use it (`DCT` id 3, `BLOCK` id 4); `IAQ` is the **descriptor** that tells a reader how to parse it. (For codecs whose AQ is intrinsic to their bitstream, `IAQ` records the parameters; the field bytes live in `IDAT`.)

```
IAQ payload:
  aq_present       : u8     # 0 = uniform quant (no field) ; 1 = field present
  field_storage    : u8     # 0 = inline in IDAT as a declared sub-image ; 1 = separate IDAT stream by index
  block_log2_w     : u8     # AQ block width  = 1 << block_log2_w  (e.g. 3 => 8)
  block_log2_h     : u8     # AQ block height = 1 << block_log2_h
  base_quant       : f32    # the global quant step the multipliers scale
  mult_fixed_point : u8     # multipliers stored as fixed-point with this many fractional bits
  mult_codec_id    : u8     # codec used to entropy-code the multiplier field (typically MODULAR id 2) — DRY
  field_stream_index : u16  # (field_storage==1) index of the IDAT stream holding the field; else 0
  # field dimensions are COMPUTED: ceil(width / block_w) × ceil(height / block_h) from IHDR — not stored, not guessed
```

**Decode (pure mechanism):** read `base_quant`, decode the multiplier field via `mult_codec_id`, and for each block set `quant_step = base_quant * multiplier[block]` (multiplier interpreted as fixed-point with `mult_fixed_point` fractional bits). Nothing is heuristic at decode time — the reader reads two declared things and multiplies.

**Encode (policy):** *how* the encoder computes the map — luminance masking (Weber/contrast on local mean), texture/activity masking (local variance or gradient energy), edge proximity, and/or butteraugli feedback — is encoder policy living in the shared `perceptual` toolkit as a pure function `aq_field(tile, params) -> multiplier[]` (DRY across `DCT`/`BLOCK`). The *model* is policy; the *field layout* is mechanism declared here.

- Bounded memory: the multiplier array size is computable up front (`ceil(w/block_w) × ceil(h/block_h)`), per-tile, streams with tiling, no hidden allocation.
- A reader that ignores `IAQ` on a codec that requires it cannot reconstruct exact quant ⇒ `IAQ` is **not** skippable for AQ-using codecs (`CHUNK_CRITICAL=1`); it is required-capability like a load-bearing transform.

---

### 13.17 `IROI` — region quality / perceptual-importance map (explicit)

`IROI` lets bits go where they *semantically* matter (faces, foreground, author-marked regions), distinct from where error *hides* (§13.16). Both modulate the final per-block quant that gets coded; combining them is SOTA. `IROI` is **optional, skippable** — because its effect is already baked into the coded AQ field/quant in `IDAT`, a decoder needs **nothing extra** (no magic re-derivation); `IROI` is preserved for honesty/provenance and re-encode tooling.

```
IROI payload:
  source_id     : u8     # closed enum: 0=MANUAL, 1=SALIENCY_MODEL, 2=FACE_DETECT, 3=AUTHOR_ANNOTATION (advisory; does not change decode)
  has_grid      : u8     # 0/1 — a coarse per-tile importance grid present
  pad           : u16 = 0
  region_count  : u32                          # bounded by ILIM.max_roi_regions
  regions[region_count] : { x:u32 ; y:u32 ; w:u32 ; h:u32 ; weight : f32 }   # weight in [0,1]; higher => lower quant => more bits
  grid_w        : u32 ; grid_h : u32           # (has_grid==1) importance grid dims (tile resolution)
  grid[grid_w*grid_h] : (has_grid==1) f32      # per-cell importance in [0,1]
```

- `IROI` is **input to the encoder's policy**. Because it changes the *coded* quant field, the result is fully captured in `IDAT`; the map's *origin* (`source_id`) is recorded for provenance but **does not change decoding**.
- It is the Caustic-explicit redesign of JPEG-2000 MAXSHIFT ROI: the region is **declared data**, never inferred from coefficient magnitudes (the original infers the region — a heuristic the philosophy forbids). Multiple weighted regions are supported, all declared. Region list length is bounded; the grid is tile-resolution and bounded.

---

### 13.18 `IGRN` — film-grain / texture synthesis (explicit, deterministic, optional)

Uniform noise is near-incompressible; coding it wastes bits, re-synthesizing it keeps the image natural. `IGRN` is **optional, skippable**: a decoder that ignores it shows the clean (denoised) image — honest, declared degradation, never broken.

```
IGRN payload:
  ar_lag        : u8     # autoregressive lag (0..3)
  num_y_points  : u8     # piecewise-linear scaling points for luma
  num_cb_points : u8
  num_cr_points : u8
  seed          : u32    # deterministic PRNG seed (the PRNG algorithm is spec-frozen, §13.18.1)
  ar_coeffs_y[ (2*ar_lag+1)*(ar_lag)+ar_lag ] : i8    # AR coefficients, scan order frozen in §13.18.1
  ar_coeffs_cb[...] : i8                                # present iff chroma_scaling_from_luma==0
  ar_coeffs_cr[...] : i8
  scaling_y[num_y_points]   : { value:u8 ; scale:u8 }  # luma intensity -> grain amplitude LUT
  scaling_cb[num_cb_points] : { value:u8 ; scale:u8 }
  scaling_cr[num_cr_points] : { value:u8 ; scale:u8 }
  scaling_shift            : u8     # right-shift applied to scaled grain
  chroma_scaling_from_luma : u8     # 1 => derive chroma grain from luma model
  overlap_flag             : u8     # 1 => overlap grain blocks to avoid block edges
  pad                      : u8 = 0
```

#### 13.18.1 Determinism (normative)

The PRNG algorithm, the AR recurrence (generating a 64×64 grain template from `seed`+coeffs), the scaling-LUT interpolation, and the fixed-point arithmetic are **fully specified, integer-only constants in the spec (grain model v1)** so synthesis is **bit-reproducible** across decoders (same `seed`+coeffs ⇒ same grain everywhere — explicitness over "some randomness"). Synthesis is a closed shared-toolkit op `grain_synthesize(model, intensity_plane) -> caller_buffer` (bounded, no hidden alloc). Mechanism/policy: the container carries the chunk; applying grain is the renderer's declared choice.

#### 13.18.2 Conformance interaction

The decode conformance reference (§13.21) includes **two** golden outputs for a grain-bearing test vector: the **pre-grain** clean image (base conformance) and the **post-grain** image (grain-aware conformance). A grain-aware decoder MUST reproduce the post-grain golden bit-exactly.

---

### 13.19 RDO seam (encoder-side, decoder-invariant)

CSIF declares — in the spec, not as a file field — the canonical way encoders should choose bits: Lagrangian rate-distortion optimization, binding the metric registry (distortion) to the entropy module (rate).

```
toolkit (encoder side, shared, DRY):
  rdo_cost(distortion_metric_id, rate_estimate_bits, lambda) -> f64 = distortion + lambda * rate_estimate_bits
```

- `distortion` is computed by a metric from the registry (§13.11), ideally perceptual on the AQ-weighted residual; `rate_estimate_bits` comes from the shared `entropy` module (rANS/range model). `lambda` is derived from the `IQMT` target.
- This is **policy** (encoder-only); the decoder never sees `lambda` and the decoder contract is untouched. Stating it once prevents each codec from hacking ad-hoc rate control and gives every codec perceptual RDO via the same seam (DRY). Trellis quantization (optimal coefficient rounding under RDO) is the textbook instance. LZ parse quality, mode search, and `lambda` schedule are all **decoder-invariant encoder policy** — a smarter future encoder drops in without a format change ("all algorithms work").

---

### 13.20 Verification & conformance result model (explicit, fail-loud)

A CSIF verifier produces a **structured, multi-field result** — never a single boolean. Each check is named; missing provenance is a distinct state from tampered or untrusted.

```
ProvResult:
  has_manifest     : bool                  # PROV chunk present with ≥1 manifest
  binding_valid    : tri   { VALID, INVALID, UNCHECKED }   # pixels match HASHBIND (§13.3.1)
  tiles_valid      : tri                    # per-tile + Merkle-root match (§13.3.2); UNCHECKED if not present
  claim_consistent : tri   { VALID, INVALID, UNCHECKED }   # all CLAIM_REF hashes match (§13.4)
  signature_valid  : quad  { VALID, INVALID, UNVERIFIED, UNCHECKED }   # math over claim by leaf cert; UNVERIFIED = no crypto impl (§13.5.4)
  timestamp_valid  : quad
  trust_status     : enum  { TRUSTED, UNTRUSTED, NO_TRUST_LIST }       # POLICY: leaf chains to a trusted root in the verifier's list
  neural_disclosed : tri   { OK, MISSING, NOT_APPLICABLE }             # §13.7.1.2 cross-check
  per_ingredient[] : { urn ; relationship ; status : enum }            # §13.7.3 lineage statuses
  per_action_unrecognized[] : indices of unknown actions (§13.7.2.1)
  unknown_assertions[]      : { type ; signed:bool }                   # ext.* / future types: present, recorded, not interpreted (§13.13)
  unsigned_assertions[]     : indices of ASRT entries not covered by any CLAIM_REF (§13.4)
  failing_field             : (on any *_INVALID) the exact range/assertion/ref index that failed
```

Rules:

- **No magic boolean.** A viewer reports precisely what is trusted and what is not. `has_manifest=false` ⇒ "no Content Credentials present" (an honest state, never fabricated as "unsigned-but-ok").
- **Distinct tamper states.** `binding_valid=INVALID` (pixels changed), `claim_consistent=INVALID` (an assertion changed), and `signature_valid=INVALID` (claim/key mismatch) are reported separately, each with `failing_field`.
- **Fail loud, bounded.** Any structural violation (§13.3–§13.8 ranges, cycles, missing-active, bad enums) yields the numbered `E_PROV_*` error and a precise locus, matching the kernel's bounded, register-level error ethos. There is no silent recovery, no hidden retry.
- **Trust is policy.** The verifier reports math facts (`signature_valid`, `binding_valid`); whether to trust the signer (`trust_status`) is a separately-supplied trust-list, never baked into the format.

#### 13.20.1 Error-code enumeration (negative, family convention)

| Code | Symbol | Condition |
|---|---|---|
| -13·01 | `E_PROV_RANGE` | a `manifest_offsets[]` entry or sub-record exceeds the `PROV` payload |
| -13·02 | `E_PROV_NO_ACTIVE` | `manifest_count>0` but `active_manifest_index` invalid |
| -13·03 | `E_PROV_HASH_ALG` | `hash_alg`/`root_alg` = 0 or ≥5 |
| -13·04 | `E_PROV_EXCL_RANGE` | exclusion not sorted/non-overlapping/in-file |
| -13·05 | `E_PROV_DIGEST_LEN` | `digest_len` ≠ `hash_alg` output length |
| -13·06 | `E_PROV_CLAIM_REF` | a `CLAIM_REF` digest mismatch (names ref index) |
| -13·07 | `E_PROV_SIG_ALG` | `sig_alg` = 0 or ≥5 |
| -13·08 | `E_PROV_DISCLOSE_TYPE` | `digital_source_type` ≥ 6 |
| -13·09 | `E_PROV_NEURAL_UNDISCLOSED` | `NEURAL` codec used, no matching `ASRT_DISCLOSE` |
| -13·10 | `E_PROV_NO_ORIGIN` | `ASRT_ACTIONS` lacks a `created`/`opened` origin at index 0 |
| -13·11 | `E_PROV_INGREDIENT_CYCLE` | `parentOf` graph has a cycle or exceeds `max_ingredient_depth` |
| -13·12 | `E_IQMT_MISSING` | lossy image without `IQMT` or `metric_id==0` |
| -13·13 | `E_IQMT_METRIC_ID` | unknown `metric_id` for the declared `metric_version` |
| -13·14 | `E_IRCM_MODE` | `rc_mode` ≥ 4 |
| -13·15 | `E_QLYR_NONMONOTONIC` | quality-layer checkpoints not monotonic (encoder-conformance) |
| -13·16 | `E_IQMT_LOSSLESS_CONFLICT` | `is_lossless==1` but `IQMT` present with `metric_id≠0` |

(Numbering style mirrors `cse.cst`'s enumerated negative returns; the `13·NN` prefix scopes this section.)

---

### 13.21 Integration with the conformance / test-vector plan

This section's structures plug directly into the format's normative conformance corpus (§security, §metrics). Two **explicitly separated** contracts, matching mechanism/policy:

#### 13.21.1 Decoder conformance — bit-exact, including grain & quality prefixes

- CSIF mandates an **exact fixed-point inverse** for every lossy codec (frozen IDCT/dequant arithmetic; no "any reasonable IDCT" magic), so the *decoder* is deterministic even though the *encoder* is free. The only float freedom is the encoder's quality search, never the decoder.
- The corpus ships, for each vector: input pixels + `.csif` + the **exact decoded byte dump** (declared colorspace/bit-depth), validated by hash. Lossless codecs (RAW/QOI/MODULAR) ⇒ max-abs-error = 0. Lossy ⇒ bit-exact against the reference dump (the AQ field §13.16 is applied deterministically; uniform vs adaptive both reproduce exactly because `IAQ` is read mechanically).
- **Grain vectors** carry two golden dumps (pre- and post-`IGRN`, §13.18.2). **`QLYR` vectors** include golden dumps for each declared truncation prefix, proving a partial decode at layer `k` reproduces the declared bytes *and* lands at the declared `cumulative_achieved` metric.

#### 13.21.2 Encoder metric-band conformance

- Optional but normative: on the reference image corpus, an encoder asked for `(metric_id, target_value)` MUST land within a declared band `[target − eps(metric), target + eps(metric)]` of the **achieved** metric measured against the source in the metric's pinned colorspace (§13.14). The recorded `IQMT.achieved_value` MUST itself fall in band when `achieved_is_measured==1`. `eps` is declared per metric in the registry.
- `QLYR` monotonicity (§13.13) and the `IRCM` `CONSTRAINED_QUALITY` cap (`achieved_bpp ≤ target_b`) are checked here.

#### 13.21.3 Provenance corpus (positive + corruption)

- **Positive:** signed `.csif` files (each `sig_alg`), with embedded ingredient chains, an `ASRT_DISCLOSE`+`NEURAL` pair, a redacted assertion, and a tile-bound (`HASHBIND_TILES`) example. A conformant verifier MUST produce the declared `ProvResult` for each.
- **Corruption / adversarial:** one pixel flipped (⇒ `binding_valid=INVALID` at the exact range), one assertion byte flipped (⇒ `claim_consistent=INVALID` naming the ref), a tampered signature (⇒ `signature_valid=INVALID`), `NEURAL` without disclosure (⇒ `E_PROV_NEURAL_UNDISCLOSED`), an out-of-range exclusion (⇒ `E_PROV_EXCL_RANGE`), an ingredient cycle (⇒ `E_PROV_INGREDIENT_CYCLE`), a lossy file missing `IQMT` (⇒ `E_IQMT_MISSING`), and a banned `metric_id`/`hash_alg`/`sig_alg` value (⇒ the matching `E_*`). Each vector asserts the **exact** numbered error and locus — proving verifiers fail safely and predictably.
- The whole corpus runs under the project's `verify.sh`-style harness (the same discipline the OS already uses), frozen alongside the format like the syscall ABI. Determinism — which the project already values (byte-identical self-host) — is what makes "golden" meaningful: lossy decode, grain synthesis, and metric computation are all bit-reproducible by spec-frozen fixed-point math, so no hollow decoder can pass (it must hit exact pixels and exact `ProvResult`s).

#### 13.21.4 Cross-references

- `hash_alg` (§13.3.3), the per-chunk CRC, and the whole-file integrity hash (§security) share **one** hash routine in the shared toolkit (DRY).
- The metric registry (§13.11) and its frozen XYB transform (§13.14) live in the shared `perceptual`/`color` toolkit, reused by `IAQ` (§13.16), the RDO seam (§13.19), and `QLYR` (§13.13).
- `IROI` (§13.17), `IAQ` (§13.16), and the RDO seam (§13.19) all feed the *coded* quantization in `IDAT`; the decoder reads only declared quant — none of the tuning policy leaks into decode.
- `ASRT_DISCLOSE` (§13.7.1) binds the `NEURAL` codec slot to provenance, so learned compression is never an undisclosed transform — the same honesty the rest of CSIF holds.
