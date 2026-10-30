`timescale 1ns/1ps

// gemm_core : INT8 Output-Stationary GEMM 코어 (S2)
//
// C[M x N] = A[M x K] x B[K x N]을 ROWS x COLS 출력 타일 단위로 계산한다.
// 타일마다 SETUP -> LOAD -> COMPUTE -> STORE를 순서대로 실행하고, 단계끼리 겹치지 않는다.
// 타일 순서: i(행 타일) 바깥, j(열 타일) 안쪽. 타일마다 A와 B를 새로 읽는다 (재사용 정책 P0).
//
// 메모리 배치 (바이트 주소, row-major, 행 사이 빈칸 없음)
//   A[i][k] = base_a + i*K + k          INT8
//   B[k][j] = base_b + k*N + j          INT8
//   C[i][j] = base_c + (i*N + j)*4      INT32, little-endian
//
// 메모리 인터페이스 (S2: 읽기는 1바이트/beat, 쓰기는 INT32 1개/beat)
//   읽기 요청 : rd_req_valid, rd_req_ready, rd_req_addr
//   읽기 응답 : rd_rsp_valid, rd_rsp_data  (요청 순서대로 돌아오고, 코어는 항상 받는다)
//   쓰기      : wr_valid, wr_ready, wr_addr, wr_data
module gemm_core #(
    parameter ROWS  = 4,
    parameter COLS  = 4,
    parameter K_MAX = 64,                // 버퍼에 담을 수 있는 최대 K
    parameter AW    = 16                 // 메모리 바이트 주소 폭
)(
    input  wire          clk,
    input  wire          rst_n,

    // 명령
    input  wire          start,          // IDLE에서 1사이클 펄스
    input  wire [15:0]   m_len,
    input  wire [15:0]   n_len,
    input  wire [15:0]   k_len,          // 1 <= K <= K_MAX
    input  wire [AW-1:0] base_a,
    input  wire [AW-1:0] base_b,
    input  wire [AW-1:0] base_c,
    output wire          busy,
    output wire          done,           // 마지막 결과를 쓴 다음 사이클에 1사이클 펄스

    // 메모리 읽기
    output wire          rd_req_valid,
    input  wire          rd_req_ready,
    output wire [AW-1:0] rd_req_addr,
    input  wire          rd_rsp_valid,
    input  wire [7:0]    rd_rsp_data,

    // 메모리 쓰기
    output wire          wr_valid,
    input  wire          wr_ready,
    output wire [AW-1:0] wr_addr,
    output wire [31:0]   wr_data
);

    localparam BAW = $clog2(K_MAX);      // bank 안 주소 폭

    // ------------------------------------------------------------------
    // 상태
    // ------------------------------------------------------------------
    localparam [2:0] ST_IDLE    = 3'd0,
                     ST_SETUP   = 3'd1,  // 타일 시작: 누산기 clear, 로드 순서 초기화
                     ST_LOAD    = 3'd2,  // A, B 타일을 bank로 읽어 온다
                     ST_COMPUTE = 3'd3,  // bank에서 skew를 걸어 배열에 공급한다
                     ST_STORE   = 3'd4,  // 유효한 결과만 메모리에 쓴다
                     ST_DONE    = 3'd5;  // done 펄스

    reg [2:0] state;

    // 명령 레지스터 (start에서 받아 둔다)
    reg [15:0]   m_r, n_r, k_r;
    reg [AW-1:0] base_a_r, base_b_r, base_c_r;

    // 현재 타일의 시작 위치: C[i0 .. i0+ROWS-1][j0 .. j0+COLS-1]
    reg [15:0] i0, j0;

    // 경계 타일이면 유효 행/열 수가 ROWS, COLS보다 작다
    wire [15:0] rows_left  = m_r - i0;
    wire [15:0] cols_left  = n_r - j0;
    wire [15:0] rows_valid = (rows_left < ROWS) ? rows_left : ROWS;
    wire [15:0] cols_valid = (cols_left < COLS) ? cols_left : COLS;
    wire        last_tile  = (i0 + ROWS >= m_r) && (j0 + COLS >= n_r);

    // 타일 시작 주소 (타일마다 한 번만 쓴다)
    wire [AW-1:0] a_start = base_a_r + i0 * k_r;
    wire [AW-1:0] b_start = base_b_r + j0;
    wire [AW-1:0] c_start = base_c_r + (i0 * n_r + j0) * 4;

    // ------------------------------------------------------------------
    // LOAD: 요청 순서와 응답 순서
    // ------------------------------------------------------------------
    wire seq_init = (state == ST_SETUP);

    wire          req_fire = rd_req_valid && rd_req_ready;
    wire [AW-1:0] req_addr;
    wire          req_finished;

    load_seq #(.AW(AW)) u_req_seq (
        .clk(clk), .rst_n(rst_n),
        .init(seq_init), .step(req_fire),
        .rows_valid(rows_valid), .cols_valid(cols_valid),
        .k_len(k_r), .n_len(n_r),
        .a_start(a_start), .b_start(b_start),
        .phase_b(), .lane(), .k(),
        .addr(req_addr), .finished(req_finished)
    );

    assign rd_req_valid = (state == ST_LOAD) && !req_finished;
    assign rd_req_addr  = req_addr;

    wire        rsp_fire = (state == ST_LOAD) && rd_rsp_valid;
    wire        rsp_phase_b;
    wire [15:0] rsp_lane;
    wire [15:0] rsp_k;
    wire        rsp_finished;

    load_seq #(.AW(AW)) u_rsp_seq (
        .clk(clk), .rst_n(rst_n),
        .init(seq_init), .step(rsp_fire),
        .rows_valid(rows_valid), .cols_valid(cols_valid),
        .k_len(k_r), .n_len(n_r),
        .a_start(a_start), .b_start(b_start),
        .phase_b(rsp_phase_b), .lane(rsp_lane), .k(rsp_k),
        .addr(), .finished(rsp_finished)
    );

    // ------------------------------------------------------------------
    // 입력 버퍼: A는 행마다 bank 하나, B는 열마다 bank 하나
    // bank 안 주소는 k이다: A bank r의 k번 칸 = A[i0+r][k], B bank c의 k번 칸 = B[k][j0+c]
    // ------------------------------------------------------------------
    localparam [ROWS-1:0] ONE_A = 1;
    localparam [COLS-1:0] ONE_B = 1;

    wire [ROWS-1:0] a_wr_en = (rsp_fire && !rsp_phase_b) ? (ONE_A << rsp_lane) : {ROWS{1'b0}};
    wire [COLS-1:0] b_wr_en = (rsp_fire &&  rsp_phase_b) ? (ONE_B << rsp_lane) : {COLS{1'b0}};

    wire [ROWS*BAW-1:0] a_rd_addr;
    wire [ROWS*8-1:0]   a_rd_data;
    wire [COLS*BAW-1:0] b_rd_addr;
    wire [COLS*8-1:0]   b_rd_data;

    bank_buffer #(.NBANK(ROWS), .DEPTH(K_MAX), .AW(BAW)) u_abuf (
        .clk(clk),
        .wr_en(a_wr_en), .wr_addr(rsp_k[BAW-1:0]), .wr_data(rd_rsp_data),
        .rd_addr(a_rd_addr), .rd_data(a_rd_data)
    );

    bank_buffer #(.NBANK(COLS), .DEPTH(K_MAX), .AW(BAW)) u_bbuf (
        .clk(clk),
        .wr_en(b_wr_en), .wr_addr(rsp_k[BAW-1:0]), .wr_data(rd_rsp_data),
        .rd_addr(b_rd_addr), .rd_data(b_rd_data)
    );

    // ------------------------------------------------------------------
    // COMPUTE: bank 읽기 주소와 valid를 skew 규칙대로 만들어 배열에 공급한다
    // ------------------------------------------------------------------
    reg  [15:0] t;                                   // COMPUTE 사이클 번호
    wire        computing = (state == ST_COMPUTE);

    // bank 읽기 1사이클 때문에 배열이 보는 skew 시간은 t-1이다.
    // 마지막 MAC은 배열 시간 K+ROWS+COLS-3, 즉 t = K+ROWS+COLS-2에서 일어난다.
    wire [15:0] t_last = k_r + ROWS + COLS - 2;

    wire [ROWS-1:0] a_valid;
    wire [COLS-1:0] b_valid;

    edge_feeder #(.NLANE(ROWS), .AW(BAW)) u_afeed (
        .clk(clk), .rst_n(rst_n),
        .active(computing), .t(t), .k_len(k_r), .lanes_valid(rows_valid),
        .rd_addr(a_rd_addr), .valid_out(a_valid)
    );

    edge_feeder #(.NLANE(COLS), .AW(BAW)) u_bfeed (
        .clk(clk), .rst_n(rst_n),
        .active(computing), .t(t), .k_len(k_r), .lanes_valid(cols_valid),
        .rd_addr(b_rd_addr), .valid_out(b_valid)
    );

    wire [ROWS*COLS*32-1:0] acc_out;

    systolic_array #(.ROWS(ROWS), .COLS(COLS)) u_array (
        .clk(clk), .rst_n(rst_n),
        .clear(state == ST_SETUP),
        .a_in(a_rd_data), .a_valid_in(a_valid),
        .b_in(b_rd_data), .b_valid_in(b_valid),
        .acc_out(acc_out)
    );

    // ------------------------------------------------------------------
    // STORE: PE(r,c)의 acc를 C[i0+r][j0+c]에 쓴다 (r < rows_valid, c < cols_valid만)
    // ------------------------------------------------------------------
    reg  [15:0]   st_r, st_c;
    reg  [AW-1:0] st_addr;               // 지금 쓸 원소의 주소
    reg  [AW-1:0] st_row;                // 지금 행의 첫 원소 주소

    wire st_fire = wr_valid && wr_ready;
    wire st_last = (st_r == rows_valid - 1) && (st_c == cols_valid - 1);

    assign wr_valid = (state == ST_STORE);
    assign wr_addr  = st_addr;
    assign wr_data  = acc_out[(st_r*COLS + st_c)*32 +: 32];

    // ------------------------------------------------------------------
    // 상태 전이
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            m_r      <= 16'd0;
            n_r      <= 16'd0;
            k_r      <= 16'd0;
            base_a_r <= {AW{1'b0}};
            base_b_r <= {AW{1'b0}};
            base_c_r <= {AW{1'b0}};
            i0       <= 16'd0;
            j0       <= 16'd0;
            t        <= 16'd0;
            st_r     <= 16'd0;
            st_c     <= 16'd0;
            st_addr  <= {AW{1'b0}};
            st_row   <= {AW{1'b0}};
        end else begin
            case (state)
                ST_IDLE: begin
                    if (start) begin
                        m_r      <= m_len;
                        n_r      <= n_len;
                        k_r      <= k_len;
                        base_a_r <= base_a;
                        base_b_r <= base_b;
                        base_c_r <= base_c;
                        i0       <= 16'd0;
                        j0       <= 16'd0;
                        state    <= ST_SETUP;
                    end
                end

                ST_SETUP: begin
                    state <= ST_LOAD;
                end

                ST_LOAD: begin
                    // 마지막 응답까지 bank에 쓰고 나면 COMPUTE로
                    if (rsp_finished) begin
                        t     <= 16'd0;
                        state <= ST_COMPUTE;
                    end
                end

                ST_COMPUTE: begin
                    t <= t + 1'b1;
                    if (t == t_last) begin
                        st_r    <= 16'd0;
                        st_c    <= 16'd0;
                        st_addr <= c_start;
                        st_row  <= c_start;
                        state   <= ST_STORE;
                    end
                end

                ST_STORE: begin
                    if (st_fire) begin
                        if (st_last) begin
                            if (last_tile) begin
                                state <= ST_DONE;
                            end else begin
                                // 다음 타일: j를 먼저 늘리고, 행 끝이면 i로 넘어간다
                                if (j0 + COLS < n_r) begin
                                    j0 <= j0 + COLS;
                                end else begin
                                    j0 <= 16'd0;
                                    i0 <= i0 + ROWS;
                                end
                                state <= ST_SETUP;
                            end
                        end else if (st_c == cols_valid - 1) begin
                            // 다음 행: C의 한 행은 N*4바이트
                            st_c    <= 16'd0;
                            st_r    <= st_r + 1'b1;
                            st_row  <= st_row + n_r * 4;
                            st_addr <= st_row + n_r * 4;
                        end else begin
                            st_c    <= st_c + 1'b1;
                            st_addr <= st_addr + 4;
                        end
                    end
                end

                ST_DONE: begin
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    assign busy = (state != ST_IDLE);
    assign done = (state == ST_DONE);

endmodule
