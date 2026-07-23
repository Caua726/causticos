# CSIF — Veredito de design (o que faltava pra ser "fodão")

> Resposta executiva à pergunta: "isso é o melhor possível ou falta muita coisa?".
> Companheiro da especificação em `docs/CSIF_FORMAT.md`.

# Veredito executivo: o CSIF v1 é o melhor possível ou falta muita coisa?

## 1) Veredito honesto sobre o baseline v1

Cru e direto: **o v1 era um bom esqueleto, mas estava muito longe de "world-class". Faltava MUITO.** Ele tinha a espinha dorsal certa — container TLV estilo CSE (magic+versão+chunks), um registro de codecs com interface {decode,encode}, e a ideia DRY de um toolkit compartilhado. Isso já te colocava na *forma* arquitetural correta (mecanismo vs política, op-set fechado). Mas como *formato de imagem* competitivo, o v1 tinha buracos estruturais que não dava pra tapar depois sem redesenhar:

- **Era single-raster, single-image.** Um `IDAT` monolítico, sem índice. Sem isso → **zero** partial decode, ROI, seek de frame, ou skip de canal. Esse era o maior buraco isolado: tudo de avançado depende de um índice.
- **Cor era um campo `colorspace` vago** — exatamente o "magic colorspace" que a tua própria filosofia proíbe. Sem transfer function, sem primaries, sem matrix, sem range, sem float. HDR/wide-gamut eram literalmente *inexprimíveis*.
- **Sem sub-images** — e é daí que vem TODA a amplitude do JPEG XL (alpha, DC/LF, quant field, mapas de correlação, canais extra são todos sub-images Modular num motor só). Sem isso o formato reimplementaria codepaths por feature (anti-DRY) e perderia a unificação.
- **Sem integridade (CRC), sem limites declarados (ILIM), sem flags de criticidade por chunk.** O v1 era inseguro por construção — o oposto da postura "fail loud, bounded" do kernel.
- **MODULAR e DCT eram nomes, não especificações.** "predictors+rANS" e "DCT8x8" sem MA-tree, sem transform stack ordenada, sem VarDCT, sem quant adaptativo, sem contexto na entropia.

Então: a fundação estava certa, o prédio não estava construído.

## 2) O que faltava pra ser world-class — agora adicionado (agrupado)

Fechei o dossiê inteiro contra JPEG XL / AVIF / HEIF / JPEG 2000 / OpenEXR / PNG-APNG / WebP / KTX2-Basis / DNG-RAW / C2PA / JBIG2 / vetor. Os grandes blocos que entraram, todos redesenhados no jeito Caustic (tudo declarado, op-set fechado, mecanismo≠política):

- **Modelo de container de verdade (de HEIF):** tabela de **items**, **property store** com associações + bit "essential", **grafo de referências tipado** (thumbnail-of/aux-of/derived-from/describes), e **derived images** (grid/overlay/identity) como op-set fechado de receitas — gigapixel-como-grid, rotação/crop lossless via propriedade, ROI real. Tudo com invariantes de container validados (ranges ⊆ chunk, DAG acíclico, geometria reconciliada).
- **Índice + escalabilidade (de JXL/JP2/EXR):** **ITOC** (offset+length+kind+coords+dependency_mask por unidade) — a fundação de partial/ROI/streaming. **Progressivo/responsivo** declarado (DC-then-AC + Squeeze/pirâmide Laplaciana, PassTable). **Wavelet** (5/3 reversível + 9/7) no toolkit, **quality layers** truncáveis, **code-blocks/precincts**, **progression order** explícito (LRCP/RLCP/...), **mipmaps/ripmaps**, **ROI explícito** (Maxshift redesenhado pra ser declarado, não inferido).
- **Cor/HDR feito direito (de AVIF/EXR/color):** **CICP obrigatório** (primaries/transfer/matrix/range), **"Unspecified" BANIDO** (o reader nunca chuta), **ICC** com precedência declarada, **MDCV+MaxCLL/MaxFALL**, **HDR gain maps** (ISO 21496-1), **sample_format** incluindo **float16/float32**, **intensity_target em nits**, subsampling/siting de croma explícitos.
- **Os codecs especificados de verdade:** MODULAR ganhou **transform stack ordenada** (RCT family/palette/delta-palette/squeeze), **MA-tree serializada**, **preditor self-correcting**, **LZ77+rANS**, **color cache parametrizado** (QOI é o caso bits=6), **meta-entropy por região**, **near-lossless**. DCT ganhou **VarDCT** (blocos variáveis + partition map decodificado), **quant adaptativo** como sub-image, prediction-before-transform.
- **Entropia como substrato unificado (de AVIF/entropy):** **rANS interleaved (SIMD)** + **hybrid integer token** (carrega resíduos 16/32-bit num alfabeto pequeno) + **context modeling explícito** (context_map + árvore serializada) + modo **adaptive-CDF** + **prefix/Huffman** — tudo atrás de uma vtable {encode,decode} selecionada por `entropy_method_id`, com bit-exactness normativo e vetores de conformância.
- **Canais & profissional (de EXR):** **canais nomeados arbitrários** com role declarado (depth/normal/id/mask/spot), **deep images** (samples-por-pixel variável), **multipart**, data-window vs display-window, alpha com associação explícita.
- **Famílias inteiras que o v1 ignorava:** **animação** (frames como keys, timebase em ticks, blend/dispose fechados, reference slots bounded), **bilevel/JBIG2+G4** (documentos/fax — DCT é catastrófico nisso), **indexed/palette** com transparência por-índice, **texturas GPU** (BC1-7/ASTC/ETC2 + Basis transcodável + mips/array/cube + upload zero-copy), **RAW de câmera** (mosaico CFA + pipeline de develop declarado como op-set ordenado), **provenance C2PA** (manifest assinado, hard-binding por hash, disclosure de IA ligado ao codec NEURAL), e **vetor/ícones** (display list binária, op-set fechado, rasterização determinística — resolução-independente pra cursores HiDPI).
- **Segurança & conformância transversal:** **ILIM** (validação de dimensão em aritmética alargada antes de alocar — mata o bug classe WebP/BLASTPASS), **CRC por chunk**, **profiles/levels**, **corpus de golden vectors** (incluindo corpus de corrupção com código de erro exato), parsing offset-driven canônico, endianness única declarada.

## 3) Como fica vs JPEG XL / AVIF agora

Com o design fechado, o CSIF **iguala ou cobre a união** dos dois — e em alguns eixos vai além:

- **vs JPEG XL:** empata na amplitude que torna o JXL o "breadth king" — Modular+VarDCT sobre um toolkit compartilhado, sub-images, progressivo/responsivo, lossless+near-lossless+lossy num arquivo, canais extra, HDR float, animação, patches/splines/noise, recompressão lossless de JPEG (slot honesto com op `reconstruct_source`). O CSIF **supera** o JXL em duas coisas: o **modelo de container HEIF-class** (items/derived/aux/referências — o JXL não tem) e a **honestidade obrigatória de cor** (CICP mandatório, "Unspecified" proibido — o JXL permite).
- **vs AVIF:** alcança a eficiência (substrato de entropia multi-símbolo com contexto, VarDCT, quant adaptativo, in-loop filters CDEF/Wiener como pipeline declarado, film grain, aux planes independentes, tiling). E **supera** o AVIF em escalabilidade (quality+resolution layers estilo JP2, que o AV1-intra não faz), em container (não fica preso à herança ISOBMFF com offsets que danglam) e em pro/HDR (deep images + float32 estilo EXR, que o AVIF não tem).
- **Onde o CSIF é singular:** ninguém num único formato junta **fotográfico + documento (JBIG2) + textura GPU transcodável + RAW de captura + vetor + provenance assinado**. Essa é a aposta "uma família, um container = mecanismo, codecs = política" levada até o fim — e é arquiteturalmente verdadeira porque o container nunca embute codec.

## 4) O que fica como módulo futuro honesto (e por quê)

Dois slots ficam como **interface real, implementação sequenciada** — nunca decoder falso (regra #4):

- **BLOCK (id 4) — VarDCT/AV1-class.** O *design* está fechado (partition tree, ~62 modos intra, transform ADST/FLIPADST/IDTX, CDEF/loop-restoration, quant adaptativo). Fica como módulo porque é uma quantidade enorme de policy de codec madura; o slot é honesto porque expõe a mesma vtable {decode,encode} e reusa o toolkit compartilhado — quando chegar, entra sem mudar o container.
- **NEURAL (id 5) — compressão aprendida + runtime de inferência.** Precisa de um runtime de inferência determinístico (senão quebra bit-exactness e conformância). Fica como slot real, e já está **arquiteturalmente amarrado à provenance**: um codec NEURAL é uma transformação algorítmica dos pixels, então é *obrigado* a emitir uma assertion `digitalSourceType` assinada (disclosure de IA). Honesto por construção.

Além desses, ficam como **camadas opt-in skippable** já especificadas mas implementáveis incrementalmente: context-mixing (PAQ/cmix) como codec_id de ratio-máximo, watermark/fingerprint durável (soft binding), e animação vetorial (Lottie-class) como extension point nomeado — todos com a disciplina "frozen agora, versionado depois" do CSE.

**Resumo de uma linha pra você:** o v1 estava certo no esqueleto e pobre no conteúdo; agora o design está fechado num nível que cobre a união de JPEG XL + AVIF + HEIF + JP2 + EXR e ainda acrescenta documento/GPU/RAW/vetor/provenance — sem violar a filosofia em nenhum ponto, porque cada feature SOTA que era "mágica" (cor implícita, ROI inferido, orientação dupla, alpha adivinhado) foi reescrita pra ser declarada. Os únicos não-construídos são BLOCK e NEURAL, e são slots honestos, não buracos.
