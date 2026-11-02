"""
GEMM 코어 사이클 모델 (README 3.2절 식).

메모리 stall이 없으면 RTL 코어가 busy인 사이클 수(SETUP부터 DONE까지)를 정확히 예측한다.
메모리가 ready = 0으로 전송을 미룬 사이클은 하나에 1사이클씩 더해진다 (README 7.6절).

  R, C : 배열 행 수, 열 수
  W    : 메모리 읽기 beat 하나의 바이트 수
  L    : 메모리 읽기 지연 (사이클)
"""

from math import ceil


def tile_cycles(rv, cv, k, rows, cols, width=1, lat=1):
    """유효 행 rv, 유효 열 cv인 타일 하나의 상태별 사이클."""
    return {
        "setup": 1,
        "load": (rv + cv) * ceil(k / width) + lat + 1,
        "compute": k + rows + cols - 1,
        "store": rv * cv,
    }


def state_cycles(m, n, k, rows, cols, width=1, lat=1):
    """명령 하나의 상태별 사이클 합. 타일 순서는 i 바깥, j 안쪽 (RTL과 같다)."""
    total = {"setup": 0, "load": 0, "compute": 0, "store": 0, "done": 1}
    for i0 in range(0, m, rows):
        rv = min(rows, m - i0)
        for j0 in range(0, n, cols):
            cv = min(cols, n - j0)
            for state, cyc in tile_cycles(rv, cv, k, rows, cols, width, lat).items():
                total[state] += cyc
    return total


def predict_cycles(m, n, k, rows, cols, width=1, lat=1):
    """stall이 없을 때 명령 하나의 전체 사이클 (T_total)."""
    return sum(state_cycles(m, n, k, rows, cols, width, lat).values())


if __name__ == "__main__":
    for rows, cols in [(4, 4), (8, 8)]:
        for m, n, k in [(32, 64, 64), (1, 64, 64), (7, 13, 29)]:
            print(f"{rows}x{cols} (M,N,K)=({m},{n},{k})  W=1 L=1  T_total={predict_cycles(m, n, k, rows, cols)}")
