# INT8 Systolic GEMM Core

INT8 Output-Stationary Systolic Array 기반 GEMM 코어를 RTL로 설계하고, Python 성능 모델의 예측 사이클과 RTL 측정 사이클을 비교해 워크로드 shape와 메모리 bandwidth에 따른 성능 변화를 분석한다.

> **핵심 질문**: PE를 늘리면 어떤 조건에서 성능이 개선되고, 어떤 조건에서는 개선 폭이 작아지는가?

---

## 현재 상태 (2026-10-29)

| 항목 | 상태 |
|---|---|
| 개념 학습 (GEMM, layout/stride, systolic/skew, dataflow, banking, tiling, roofline, ready/valid) | 완료 |
| Python 기능 정답 모델 `model/gemm_reference.py` | 완료: 2×2 예제 통과 |
| 단일 PE `RTL/PE.v` + self-checking TB `tb/tb_PE.v` | 완료: 14개 케이스 PASS |
| S1: 파라미터화 배열 `RTL/systolic_array.v` | 작성 완료: 4×4, 2×3 구성 컴파일 통과 |
| S1: 2×2 배열 TB `tb/tb_array_2x2.v` | 작성 중 |
| S1b ~ S6 | 예정 |
| Python 성능 모델 (사이클 예측) | 미구현 |

## 디렉터리 구조

```
.
├── README.md
├── RTL/                     # 설계
│   ├── PE.v                 # Output Stationary PE
│   └── systolic_array.v     # ROWS×COLS 배열
├── tb/                      # 검증
│   ├── tb_PE.v              # PE self-checking TB
│   └── tb_array_2x2.v       # (S1 작성 중) 2×2 배열 TB
└── model/                   # Python 모델
    └── gemm_reference.py    # 기능 정답 모델 (계산 결과만, 사이클 예측 없음)
```

시뮬레이션 산출물(`sim_*`, `*.vcd`)은 저장소에 포함하지 않는다.

## 실행 방법

도구: Icarus Verilog 12, Python 3

저장소 최상위 폴더에서 실행한다.

```bash
# 기능 정답 모델
python model/gemm_reference.py

# PE 단위 테스트
iverilog -g2005 -o sim_pe tb/tb_PE.v RTL/PE.v
vvp sim_pe

# 배열 elaboration 확인 (기본 4×4, 비정방 2×3)
iverilog -g2005 -o chk RTL/systolic_array.v RTL/PE.v
iverilog -g2005 -Psystolic_array.ROWS=2 -Psystolic_array.COLS=3 -o chk RTL/systolic_array.v RTL/PE.v

# (S1 이후) 2×2 배열 테스트
iverilog -g2005 -o sim_array tb/tb_array_2x2.v RTL/systolic_array.v RTL/PE.v
vvp sim_array
```

`-g2005`: 배열 내부에서 다차원 wire 배열을 사용하므로 지정한다.

---

## 1. 범위

### 고정 사항

- **데이터 형식**: 입력 A/B는 signed INT8, 누산과 출력은 signed INT32
- **Dataflow**: Output Stationary 하나. A는 가로(왼쪽→오른쪽), B는 세로(위→아래)로 이동하고 각 PE가 C[i,j]를 누산기에 유지한다.
- **K 처리**: K 전체를 버퍼에 담는다 (K ≤ `K_MAX`). K 방향 분할은 하지 않는다.
- **실행 순서**: 타일마다 Load → Clear → Compute → Store를 순차 실행한다. 단계 간 중첩(double buffering)은 없다.
- **완료 조건**: 경계 타일도 배열 전체 크기 기준으로 고정 대기한다 (3.1절).
- **Padding**: 배열에 주입하지 않는다. 유효 범위 밖의 행, 열은 valid=0으로 두고, 외부 메모리에서도 유효 원소만 읽는다. 따라서 하드웨어가 센 MAC 수는 정확히 M×N×K여야 한다.
- **배열 크기**: `ROWS`/`COLS` 파라미터로 지정한다. 입력, 누산 비트폭은 고정이다.

### 구성별 범위

| 구성 | 평가 방식 | 용도 |
|---|---|---|
| 2×2 | RTL (배열 단독) | 연결, 타이밍 손 검증 |
| 2×3, 3×2 | RTL (배열 단독) | 행/열 인덱스 뒤바뀜 검출 (정방 배열에서는 드러나지 않음) |
| 4×4 | RTL (전체 코어) | 기준 구성 |
| 8×8 | RTL (전체 코어) | 모델 비교 |
| 16×16 | 조건부 | S4까지 안정되면 RTL, 아니면 모델 전용 |
| 32×32 이상 | 모델 전용 | DSE 추세 확인 |

### 제외

Double buffering, K 분할, AXI, 무작위 stall 정밀 비교 (결정적 stall 패턴만 사용), 합성 면적, 전력, SRAM macro 수치.

---

## 2. 설계 명세

### 2.1 연산

$$C_{M\times N} = A_{M\times K} \times B_{K\times N}, \qquad C[i,j] = \sum_{k=0}^{K-1} A[i,k]\,B[k,j]$$

`gemm_reference(A, B)`는 Python 정수로 계산하므로 INT8 자료형 overflow가 없다. 입력이 INT8 범위를 벗어나거나 누산값이 INT32 범위를 벗어나면 예외를 낸다.

### 2.2 PE (`RTL/PE.v`, TB: `tb/tb_PE.v`)

| 포트 | 방향 | 폭 | 설명 |
|---|---|---|---|
| `clk` | in | 1 | |
| `rst_n` | in | 1 | 동기식 active-low reset |
| `clear` | in | 1 | 동기식 active-high clear |
| `a_in`, `b_in` | in | 8 (signed) | 입력 데이터 |
| `a_valid_in`, `b_valid_in` | in | 1 | 입력 valid |
| `a_out`, `b_out` | out | 8 (signed) | 1사이클 지연 전달 데이터 |
| `a_valid_out`, `b_valid_out` | out | 1 | 1사이클 지연 전달 valid |
| `acc_out` | out | 32 (signed) | 누산값 |

- `!rst_n || clear`이면 누산값, 전달 데이터, 전달 valid를 모두 0으로 만든다. reset/clear는 MAC보다 우선한다.
- 정상 동작에서는 A/B와 각 valid를 1사이클 지연해 전달한다.
- `a_valid_in && b_valid_in`일 때만 현재 입력으로 MAC을 수행한다 (16비트 signed 곱 → 32비트 부호 확장 → 누산).
- 한쪽만 유효하면 데이터, valid 전달은 계속하고 누산값은 유지한다.
- PE 내부에는 ready/done 신호가 없다.

### 2.3 배열 (`RTL/systolic_array.v`, S1)

```verilog
module systolic_array #(parameter ROWS = 4, parameter COLS = 4) (...);
```

| 포트 | 방향 | 폭 | 비트 배치 |
|---|---|---|---|
| `clk`, `rst_n`, `clear` | in | 1 | 모든 PE에 같은 사이클에 broadcast |
| `a_in` | in | ROWS×8 | 행 r = `a_in[r*8 +: 8]` (왼쪽 경계) |
| `a_valid_in` | in | ROWS | 행 r = `a_valid_in[r]` |
| `b_in` | in | COLS×8 | 열 c = `b_in[c*8 +: 8]` (위쪽 경계) |
| `b_valid_in` | in | COLS | 열 c = `b_valid_in[c]` |
| `acc_out` | out | ROWS×COLS×32 | PE(r,c) = `acc_out[(r*COLS+c)*32 +: 32]` (row-major) |

- Verilog-2001은 배열 포트를 지원하지 않으므로 1차원으로 펼친다. row-major 배치는 Python `C[i][j]` 순서와 같다.
- 펼친 벡터는 unsigned이다. 부호 연산은 PE 내부에서 처리되며, TB에서 슬라이스를 비교하거나 출력할 때는 `$signed(...)`를 사용한다.
- 오른쪽, 아래쪽 끝 PE의 `a_out`/`b_out`은 외부로 내보내지 않는다.
- 모든 acc를 병렬로 내보내는 것은 S1의 단순화이다. 결과 저장 경로 폭(T_store 결정)은 S2/S3에서 정한다.

**내부 연결**

```
a_h[r][c] : PE(r,c)의 a 입력   (c = 0..COLS, [COLS]는 오른쪽 끝 출력)
b_v[r][c] : PE(r,c)의 b 입력   (r = 0..ROWS, [ROWS]는 아래쪽 끝 출력)

a_h[r][0] = a_in 행 r            b_v[0][c] = b_in 열 c
PE(r,c):  a_in ← a_h[r][c],  a_out → a_h[r][c+1]
          b_in ← b_v[r][c],  b_out → b_v[r+1][c]
          valid도 같은 규칙 (av_h, bv_v)
```

연결선 배열을 COLS+1, ROWS+1 크기로 잡아 모든 PE가 "입력 [c], 출력 [c+1]" 규칙을 따르게 한다. 마지막 열, 행의 예외 처리가 없어진다.

PE가 홉마다 1사이클 지연하므로:

```
PE(r,c).a_in(t) = 경계 a_r(t - c)
PE(r,c).b_in(t) = 경계 b_c(t - r)
```

### 2.4 Skew와 2×2 예제

**Skew 규칙**

- 경계 a_r(t) = A[r][t-r], 0 ≤ t-r < K일 때 valid
- 경계 b_c(t) = B[t-c][c], 0 ≤ t-c < K일 때 valid

이때 PE(r,c)는 사이클 t에 A[r][t-r-c]와 B[t-r-c][c]를 받는다. **A[r][k]와 B[k][c]는 PE(r,c)에서 t = k + r + c에 만난다.** 마지막 MAC은 t = K+R+C-3이므로 한 타일의 연산 시간은 **K+R+C-2 사이클**이다.

**예제**: A = [[1,2],[3,4]], B = [[5,6],[7,8]], K = 2 → C = [[19,22],[43,50]]

경계 입력 ("-"는 valid=0)

| t | a_0 | a_1 | b_0 | b_1 |
|---|---|---|---|---|
| 0 | 1 (A00) | - | 5 (B00) | - |
| 1 | 2 (A01) | 3 (A10) | 7 (B10) | 6 (B01) |
| 2 | - | 4 (A11) | - | 8 (B11) |
| 3 | - | - | - | - |

사이클 t에 각 PE가 수행하는 MAC

| t | PE00 | PE01 | PE10 | PE11 |
|---|---|---|---|---|
| 0 | 1×5 (k0) | - | - | - |
| 1 | 2×7 (k1) | 1×6 (k0) | 3×5 (k0) | - |
| 2 | - | 2×8 (k1) | 4×7 (k1) | 3×6 (k0) |
| 3 | - | - | - | 4×8 (k1) |

t의 posedge 직후 acc

| t | PE00 | PE01 | PE10 | PE11 |
|---|---|---|---|---|
| 0 | 5 | 0 | 0 | 0 |
| 1 | 19 | 6 | 15 | 0 |
| 2 | 19 | 22 | 43 | 18 |
| 3 | 19 | 22 | 43 | 50 |

**TB 타이밍 규칙**: negedge에서 경계 입력을 넣고 posedge 후 `#1`에 acc를 확인한다. reset 해제 후 처음 valid 입력이 샘플되는 posedge를 t=0으로 둔다.

**추가 테스트**

- **테스트 2**: 같은 행렬, valid=0 슬롯에 쓰레기 값(-77, 99, -128 등)을 넣는다 → 위 표와 동일해야 한다 (valid gating 확인).
- **테스트 3** (clear 후): A = [[-128,127],[-3,5]], B = [[-128,-1],[127,-2]] → C = [[32513,-126],[1019,-7]]
  - acc: t0 `[16384, 0; 0, 0]` → t1 `[32513, 128; 384, 0]` → t2 `[32513, -126; 1019, 3]` → t3 `[32513, -126; 1019, -7]`
  - (-128)(-1) = 128은 unsigned 곱셈이면 32640이 되므로 signed 곱셈을 검증한다. 127×(-2), 5×(-2)는 음수 곱이라 부호 확장을 검증한다.

---

## 3. 성능 모델 정의

### 3.1 완료 조건

타일마다 배열 전체 크기 기준으로 고정 대기한다. 경계 타일도 같다.

```
COMPUTE 상태 길이 = K + R + C - 2 + L_feed
```

`L_feed`는 버퍼 읽기, feeder 파이프라인 지연이다. S2에서 RTL 구조가 정해지면 값을 확정하고 Python 모델에 같은 값을 사용한다. 유효 행, 열까지만 기다리는 조기 종료(K + r_valid + c_valid - 2)는 S5의 비교 옵션이다.

### 3.2 사이클 모델

항목 하나가 RTL 카운터 하나에 대응한다.

```
T_total = T_cmd + Σ_tiles [ T_load(tile) + T_clear + T_compute + T_store(tile) ] + T_done
```

- 순차 구조이므로 `max(Load, Compute, Store)`를 쓰지 않는다.
- 항목별로 예측해서 불일치가 생긴 단계를 바로 찾는다.
- `T_load`의 정확한 식은 S3에서 외부 전송 프로토콜을 정할 때 확정한다. B가 row-major이면 B 타일은 C 바이트 조각 K개로 나뉘어 조각마다 ⌈ ⌉가 붙는다 (layout이 load 사이클에 미치는 영향).

### 3.3 지표

| 지표 | 정의 |
|---|---|
| 유효 MAC | M×N×K (padding 제외). RTL `mac_valid` 카운터로 측정해 일치를 확인한다. |
| 연산 구간 이용률 | 유효 MAC / (R×C×ΣT_compute) |
| 명령 전체 처리율 | 유효 MAC / T_total [MAC/cycle], 정규화 값은 R×C로 나눈다. |
| 외부 전송량 | 외부 메모리 인터페이스를 실제로 통과한 바이트 수 (`bytes_rd`, `bytes_wr`) |
| 모델 오차 | 카운터별 Python 예측 사이클 - RTL 측정 사이클 |

### 3.4 Bandwidth: 배열 경계 공급과 외부 전송의 구분

**배열 경계 공급 (온칩 버퍼 → 배열, COMPUTE 상태 동안)**

충분히 채워진 R×C 배열, INT8 입력, PE당 1 MAC/cycle 기준:

| 배열 | 최대 처리율 (MAC/cycle) | 경계 입력 공급 (B/cycle) | AI_edge (MAC/B) |
|---|---|---|---|
| 4×4 | 16 | 8 | 2 |
| 8×8 | 64 | 16 | 4 |
| 16×16 | 256 | 32 | 8 |

배열이 커지면 절대 입력 공급량 R+C는 **증가**하고, MAC당 입력 공급량 (R+C)/(R×C)는 **감소**한다.

**외부 메모리 전송 (LOAD/STORE 상태 동안, W B/cycle)**

총량은 버퍼 재사용 정책이 결정한다. 입력만, padding 미전송, Tm = ⌈M/R⌉, Tn = ⌈N/C⌉:

| 정책 | A 바이트 | B 바이트 |
|---|---|---|
| P0: 타일마다 A, B를 새로 로드 | M×K×Tn | K×N×Tm |
| P1: 같은 타일 행 동안 A 유지 (i 바깥, j 안쪽 루프) | M×K | K×N×Tm |

출력은 두 정책 모두 4×M×N 바이트이다 (K 분할이 없으므로 한 번만 저장). P0에서는 외부 입력 전송 총량이 배열 경계 공급 총량과 같고, 두 값은 버퍼 재사용(P1)부터 갈라진다.

입력 전송량 (P0 / P1, **공식 계산값, RTL 미검증**):

| 워크로드 (M,N,K) | 4×4 | 8×8 | 16×16 |
|---|---|---|---|
| (32,64,64) | 65,536 / 34,816 | 32,768 / 18,432 | 16,384 / 10,240 |
| (1,64,64) | 5,120 / 4,160 | 4,608 / 4,160 | 4,352 / 4,160 |

(1,64,64)는 B 4,096 B가 대부분이고 M=1이라 재사용할 데이터가 없어서, 배열 크기, 정책과 관계없이 전송량이 거의 일정하다. 외부 W가 병목이면 PE를 늘려도 개선 폭이 작아지는 원인 후보이며, S4/S5에서 수치로 확인한다.

### 3.5 실험 기록 항목

각 실행마다 다음을 기록한다.

R, C / A, B bank 수와 폭 / 경계 공급 능력 (B/cycle) / 외부 W / 외부 지연 L / stall 패턴 / 재사용 정책 / 완료 조건 / 출처 (모델 또는 RTL)

- 기본 배열 크기 sweep은 bank 수가 R, C를 따라 증가하므로 **"PE 수와 경계 공급 능력을 함께 늘리고 외부 W는 고정한 실험"**으로 표기한다.
- 경계 공급을 고정하고 배열만 키우는 실험은 feeder stall이 필요하므로 모델 전용으로 둔다.

---

## 4. 워크로드

| (M,N,K) | 목적 |
|---|---|
| (32, 64, 64) | 여러 입력을 함께 처리하는 형태 (prefill형 shape) |
| (1, 64, 64) | 입력 한 개를 처리하는 형태 (decode형 shape) |
| (7, 13, 29) | 배열 크기에 맞지 않는 경계 타일 검증 |

첫 두 워크로드는 LLM 선형 계층의 prefill/decode shape 차이를 단순화한 합성 GEMM이다. Attention, KV cache, Softmax 등을 포함하지 않으므로 전체 LLM 실행 성능을 평가한 것이 아니다.

---

## 5. 단계별 계획과 완료 기준

| 단계 | 내용 | 예상 기간 |
|---|---|---|
| S1 | 파라미터화 배열 + 2×2 검증 (TB가 skew 직접 공급) | 0.5일 |
| S1b | 배열 단독 랜덤 검증 (TB가 skew 자동 생성) | 0.5일 |
| S2 | 4×4 기준 코어: 버퍼, skew feeder, 타일 제어기, 결과 저장 | 1.5일 |
| S3 | 외부 메모리 모델 (ready/valid) + 계측 카운터 | 1일 |
| S4 | Python 성능 모델 + 4×4/8×8 RTL 비교 | 1일 |
| S5 | 16×16 RTL (조건부) + DSE | 1일 |
| S6 | 명세, 결과 문서, 재현 스크립트 | 0.5일 |

**범위 축소 규칙**

- 4일차 끝까지 S2가 끝나지 않으면 16×16과 P1 정책은 모델 전용으로 평가한다.
- S4에서 모델-RTL 불일치가 반나절 넘게 해결되지 않으면 원인 분석을 결과로 기록한다.

### S1: 파라미터화 배열 + 2×2

산출물: `RTL/systolic_array.v`, `tb/tb_array_2x2.v`

- [ ] t0~t3 매 사이클 acc 4개가 2.4절 표와 일치
- [ ] 입력 종료 후 acc 유지
- [ ] clear 1사이클 후 acc 전부 0, 다른 행렬(-128/127 포함)로 재실행 시 이전 값이 섞이지 않음
- [ ] valid=0 슬롯의 쓰레기 값이 결과에 영향 없음
- [x] 2×3 구성 elaboration 통과
- [ ] `tb_PE` 회귀 PASS

### S1b: 배열 단독 랜덤 검증

산출물: Python 벡터 생성기 (A/B/C hex 출력), 파라미터화 `tb_array.v`

- [ ] 2×2, 2×3, 3×2, 4×4, 8×8 단일 타일 (M=R, N=C), K ∈ {1, 2, 29, 64}, 고정 seed 여러 개
- [ ] t = K+R+C-3 posedge 직후 전체 일치, 직전 사이클에 PE(R-1,C-1)은 마지막 곱 하나가 빠진 값

### S2: 4×4 기준 코어

산출물: A 버퍼 (R bank), B 버퍼 (C bank), skew feeder, 타일 FSM, 결과 버퍼

- [ ] 4×4에서 세 워크로드 결과 전체 일치
- [ ] shape이 다른 연속 두 명령의 결과가 독립
- [ ] (7,13,29) 경계 타일에서 padding 위치 PE의 acc = 0

이 단계의 TB는 단순 포트로 버퍼를 직접 채운다. 외부 프로토콜은 S3에서 추가한다.

### S3: 외부 메모리 모델 + 계측 카운터

산출물: 외부 메모리 모델 (beat 폭 W, 고정 지연 L, 결정적 stall 패턴), 카운터 `cyc_total/load/compute/store/ctrl`, `bytes_rd/wr`, `mac_valid`

- [ ] `cyc_load + cyc_compute + cyc_store + cyc_ctrl == cyc_total`
- [ ] `mac_valid == M×N×K`, `bytes_rd`/`bytes_wr`가 3.4절 공식과 일치
- [ ] ready=0 동안 valid, data 유지 (TB assertion), 전송은 valid && ready에서만 성립
- [ ] done은 마지막 store 전송 이후에만 올라감

### S4: Python 성능 모델 + RTL 비교

산출물: `perf_model.py` (카운터별 사이클 예측), RTL 로그 비교 스크립트

- [ ] stall 없는 조건 (워크로드 3 × 배열 4×4/8×8 × W 4/8/16)에서 모든 카운터 오차 0
- [ ] 불일치가 생기면 해당 카운터, 원인, 수정 내역 기록

### S5: 16×16 RTL + DSE

- [ ] 16×16은 S1b, S2, S3 테스트 세트를 그대로 통과한 경우에만 "RTL 검증 구성"에 포함
- [ ] DSE 표와 그래프 2~3개, 각 행에 고정/변경 자원과 출처 (모델/RTL) 표기

### S6: 문서, 재현

- [ ] 명세: 데이터 형식, 메모리 layout, stride, 포트, 명령, 상태별 사이클, 완료 조건
- [ ] 결과와 한계 정리
- [ ] 명령 하나로 RTL 회귀 + 모델 + 표 생성

---

## 6. 결과 표기 원칙

- Python 모델 예측값과 RTL 측정값을 구분해서 표기한다.
- 각 실험에서 고정한 자원과 변경한 자원을 함께 기록한다.
- 파라미터화는 구성별 검증을 대신하지 않는다. RTL 검증 구성은 해당 구성에서 계산 결과, skew, 완료 사이클, 초기화, 경계 처리를 확인한 것만 포함한다.
- 전력 분석, 실제 SRAM macro, 물리 구현을 수행하지 않았으므로 해당 PPA 수치를 주장하지 않는다. behavioral 버퍼를 합성했다면 그 면적은 SRAM macro 기반 면적으로 해석하지 않는다.
- 외부 인터페이스는 단순 ready/valid이며 AMBA AXI 구현이 아니다.
- 이 프로젝트는 Output-Stationary systolic GEMM 코어이며 TPU 전체 구조를 재현한 것이 아니다.
