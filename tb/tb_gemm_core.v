`timescale 1ns/1ps

// tb_gemm_core : GEMM 코어 시스템 검증 (S2)
//
// 입력 파일 (scripts/run_core_tests.py가 만든다)
//   build/mem_init.hex   : 시작 메모리. 모든 명령의 A, B가 들어 있다.
//   build/mem_expect.hex : 모든 명령이 끝난 뒤 기대하는 메모리. C 영역이 정답으로 채워져 있다.
//   build/cmds.hex       : 첫 줄은 명령 수, 이후 명령마다 M, N, K, base_a, base_b, base_c
//
// 확인하는 것
//   - 명령을 연속으로 실행한 뒤 메모리 전체가 기대값과 같다 (C 밖에는 쓰지 않았다)
//   - C의 모든 바이트가 정확히 한 번씩 쓰였다
//   - STORE 동안 유효한 PE의 acc는 이미 최종 정답이다 (COMPUTE가 끝난 뒤에 STORE를 시작했다)
//   - STORE 동안 유효 범위 밖 PE의 acc는 0이다 (padding을 배열에 넣지 않았다)
//
// 메모리 모델 (S2): 항상 ready, 읽기 응답은 요청 다음 사이클에 돌아온다.
module tb_gemm_core;

    parameter ROWS = 4;
    parameter COLS = 4;

    localparam K_MAX     = 64;
    localparam AW        = 16;
    localparam MEM_BYTES = 1 << AW;
    localparam MAX_CMDS  = 8;

    reg           clk;
    reg           rst_n;

    reg           start;
    reg  [15:0]   cmd_m, cmd_n, cmd_k;
    reg  [AW-1:0] cmd_base_a, cmd_base_b, cmd_base_c;
    wire          busy;
    wire          done;

    wire          rd_req_valid;
    wire [AW-1:0] rd_req_addr;
    reg           rd_rsp_valid;
    reg  [7:0]    rd_rsp_data;

    wire          wr_valid;
    wire [AW-1:0] wr_addr;
    wire [31:0]   wr_data;

    reg [7:0]  mem        [0:MEM_BYTES-1];
    reg [7:0]  mem_expect [0:MEM_BYTES-1];
    reg        written    [0:MEM_BYTES-1];   // C 바이트가 이미 쓰였는지
    reg [15:0] cmds       [0:6*MAX_CMDS];

    integer num_cmds;
    integer ci, i;          // 메인 시나리오용
    integer wi;             // 쓰기 모델용
    integer pr, pc;         // STORE 중 PE 확인용
    integer exp_addr;
    reg [31:0] exp_word;
    integer cycles;

    gemm_core #(
        .ROWS(ROWS), .COLS(COLS), .K_MAX(K_MAX), .AW(AW)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start),
        .m_len(cmd_m), .n_len(cmd_n), .k_len(cmd_k),
        .base_a(cmd_base_a), .base_b(cmd_base_b), .base_c(cmd_base_c),
        .busy(busy), .done(done),
        .rd_req_valid(rd_req_valid), .rd_req_ready(1'b1), .rd_req_addr(rd_req_addr),
        .rd_rsp_valid(rd_rsp_valid), .rd_rsp_data(rd_rsp_data),
        .wr_valid(wr_valid), .wr_ready(1'b1), .wr_addr(wr_addr), .wr_data(wr_data)
    );

    // 100MHz 클럭
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // 메모리 읽기: ready가 항상 1이므로 valid인 사이클마다 요청이 성립하고, 다음 사이클에 응답한다.
    always @(posedge clk) begin
        if (!rst_n) begin
            rd_rsp_valid <= 1'b0;
        end else begin
            rd_rsp_valid <= rd_req_valid;
            rd_rsp_data  <= mem[rd_req_addr];
        end
    end

    // 메모리 쓰기: C 원소 하나(4바이트)를 little-endian으로 저장한다.
    always @(posedge clk) begin
        if (rst_n && wr_valid) begin
            if (wr_addr[1:0] != 2'b00)
                $fatal(1, "FAIL write: unaligned address %0d", wr_addr);
            for (wi = 0; wi < 4; wi = wi + 1) begin
                if (written[wr_addr + wi])
                    $fatal(1, "FAIL write: address %0d written twice", wr_addr + wi);
                mem[wr_addr + wi]     <= wr_data[wi*8 +: 8];
                written[wr_addr + wi] <= 1'b1;
            end
        end
    end

    // STORE 동안 PE 상태 확인 (코어 내부 신호를 직접 본다)
    //   유효한 PE        : acc가 이미 최종 정답 C[i0+r][j0+c]와 같아야 한다
    //   유효 범위 밖 PE  : MAC을 하지 않았으므로 acc가 0이어야 한다
    always @(posedge clk) begin
        if (rst_n && dut.state == dut.ST_STORE) begin
            for (pr = 0; pr < ROWS; pr = pr + 1) begin
                for (pc = 0; pc < COLS; pc = pc + 1) begin
                    if (pr < dut.rows_valid && pc < dut.cols_valid) begin
                        exp_addr = dut.base_c_r + ((dut.i0 + pr) * dut.n_r + dut.j0 + pc) * 4;
                        exp_word = {mem_expect[exp_addr + 3], mem_expect[exp_addr + 2],
                                    mem_expect[exp_addr + 1], mem_expect[exp_addr]};
                        if (dut.acc_out[(pr*COLS + pc)*32 +: 32] !== exp_word)
                            $fatal(1, "FAIL store before compute finished: PE(%0d,%0d) acc=%0d expected=%0d in tile i0=%0d j0=%0d",
                                   pr, pc, $signed(dut.acc_out[(pr*COLS + pc)*32 +: 32]),
                                   $signed(exp_word), dut.i0, dut.j0);
                    end else if (dut.acc_out[(pr*COLS + pc)*32 +: 32] !== 32'd0) begin
                        $fatal(1, "FAIL padding PE(%0d,%0d) acc=%0d in tile i0=%0d j0=%0d",
                               pr, pc, $signed(dut.acc_out[(pr*COLS + pc)*32 +: 32]),
                               dut.i0, dut.j0);
                    end
                end
            end
        end
    end

    initial begin
        $readmemh("build/mem_init.hex", mem);
        $readmemh("build/mem_expect.hex", mem_expect);
        $readmemh("build/cmds.hex", cmds);
        for (i = 0; i < MEM_BYTES; i = i + 1)
            written[i] = 1'b0;

        rst_n      = 1'b0;
        start      = 1'b0;
        cmd_m      = 0;
        cmd_n      = 0;
        cmd_k      = 0;
        cmd_base_a = 0;
        cmd_base_b = 0;
        cmd_base_c = 0;

        @(negedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        num_cmds = cmds[0];
        for (ci = 0; ci < num_cmds; ci = ci + 1) begin
            // IDLE에서 명령을 넣고 start를 1사이클 올린다
            @(negedge clk);
            cmd_m      = cmds[1 + 6*ci];
            cmd_n      = cmds[2 + 6*ci];
            cmd_k      = cmds[3 + 6*ci];
            cmd_base_a = cmds[4 + 6*ci];
            cmd_base_b = cmds[5 + 6*ci];
            cmd_base_c = cmds[6 + 6*ci];
            if (cmd_k < 1 || cmd_k > K_MAX)
                $fatal(1, "FAIL cmd %0d: K=%0d is outside 1..%0d", ci, cmd_k, K_MAX);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            // busy인 사이클 수 = SETUP부터 DONE까지
            cycles = 0;
            while (busy) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            $display("CMD %0d: M=%0d N=%0d K=%0d cycles=%0d", ci, cmd_m, cmd_n, cmd_k, cycles);
        end

        // 모든 C 바이트가 쓰였는지
        for (ci = 0; ci < num_cmds; ci = ci + 1)
            for (i = 0; i < cmds[1 + 6*ci] * cmds[2 + 6*ci] * 4; i = i + 1)
                if (!written[cmds[6 + 6*ci] + i])
                    $fatal(1, "FAIL cmd %0d: C byte at address %0d was not written",
                           ci, cmds[6 + 6*ci] + i);

        // 메모리 전체 비교
        for (i = 0; i < MEM_BYTES; i = i + 1)
            if (mem[i] !== mem_expect[i])
                $fatal(1, "FAIL memory[%0d] = %h, expected %h", i, mem[i], mem_expect[i]);

        $display("PASS: ROWS=%0d COLS=%0d, %0d commands", ROWS, COLS, num_cmds);
        $finish;
    end

    // 무한 대기 방지 (100ms = 1000만 사이클)
    initial begin
        #100000000;
        $fatal(1, "FAIL: simulation timeout");
    end

endmodule
