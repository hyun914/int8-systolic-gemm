"""
GEMM 코어를 Sky130 표준 셀(sky130_fd_sc_hd, tt 코너, 100 MHz 제약)로 구현해 면적과 타이밍을 뽑는다.

도구는 OpenROAD-flow-scripts Docker 이미지(openroad/orfs)를 쓴다.
  1. Yosys (계층 유지): 모듈별 면적으로 PE 배열, bank 버퍼, 제어의 비율을 구한다
  2. ORFS 흐름 (syn/config.mk): 합성, floorplan, 배치(버퍼 삽입과 셀 크기 조정 포함)까지 실행하고
     배치 후 면적과, 배선을 길이로 추정한 타이밍(worst slack)을 읽는다

배선(route) 전 값이고, bank 버퍼는 SRAM 매크로가 아니라 FF로 구현된다.
공식 수치는 ORFS 결과이고, 계층 합성의 묶음별 비율은 참고값이다 (계층을 나누면 경계를 넘는 최적화가 안 되므로).
산출물은 build/syn (Yosys, summary.csv)과 build/orfs (ORFS)에 남는다.

저장소 최상위 폴더에서 실행:
  python scripts/run_synth.py                    # 기본 구성 전부
  python scripts/run_synth.py --config 4 4 1     # ROWS COLS RD_BYTES 하나만
"""

import argparse
import csv
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SYN = ROOT / "build" / "syn"
ORFS_WORK = ROOT / "build" / "orfs"

IMAGE = "openroad/orfs:latest"
FLOW = "/OpenROAD-flow-scripts/flow"
YOSYS = "/OpenROAD-flow-scripts/tools/install/yosys/bin/yosys"
LIB = f"{FLOW}/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
PERIOD_NS = 10.0                                  # syn/constraint.sdc와 같아야 한다

RTL = [
    "RTL/PE.v",
    "RTL/systolic_array.v",
    "RTL/bank_buffer.v",
    "RTL/edge_feeder.v",
    "RTL/load_seq.v",
    "RTL/gemm_core.v",
]

# (ROWS, COLS, RD_BYTES)
CONFIGS = [(4, 4, 1), (8, 8, 1), (4, 4, 16), (8, 8, 16)]


def docker(cmd):
    """저장소를 /work에 연결한 컨테이너에서 명령을 실행하고 (종료 코드, 출력)을 돌려준다."""
    full = ["docker", "run", "--rm", "-v", f"{ROOT}:/work", "-w", "/work", IMAGE, "bash", "-c", cmd]
    result = subprocess.run(full, capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def yosys_area(name, rows, cols, width):
    """계층을 유지해 합성하고 묶음별 면적을 돌려준다."""
    reads = "\n".join(f"read_verilog {f}" for f in RTL)
    script = f"""{reads}
chparam -set ROWS {rows} -set COLS {cols} -set RD_BYTES {width} gemm_core
synth -top gemm_core
dfflibmap -liberty {LIB}
abc -liberty {LIB}
opt_clean
tee -o build/syn/{name}_area.txt stat -liberty {LIB}
"""
    (SYN / f"{name}.ys").write_text(script, encoding="utf-8")
    code, log = docker(f"{YOSYS} -q -l build/syn/{name}_yosys.log -s build/syn/{name}.ys")
    if code != 0:
        sys.exit(f"{name}: Yosys 실패\n{log[-3000:]}")
    return parse_area((SYN / f"{name}_area.txt").read_text(encoding="utf-8"), rows, cols)


def parse_area(text, rows, cols):
    """stat -liberty 출력에서 전체 면적과 묶음별 면적 (PE 배열, bank 버퍼, 제어)을 꺼낸다."""
    modules = {}
    for name, area in re.findall(r"Chip area for module '([^']+)': ([\d.]+)", text):
        modules[name.split("\\")[-1]] = float(area)
    top = float(re.findall(r"Chip area for top module '[^']+': ([\d.]+)", text)[-1])
    seq = float(re.findall(r"used for sequential elements: ([\d.]+)", text)[-1])

    # 최상위 바로 아래 인스턴스 수: 최상위 셀 목록 끝의 "N submodules" 다음 줄들
    counts = {}
    tail = text.split("submodules")[-1]
    for count, name in re.findall(r"^\s+(\d+)\s+\S+\s+\S*\\(\w+)\s*$", tail, re.M):
        counts[name] = counts.get(name, 0) + int(count)

    pe = rows * cols * modules["PE"]
    banks = counts.get("bank_buffer", 0) * modules["bank_buffer"]
    return {"total": top, "pe": pe, "banks": banks, "control": top - pe - banks, "seq": seq}


def orfs_place(name, rows, cols, width):
    """ORFS로 배치까지 실행하고 합성 면적, 배치 후 면적, worst slack, 최악 경로를 돌려준다."""
    nick = f"gemm_core_{rows}x{cols}_w{width}"
    make = (f"make -C {FLOW} DESIGN_CONFIG=/work/syn/config.mk WORK_HOME=/work/build/orfs "
            f"ROWS={rows} COLS={cols} RD_BYTES={width}")
    code, log = docker(f"{make} clean_all >/dev/null 2>&1; {make} synth floorplan place")
    (ORFS_WORK / f"run_{name}.log").write_text(log, encoding="utf-8")
    if code != 0:
        sys.exit(f"{name}: ORFS 실패 (build/orfs/run_{name}.log)\n{log[-3000:]}")

    reports = ORFS_WORK / "reports" / "sky130hd" / nick / "base"
    rpt = (reports / "3_detailed_place.rpt").read_text(encoding="utf-8")
    stat = (reports / "synth_stat.txt").read_text(encoding="utf-8")
    place = re.findall(r"Design area (\d+) um\^2 (\d+)% utilization", log)
    worst = rpt.split("report_checks -path_delay max")[1]
    return {
        "synth_area": float(re.findall(r"Chip area for (?:top )?module '[^']+': ([\d.]+)", stat)[-1]),
        "synth_seq": float(re.findall(r"used for sequential elements: ([\d.]+)", stat)[-1]),
        "place_area": int(place[-1][0]),
        "util": int(place[-1][1]),
        "slack": float(re.search(r"worst slack max (-?[\d.]+)", rpt).group(1)),
        "start": re.search(r"Startpoint: (\S+)", worst).group(1),
        "end": re.search(r"Endpoint: (\S+)", worst).group(1),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=int, nargs=3, metavar=("ROWS", "COLS", "RD_BYTES"),
                        help="구성 하나만 실행")
    args = parser.parse_args()
    configs = [tuple(args.config)] if args.config else CONFIGS

    SYN.mkdir(parents=True, exist_ok=True)
    ORFS_WORK.mkdir(parents=True, exist_ok=True)
    print(f"Sky130 HD tt_025C_1v80, 클럭 주기 {PERIOD_NS} ns, 배치 후 (배선 전)")
    print(f"{'구성':<12}{'합성 면적':>11}{'FF':>10}{'조합':>10}{'배치 면적':>11}{'이용률':>7}{'slack':>7}{'fmax':>6}"
          f"   계층 합성 비율 (참고) PE/bank/제어")

    rows_out = []
    for rows, cols, width in configs:
        name = f"core_{rows}x{cols}_w{width}"
        hier = yosys_area(name, rows, cols, width)
        r = orfs_place(name, rows, cols, width)
        fmax = 1000.0 / (PERIOD_NS - r["slack"])
        comb = r["synth_area"] - r["synth_seq"]
        t = hier["total"]
        print(f"{rows}x{cols} W={width:<5}{r['synth_area']:>11,.0f}{r['synth_seq']:>10,.0f}{comb:>10,.0f}"
              f"{r['place_area']:>11,}{r['util']:>6}%{r['slack']:>7.2f}{fmax:>6.0f}"
              f"   {hier['pe'] / t:.0%}/{hier['banks'] / t:.0%}/{hier['control'] / t:.0%}")
        print(f"{'':12}최악 경로: {r['start']} -> {r['end']}")
        rows_out.append({
            "rows": rows, "cols": cols, "rd_bytes": width,
            "synth_area_um2": round(r["synth_area"]), "synth_ff_um2": round(r["synth_seq"]),
            "synth_comb_um2": round(comb), "place_area_um2": r["place_area"], "util_pct": r["util"],
            "worst_slack_ns": r["slack"], "fmax_mhz": round(fmax, 1),
            "worst_start": r["start"], "worst_end": r["end"],
            "hier_total_um2": round(t), "hier_pe_um2": round(hier["pe"]),
            "hier_bank_um2": round(hier["banks"]), "hier_control_um2": round(hier["control"]),
        })

    with open(SYN / "summary.csv", "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows_out[0]))
        writer.writeheader()
        writer.writerows(rows_out)

    print("\n면적 um^2 (합성 면적, FF, 조합은 ORFS 합성 단계), slack ns, fmax MHz = 1000 / (주기 - slack).")
    print("계층 합성 비율은 계층을 유지한 Yosys 합성 기준의 참고값. 결과 표: build/syn/summary.csv")


if __name__ == "__main__":
    main()
