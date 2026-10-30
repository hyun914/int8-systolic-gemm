"""
S2: GEMM 코어 시스템 검증을 여러 배열 구성에서 실행한다.

시뮬레이션 한 번에 워크로드 세 개를 연속 명령으로 실행하고,
끝난 뒤 메모리 전체를 기대값과 비교한다. seed가 짝수면 명령 순서를 뒤집는다.

저장소 최상위 폴더에서 실행:
  python scripts/run_core_tests.py
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
sys.path.insert(0, str(ROOT / "model"))

from gen_vectors import make_matrices  # noqa: E402

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
        for kk in range(k):
            for j in range(n):
                mem[base_b + kk * n + j] = B[kk][j] & 0xFF

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


def compile_tb(rows, cols):
    """ROWS, COLS를 지정해 TB를 컴파일하고 (성공 여부, 컴파일러 출력)을 돌려준다."""
    cmd = ["iverilog", "-g2005",
           f"-Ptb_gemm_core.ROWS={rows}",
           f"-Ptb_gemm_core.COLS={cols}",
           "-o", str(SIM)] + SOURCES
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    return result.returncode == 0, result.stdout + result.stderr


def run_sim():
    """시뮬레이션을 실행하고 (통과 여부, 출력)을 돌려준다."""
    result = subprocess.run(["vvp", "-n", str(SIM)], cwd=ROOT,
                            capture_output=True, text=True)
    output = result.stdout + result.stderr
    passed = "PASS:" in output and "FATAL" not in output and "FAIL" not in output
    return passed, output


def main():
    BUILD.mkdir(exist_ok=True)
    failures = []
    total = 0

    for rows, cols in SHAPES:
        compiled, compile_output = compile_tb(rows, cols)
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

            passed, output = run_sim()
            total += 1

            label = f"{rows}x{cols} seed={seed}"
            print(("PASS  " if passed else "FAIL  ") + label)
            for m, n, k, cyc in re.findall(r"M=(\d+) N=(\d+) K=(\d+) cycles=(\d+)", output):
                print(f"        (M,N,K)=({m},{n},{k})  cycles={cyc}")
            if not passed:
                failures.append((label, output))

    print(f"\n{total - len(failures)}/{total} passed")
    for label, output in failures:
        print(f"\n--- {label} ---\n{output.strip()}")

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
