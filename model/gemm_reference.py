
def gemm_reference(A,B):


    # 1. 입력 행렬의 크기와 데이터 범위 확인 과정

    if not A or not B or not A[0] or not B[0]:
        raise ValueError("입력 행렬이 비어있어서 오류")

    M = len(A)
    K = len(A[0])
    N = len(B[0])

    if len(B) != K:
        raise ValueError ("A의 열 수와 B의 행 수가 달라 연산 불가")

    if any(len(row) != K for row in A) or any(len(row) !=N for row in B):
        raise ValueError("같은 행렬에 속한 모든 행의 길이는 같아야 함")

    for matrix in (A,B):
        for row in matrix:
            for value in row:
                if type(value) is not int or not -128<=value<=127:
                    raise ValueError("입력 원소가 Signed INT8 범주를 벗어남")

    # 2. (M,N) 행렬의 출력 행렬을 0으로 초기화한다.
    C = [[0 for _ in range(N)]for _ in range(M)]

    # 3. 출력 원소마다 K 번의 곱셈과 누산 수행 (MAC)
    for i in range(M):
        for j in range(N):
            acc=0 # 미리 초기화
            for k in range(K): # AB MAC 진행
                acc += A[i][k] * B[k][j]
                if not -(2**31) <= acc < 2**31:
                    raise OverflowError("누산값이 INT32 범위를 벗어남")
            C[i][j] = acc # 아까 초기화한 곳에 누산값 대입
    return C

if __name__ == "__main__":
    A = [
        [1,2],
        [3,4],
    ]
    B = [
        [5,6],
        [7,8],
    ]

    C = gemm_reference(A,B)
    expected = [[19,22],[43,50]]
    assert C == expected, f"결과 불일치 : {C}"
    print("C =", C)
    print("테스트 통과")