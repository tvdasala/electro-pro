# Especificação Técnica do Formato Nord Piano Library (`.npno`)

Este documento descreve a estrutura binária e o algoritmo de decodificação de áudio dos arquivos `.npno` (Nord Piano Library), levantados por inspeção estática e validados contra o banco `Astoria Grand XL 6.1.npno`.

---

## 1. Visão Geral do Arquivo

Um arquivo `.npno` é composto por quatro regiões contíguas:

1. **Container Externo (`CBIN`)**:
   * Versão `0` (legado): cabeçalho de `24 bytes` (`0x18`) + trailer de `2 bytes` (`CRC16-CCITT`, polinômio `0x1021`, semente `0xFFFF`).
   * Versão `1` (moderno, usado em `Astoria Grand XL 6.1.npno`): cabeçalho de `44 bytes` (`0x2C`), contendo o `CRC32` IEEE 802.3 (`0xEDB88320`, semente `0xFFFFFFFF`) calculado sobre todo o payload a partir de `0x2C` até o fim do arquivo.
2. **Cabeçalho de Metadados (`CNSP`)**:
   * Tamanho fixo de **`1.842 bytes` (`0x732`)**, iniciando imediatamente após o cabeçalho `CBIN` (`0x2C` na v1).
3. **Tabela de Registros de Amostras (`Record[total_records]`)**:
   * Inicia em `cb_hdr_len + 0x732` (`0x075E` na v1).
   * Cada registro possui tamanho fixo de **`118 bytes` (`0x76`)**, com campos multibyte em **Big-Endian**.
4. **Blocos de Áudio Comprimidos (LPC de ordem `0..4`)**:
   * Iniciam após a tabela de registros (`audio_base = cb_hdr_len + 0x732 + total_records * 0x76`, alinhado conforme `rel_byte_offset` de cada registro).
   * Cada bloco comprimido tem tamanho fixo de **`1.022 × channels` bytes** (`1.022 B` em mono, `2.044 B` em estéreo).

---

## 2. Layout Detalhado dos Cabeçalhos

### 2.1 Cabeçalho `CBIN` (`0x00..0x2B` na v1)

| Offset | Tamanho | Tipo | Descrição |
| :--- | :--- | :--- | :--- |
| `0x00..0x03` | 4 B | `char[4]` | Magic `"CBIN"` |
| `0x04..0x07` | 4 B | `uint32_t LE` | `container_version` (`0` ou `1`) |
| `0x08..0x0B` | 4 B | `char[4]` | Identificador do formato: `"npno"` |
| `0x14..0x17` | 4 B | `uint32_t LE` | `file_version` (ex.: `610` = v6.10) |
| `0x18..0x1B` | 4 B | `uint32_t LE` | `expected_crc32` (apenas quando `container_version == 1`) |

### 2.2 Cabeçalho `CNSP` (`0x732` bytes a partir de `cb_hdr_len`)

| Offset (`CNSP+`) | Tamanho | Tipo | Descrição |
| :--- | :--- | :--- | :--- |
| `+0x00..0x03` | 4 B | `char[4]` | Magic `"CNSP"` |
| `+0x04` | 1 B | `uint8_t` | Versão do cabeçalho `CNSP` (deve ser `4`) |
| `+0x1C..0x3B` | 32 B | `char[32]` | Nome combinado (`"Nome#Modelo   Tamanho"`) |
| `+0x3C..0x5B` | 32 B | `char[32]` | Nome principal do instrumento |
| `+0x5C..0x7B` | 32 B | `char[32]` | Modelo / subtítulo |
| `+0x8C..0x10B` | 128 B | `uint8_t[128]` | `keymap[128]`: nota MIDI `0..127` $\to$ `root_key` (`0xFF` = sem amostra) |
| `+0x10C..0x18B` | 128 B | `int8_t[128]` | `note_trim[128]`: ajuste de ganho por nota em décimos de dB ($10^{\text{trim}/200}$) |
| `+0x18C..0x20B` | 128 B | `int8_t[128]` | `note_cents[128]`: ajuste fino de afinação por nota em cents |
| `+0x30C..0x38B` | 128 B | `uint8_t[128]` | `damper_flags[128]`: flags auxiliares de abafador por nota |
| `+0x40C` | 1 B | `int8_t` | `global_trim`: ajuste global de ganho em décimos de dB |
| `+0x40D` | 1 B | `uint8_t` | `damper_boundary`: primeira nota MIDI sem abafador (válido se $\in [21, 109]$) |
| `+0x61E..0x61F` | 2 B | `uint16_t BE` | `channels`: `1` (mono) ou `2` (estéreo) |
| `+0x620..0x621` | 2 B | `uint16_t BE` | `total_records`: número total de registros na tabela de amostras |
| `+0x622..0x721` | 256 B | `uint16_t BE[128]` | `per_key_count[128]`: quantidade de registros por `root_key` (`0..127`) |

---

## 3. Registro de Amostra (`0x76` = 118 bytes, Big-Endian)

| Offset | Tamanho | Tipo | Descrição |
| :--- | :--- | :--- | :--- |
| `+0x00..0x03` | 4 B | `uint32_t BE` | `rel_byte_offset`: offset relativo ao fim do cabeçalho `CBIN` (`abs = cb_hdr_len + rel`) |
| `+0x04` | 1 B | `uint8_t` | `kind`: `0x00` = amostra normal (*key-on*); `0x02` = amostra de soltura (*key-release*) |
| `+0x05` | 1 B | `uint8_t` | `vel_param`: parâmetro de camada de velocidade (`0` = camada mais forte *ff*, crescente até *pp*) |
| `+0x06..0x09` | 4 B | `uint32_t BE` | `decoded_frames`: total de frames PCM16 decodificados |
| `+0x0A..0x0B` | 2 B | `uint16_t BE` | `block_count`: quantidade de blocos de `1022 × channels` bytes |
| `+0x0C..0x13` | 8 B | `int16_t BE[4]` | `init_hist_L[4]`: estado inicial `hist[0][0..3]` ($y[-4 \dots -1]$) do preditor LPC para o canal 0 (esquerdo) |
| `+0x14..0x1B` | 8 B | `int16_t BE[4]` | `init_hist_R[4]`: estado inicial `hist[1][0..3]` ($y[-4 \dots -1]$) do preditor LPC para o canal 1 (direito) |
| `+0x1C..0x1F` | 4 B | `uint32_t BE` | `loop_start`: frame de início do loop |
| `+0x20..0x23` | 4 B | `uint32_t BE` | `loop_length`: tamanho do loop em frames (`0` = sem loop) |
| `+0x2E..0x31` | 4 B | `uint32_t BE` | `loop_decay_raw`: fator `UQ9.23` ($\in [1, 2^{23}]$) convertido em dB/s |
| `+0x32..0x33` | 2 B | `int16_t BE` | `gain_ref`: referência diferencial de ganho (usada na v0) |
| `+0x34..0x35` | 2 B | `int16_t BE` | `attenuation`: atenuação em décimos de dB ($\text{gain} = 10^{-\text{att}/200} \times \frac{1,5}{32768}$) |
| `+0x3A..0x3D` | 4 B | `uint32_t BE` | `env_decay_raw`: segundo fator `UQ9.23` de decaimento |
| `+0x72` | 1 B | `uint8_t` | `release_param`: tempo de abafamento ($\text{clamp}(2 \cdot 2^{x/6}, 10, 4000)\text{ ms}$) |
| `+0x74` | 1 B | `uint8_t` | `layer_min`: limite explícito de camada (`0` = calculado por ponto médio) |

---

## 4. Decodificação de Blocos LPC e Sobreposição de 64 Frames

1. **Taxa de amostragem nativa**: `34.990 Hz`.
2. **Cabeçalho do bloco (`2 bytes`)**:
   * `hdr = block[1]`
   * `bit_width = hdr & 0x1F` (`1..16`)
   * `order = (hdr >> 5) & 0x07` (`0..4`)
   * $\text{raw\_frames} = \lfloor \lfloor (\text{block\_bytes} \times 8 - 16) / \text{bit\_width} \rfloor / \text{channels} \rfloor$
   * $\text{playable\_frames} = \text{raw\_frames} - 64$
3. **Leitura do Bitstream**:
   * Palavras `uint16_t BE` a partir de `block + 2` são empilhadas **LSB-first** em um acumulador de 64 bits.
   * Cada resíduo de `bit_width` bits sofre extensão de sinal para inteiro com sinal.
4. **Preditor LPC Binomial**:
   * Ordem 0: $0$
   * Ordem 1: $y[n-1]$
   * Ordem 2: $2y[n-1] - y[n-2]$
   * Ordem 3: $3y[n-1] - 3y[n-2] + y[n-3]$
   * Ordem 4: $4y[n-1] - 6y[n-2] + 4y[n-3] - y[n-4]$
5. **Sobreposição entre blocos**:
   * Ao atingir o frame `raw_frames - 64`, o estado `hist[c][0..3]` é salvo.
   * Os 64 frames finais do bloco $b$ coincidem exatamente com os 64 primeiros frames decodificados no bloco $b+1$ após restaurar `hist`.

---

## 9. Formato Nord Sample Library 4 (`.nsmp4` — Container `CBIN` / `nsmp` / `NSMP`)

Os arquivos `.nsmp4` compartilham o mesmo container externo `CBIN` v1 (44 bytes, CRC-32 IEEE sobre `data[0x2C..EOF]`) com assinatura `nsmp` em `+0x08` e versão (ex.: `410` = v4.10) em `+0x14`.

### 9.1 Cabeçalho Interno `NSMP` e Chunks (`0x2C..EOF`)
* `0x2C..0x3B` (16 bytes): `"NSMP\x00\x00\x00\x28\x00\x00\x00\x04\x00\x02\x00\x05"`.
* `0x3C..EOF`: Sequência de chunks Big-Endian (`char tag[4]`, `u32 version`, `u32 size`, seguido de `size` bytes):
  * `\0hdr` (`size = 0x70`): Nome do instrumento em `+0x0A` (64 bytes) e submodelo/autor em `+0x4A` (16 bytes).
  * `\0cat` (`size = 0x08`): Metadados de categoria.
  * `\0map` (tamanho variável): Em `payload + 1286`, `u16 count = be16(+0x1E)` zonas de 16 bytes a partir de `+0x20`:
    * `+0x00`: `u8 rootKey`, `+0x01`: `u8 keyHigh`, `+0x02`: `u8 keyLow`, `+0x08`: `u32 sampleId`, `+0x0D`: `u8 velLow`, `+0x0F`: `u8 velHigh`.
  * `\0stk` (`version = 11`): Um chunk por amostra de áudio (`34990 Hz`), com cabeçalho de `0x44` bytes:
    * `+0x00`: `u32 sampleId`, `+0x04`: `u8 kind`, `+0x05`: `u8 rootKey`, `+0x07`: `u8 velParam`, `+0x08`: `u8 channels` (`1` ou `2`).
    * `+0x09..+0x0B`: `u24 envDecayRaw`, `+0x0C`: `u8 releaseParam`, `+0x0D`: `i16 attenuation`, `+0x0F`: `u8 gainRef`.
    * `+0x13`: `u32(be32 >> 8) wOff` (offset inicial em palavras de 32 bits desde `0x2C`).
    * `+0x1C`: `u32(be32 >> 8) lStart` (fim do ataque em palavras de 32 bits).
    * `+0x25`: `u32(be32 >> 8) lEnd` (início do loop em palavras de 32 bits; se `lEnd < eWord`, faz loop entre `lEnd` e `eWord`).
    * `+0x2E`: `u32(be32 >> 8) eWord` (fim dos pacotes da amostra; palavra `0x00800020` mono ou `0x00800040` estéreo).
    * `+0x36`: `f32 fineTuneCents`, `+0x3B`: `f32 linearGain`.

### 9.2 Stream de Pacotes LPC de 14 bits (`wOff .. eWord`)
Cada pacote em `0x2C + cur * 4` inicia com `u32 w = be32(...)`:
* `flag80 = (w >> 23) & 1`, `rawBits = (w >> 19) & 0x0F`, `order = (w >> 14) & 7`, `n = w & 0x3FFF`, `frames = n / channels`.
* Se `flag80 == 1 && rawBits == 0`: `frames` frames com resíduo zero (`step = 1` palavra).
* Caso contrário: `width = rawBits + 1`, `wordsPerCh = (frames * width + 31) / 32`, `step = 1 + channels * wordsPerCh`.
* As palavras de 32 bits dos canais são intercaladas (`canal c` usa `pktWords[wIdx * channels + c]`), lidas MSB-first em complemento de dois de `width` bits, somadas ao preditor polinomial LPC de ordem `0..4` e escaladas por `<< 2` para PCM16 (`[-32768, +32767]`).
