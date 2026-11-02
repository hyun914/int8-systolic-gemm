"""
GEMM 코어 시스템 검증을 여러 배열 구성에서 실행한다.

시뮬레이션 한 번에 워크로드 세 개를 연속 명령으로 실행하고,
끝난 뒤 메모리 전체를 기대값과 비교한다 (판정은 TB). seed가 짝수면 명령 순서를 뒤집는다.
명령마다 측정 사이클이 사이클 모델(model/perf_model.py) + stall 사이클과 정확히 같은지도 확인한다.

저장소 최상위 폴더에서 실행:
  python scripts/run_core_tests.py                                # L = 1, W = 1바이트, stall 없음
  python scripts/run_core_tests.py --lat 3 --width 8 --stall 25   # L = 3, W = 8, ready = 0 확률 25%
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
sys.path.insert(0, str(ROOT / "model"))

from gen_vectors import make_matrices  # noqa: E402
from perf_model import predict_cycles  # noqa: E402

SHAPES = [(4, 4), (2, 3), (8, 8)]                     # (ROWS, COLS)
WORKLOADS = [(32, 64, 64), (1, 64, 64), (7, 13, 29)]  # (M, N, K)
SEEDS = [1, 2]

MEM_BYTES = 1 << 16
K_MAX = 64
ALIGN = 16

SOURCES = [
    "tb/tb_gemm_core.v",
    "RTL/gemm_core.v",
    "RTL/load_seq.v",
    "RTL/bank_buffer.v",
    "RTL/edge_feeder.v",
    "RTL/systolic_array.v",
    "RTL/PE.v",
]
SIM = BUILD / "sim_tb_gemm_core"


def align_up(addr):
    return (addr + ALIGN - 1) // ALIGN * ALIGN


def build_images(workloads, seed):
    """명령 목록에 맞춰 시작 메모리, 기대 메모리, 명령 테이블을 만든다."""
    mem = [0] * MEM_BYTES
    results = []          # (base_c, C)
    cmds = []
    addr = 0

    for idx, (m, n, k) in enumerate(workloads):
        if k > K_MAX:
            raise ValueError(f"K={k}가 K_MAX={K_MAX}보다 크다")
        A, B, C = make_matrices(m, n, k, seed * 100 + idx)

        base_a = align_up(addr)
        base_b = align_up(base_a + m * k)
        base_c = align_up(base_b + k * n)
        addr = base_c + m * n * 4
        if addr > MEM_BYTES:
            raise ValueError("명령 목록이 메모리 크기를 넘는다")

        for i in range(m):
            for kk in range(k):
                mem[base_a + i * k + kk] = A[i][kk] & 0xFF
        # B는 전치(N x K)로 저장한다: 열 j의 K개 원소가 이어진다
        for j in range(n):
            for kk in range(k):
                mem[base_b + j * k + kk] = B[kk][j] & 0xFF

        results.append((base_c, n, C))
        cmds.append((m, n, k, base_a, base_b, base_c))

    # 기대 메모리 = 시작 메모리 + C 영역 (INT32, little-endian)
    expect = list(mem)
    for base_c, n, C in results:
        for i, row in enumerate(C):
            for j, value in enumerate(row):
                word = value & 0xFFFFFFFF
                a = base_c + (i * n + j) * 4
                for byte in range(4):
                    expect[a + byte] = (word >> (8 * byte)) & 0xFF

    return mem, expect, cmds


def write_bytes(path, data):
    with open(path, "w") as f:
        f.write("\n".join(f"{b:02x}" for b in data) + "\n")


def write_cmds(path, cmds):
    with open(path, "w") as f:
        f.write(f"{len(cmds):04x}\n")
        for cmd in cmds:
            for value in cmd:
                f.write(f"{value:04x}\n")


def compile_tb(rows, cols, lat, width, stall):
    """ROWS, COLS와 메모리 조건을 지정해 TB를 컴파일하고 (성공 여부, 컴파일러 출력)을 돌려준다."""
    cmd = ["iverilog", "-g2005",
           f"-Ptb_gemm_core.ROWS={rows}",
           f"-Ptb_gemm_core.COLS={cols}",
           f"-Ptb_gemm_core.RD_LAT={lat}",
           f"-Ptb_gemm_core.RD_BYTES={width}",
           f"-Ptb_gemm_core.STALL_PCT={stall}",
           "-o", str(SIM)] + SOURCES
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    return result.returncode == 0, result.stdout + result.stderr


def run_sim(seed):
    """시뮬레이션을 실행하고 (통과 여부, 출력)을 돌려준다. seed는 stall 패턴을 정한다."""
    result = subprocess.run(["vvp", "-n", str(SIM), f"+stall_seed={seed}"], cwd=ROOT,
                            capture_output=True, text=True)
    output = result.stdout + result.stderr
    passed = "PASS:" in output and "FATAL" not in output and "FAIL" not in output
    return passed, output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lat", type=int, default=1,
                        help="TB 메모리 읽기 지연 L (사이클, 1 이상)")
    parser.add_argument("--width", type=int, default=1,
                        help="TB 메모리 읽기 beat 하나의 바이트 수 W (1 이상)")
    parser.add_argument("--stall", type=int, default=0,
                        help="사이클마다 메모리 ready를 0으로 내릴 확률 (%%, 0 .. 99)")
    args = parser.parse_args()
    if not 0 <= args.stall <= 99:
        parser.error("--stall은 0 이상 99 이하여야 한다")
    if args.lat < 1:
        parser.error("--lat은 1 이상이어야 한다")
    if args.width < 1:
        parser.error("--width는 1 이상이어야 한다")

    BUILD.mkdir(exist_ok=True)
    failures = []
    total = 0
    print(f"메모리 읽기 지연 L = {args.lat}, beat 폭 W = {args.width}바이트, ready = 0 확률 {args.stall}%")

    for rows, cols in SHAPES:
        compiled, compile_output = compile_tb(rows, cols, args.lat, args.width, args.stall)
        if not compiled:
            total += len(SEEDS)
            label = f"{rows}x{cols} compile"
            print("FAIL  " + label)
            failures.append((label, compile_output))
            continue

        for seed in SEEDS:
            order = WORKLOADS if seed % 2 == 1 else list(reversed(WORKLOADS))
            mem, expect, cmds = build_images(order, seed)
            write_bytes(BUILD / "mem_init.hex", mem)
            write_bytes(BUILD / "mem_expect.hex", expect)
            write_cmds(BUILD / "cmds.hex", cmds)

            passed, output = run_sim(seed)
            total += 1

            # 사이클 확인: 측정값 = 모델 예측 + stall 때문에 미뤄진 사이클
            notes = []
            found = re.findall(r"M=(\d+) N=(\d+) K=(\d+) cycles=(\d+) rd_stall=(\d+) wr_stall=(\d+)", output)
            if passed and len(found) != len(cmds):
                passed = False
                notes.append("명령별 사이클 출력이 명령 수와 다르다")
            for m, n, k, cyc, rd_st, wr_st in found:
                m, n, k, cyc, rd_st, wr_st = map(int, (m, n, k, cyc, rd_st, wr_st))
                model = predict_cycles(m, n, k, rows, cols, args.width, args.lat)
                ok = cyc == model + rd_st + wr_st
                notes.append(f"        (M,N,K)=({m},{n},{k})  cycles={cyc}  model={model}"
                             f"  rd_stall={rd_st}  wr_stall={wr_st}" + ("" if ok else "  MISMATCH"))
                if not ok:
                    passed = False

            label = f"{rows}x{cols} seed={seed}"
            print(("PASS  " if passed else "FAIL  ") + label)
            for note in notes:
                print(note)
            if not passed:
                failures.append((label, output))

    print(f"\n{total - len(failures)}/{total} passed")
    for label, output in failures:
        print(f"\n--- {label} ---\n{output.strip()}")

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
