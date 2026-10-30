"""
S1b 벡터 생성기

단일 타일 GEMM(M = ROWS, N = COLS)의 무작위 INT8 입력 A, B와 정답 C를 만들고,
Verilog $readmemh로 읽을 수 있는 hex 파일로 저장한다.

  a.hex : A (ROWS x K), row-major, 한 줄에 8비트 값 하나
  b.hex : B (K x COLS), row-major, 한 줄에 8비트 값 하나
  c.hex : C (ROWS x COLS), row-major, 한 줄에 32비트 값 하나

음수는 2의 보수로 저장한다. 예: -128 -> 80, -1 -> ff

사용 예 (저장소 최상위에서):
  python model/gen_vectors.py --rows 4 --cols 4 --k 29 --seed 1
"""

import argparse
import random
from pathlib import Path

from gemm_reference import gemm_reference


def to_hex(value, bits):
    """부호 있는 정수를 bits 폭의 2의 보수 hex 문자열로 바꾼다."""
    mask = (1 << bits) - 1
    return format(value & mask, f"0{bits // 4}x")


def random_matrix(rows, cols, rng):
    """[-128, 127] 범위의 무작위 정수 행렬을 만든다."""
    return [[rng.randint(-128, 127) for _ in range(cols)] for _ in range(rows)]


def write_hex(path, header, matrix, bits):
    """행렬을 row-major 순서로 한 줄에 하나씩 hex로 저장한다."""
    with open(path, "w") as f:
        f.write(f"// {header}\n")
        for row in matrix:
            for value in row:
                f.write(to_hex(value, bits) + "\n")


def write_vectors(rows, cols, k, seed, out_dir):
    """A, B, C를 만들어 out_dir에 a.hex, b.hex, c.hex로 저장하고 돌려준다."""
    rng = random.Random(seed)
    A = random_matrix(rows, k, rng)
    B = random_matrix(k, cols, rng)
    C = gemm_reference(A, B)

    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    write_hex(out / "a.hex", f"A {rows}x{k} row-major, seed={seed}", A, 8)
    write_hex(out / "b.hex", f"B {k}x{cols} row-major, seed={seed}", B, 8)
    write_hex(out / "c.hex", f"C {rows}x{cols} row-major, seed={seed}", C, 32)
    return A, B, C


def main():
    parser = argparse.ArgumentParser(description="단일 타일 GEMM 테스트 벡터 생성")
    parser.add_argument("--rows", type=int, required=True, help="배열 행 수 (= M)")
    parser.add_argument("--cols", type=int, required=True, help="배열 열 수 (= N)")
    parser.add_argument("--k", type=int, required=True, help="누산 길이 K")
    parser.add_argument("--seed", type=int, default=1, help="난수 seed")
    parser.add_argument("--out", default="build", help="출력 폴더")
    args = parser.parse_args()

    write_vectors(args.rows, args.cols, args.k, args.seed, args.out)
    print(f"wrote {args.out}/a.hex, b.hex, c.hex "
          f"(ROWS={args.rows} COLS={args.cols} K={args.k} seed={args.seed})")


if __name__ == "__main__":
    main()
