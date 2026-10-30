"""
S1b: systolic array 단독 랜덤 검증을 여러 구성에서 실행한다.

구성마다 TB를 ROWS, COLS, K로 컴파일하고, seed마다 벡터를 새로 만들어 시뮬레이션한다.
하나라도 실패하면 실패한 구성의 시뮬레이션 출력을 보여주고 종료 코드 1로 끝난다.

저장소 최상위 폴더에서 실행:
  python scripts/run_array_tests.py
"""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
sys.path.insert(0, str(ROOT / "model"))

from gen_vectors import write_vectors  # noqa: E402

SHAPES = [(2, 2), (2, 3), (3, 2), (4, 4), (8, 8)]   # (ROWS, COLS)
K_VALUES = [1, 2, 29, 64]
SEEDS = [1, 2, 3]

SOURCES = ["tb/tb_array.v", "RTL/systolic_array.v", "RTL/PE.v"]
SIM = BUILD / "sim_tb_array"


def compile_tb(rows, cols, k):
    """ROWS, COLS, K를 지정해 TB를 컴파일하고 (성공 여부, 컴파일러 출력)을 돌려준다."""
    cmd = ["iverilog", "-g2005",
           f"-Ptb_array.ROWS={rows}",
           f"-Ptb_array.COLS={cols}",
           f"-Ptb_array.K={k}",
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
        for k in K_VALUES:
            compiled, compile_output = compile_tb(rows, cols, k)
            if not compiled:
                # 컴파일이 안 되면 이 구성의 seed는 모두 실패로 센다.
                total += len(SEEDS)
                label = f"{rows}x{cols} K={k:<2} compile"
                print("FAIL  " + label)
                failures.append((label, compile_output))
                continue

            for seed in SEEDS:
                write_vectors(rows, cols, k, seed, BUILD)
                passed, output = run_sim()
                total += 1

                label = f"{rows}x{cols} K={k:<2} seed={seed}"
                print(("PASS  " if passed else "FAIL  ") + label)
                if not passed:
                    failures.append((label, output))

    print(f"\n{total - len(failures)}/{total} passed")
    for label, output in failures:
        print(f"\n--- {label} ---\n{output.strip()}")

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
