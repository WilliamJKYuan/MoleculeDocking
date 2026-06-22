#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Parallel Batch LigPlot+ / HBPLUS pipeline for AutoDock Vina with auto OS LigPlus path - ligand-only list fixed
# Windows Git Bash / Linux compatible
#
# 输入:
#   receptor/OR1A1.pdb
#   Docking_Results_Parallel/OR1A1_xxx_out.pdbqt
#
# 输出:
#   LigPlot_Batch_Results/
#     complex_pdb/
#     ligand_pose_pdb/
#     split_pose_pdbqt/
#     ligplot_each/
#     images_ps/
#     images_png/
#     txt_data/
#     summary.tsv
#
# 关键修复:
#   HBPLUS 在 Windows 下常输出 .complex.nnb / .complex.hhb，
#   LigPlot 需要 complex.nnb / complex.hhb，所以脚本会自动复制。
#
# 并行方式:
#   每个 receptor-ligand-pose 作为一个独立任务后台运行。
#   每个任务写自己的 summary_parts/*.tsv，最后统一合并，避免多线程写同一个 summary.tsv 冲突。
# ============================================================


# ===================== 配置 =====================

RECEPTOR_DIR="./receptor"
DOCKING_DIR="./Docking_Results_Parallel"
OUT_DIR="./LigPlot_Batch_Results"

# LigPlus 根目录。
# 支持三种方式：
#   1) 直接修改 DEFAULT_LIGPLUS_DIR
#   2) 运行时输入路径
#   3) 用环境变量或第一个命令行参数指定：
#      LIGPLUS_DIR="/f/SciApp/LigPlus" ./batch_ligplot_vina_hbplus_autoos_with_list.sh
#      ./batch_ligplot_vina_hbplus_autoos_with_list.sh "/f/SciApp/LigPlus"
#
# Windows 路径支持两种写法：
#   CMD 风格:      F:\SciApp\LigPlus
#   Git Bash 风格: /f/SciApp/LigPlus
DEFAULT_LIGPLUS_DIR="/f/SciApp/LigPlus"

# 是否运行时询问 LigPlus 根目录
# 1 = 询问；直接回车使用 DEFAULT_LIGPLUS_DIR / 环境变量 / 第一个参数
# 0 = 不询问
ASK_LIGPLUS_DIR=1

# 以下路径会根据系统自动选择，不需要手动改
LIGPLUS_DIR=""
LIGPLUS_OS=""
LIGPLUS_EXE_DIR=""
LIGPLOT_BIN=""
HBADD_BIN=""
HBPLUS_BIN=""
LIGPLOT_PRM=""

# Open Babel 命令
OBABEL_BIN="obabel"

# 最大并行任务数
# 建议 Windows 上先用 4 或 6；如果机器很强可改成 8
MAX_JOBS=4

# 是否只处理每个受体-配体组合的最低能量 pose
# 0 = 所有 pose 都画
# 1 = 只画最低能量 pose
ONLY_LOWEST=0

# 是否覆盖已有结果
# 0 = 如果已有 ps/txt 则跳过
# 1 = 强制重跑
OVERWRITE=1

# ligand chain
LIG_CHAIN="X"
LIG_RESID="1"

# PNG 分辨率
PNG_DPI=300

# 是否尝试导出 PNG
# 1 = 导出 PNG；0 = 只保留 PS/txt，速度更快
EXPORT_PNG=1

# 是否输出简短进度
SHOW_PROGRESS=1

# 是否交互式设置以上运行参数
# 1 = 运行时逐项询问；直接回车使用默认值
# 0 = 不询问，使用脚本内默认值或环境变量
ASK_RUNTIME_CONFIG=1

# ===================== 用户配置区结束 =====================


# ===================== 目录初始化 =====================

SPLIT_DIR="$OUT_DIR/split_pose_pdbqt"
LIG_PDB_DIR="$OUT_DIR/ligand_pose_pdb"
COMPLEX_DIR="$OUT_DIR/complex_pdb"
EACH_DIR="$OUT_DIR/ligplot_each"
PS_DIR="$OUT_DIR/images_ps"
PNG_DIR="$OUT_DIR/images_png"
TXT_DIR="$OUT_DIR/txt_data"
SUMMARY_PARTS_DIR="$OUT_DIR/summary_parts"
LIST_PARTS_DIR="$OUT_DIR/list_parts"
TABLE_PARTS_DIR="$OUT_DIR/table_parts"
SUMMARY="$OUT_DIR/summary.tsv"
ALL_LIST="$TXT_DIR/all_ligplot_interaction_lists.cleaned.txt"
ALL_TABLE="$TXT_DIR/all_ligplot_interactions.tsv"
SELECTED_RESULT="$OUT_DIR/筛选结果.tsv"

mkdir -p "$SPLIT_DIR" "$LIG_PDB_DIR" "$COMPLEX_DIR" "$EACH_DIR" "$PS_DIR" "$PNG_DIR" "$TXT_DIR" "$SUMMARY_PARTS_DIR" "$LIST_PARTS_DIR" "$TABLE_PARTS_DIR"

# 每次运行先清空 parts，避免旧结果混入
rm -f "$SUMMARY_PARTS_DIR"/*.tsv "$LIST_PARTS_DIR"/*.txt "$TABLE_PARTS_DIR"/*.tsv 2>/dev/null || true

SUMMARY_HEADER=$'Receptor	Ligand	LigCode	Pose	Energy_kcal_mol	Status	Complex_PDB	PS	Final_PS	PNG	PNG_DuplicatePath	HHB	NNB	Named_HHB	Named_NNB	Interaction_txt	Clean_List	Interaction_Table_Part	Hydrogen_bond_residues	Non_bonded_contact_residues	Log'
TABLE_HEADER=$'PDB_code\tReceptor\tLigand\tLigCode\tPose\tEnergy_kcal_mol\tInteraction_type\tIndex\tLig_atom_no\tLig_atom_name\tLig_res_name\tLig_res_no\tLig_chain\tProtein_atom_no\tProtein_atom_name\tProtein_res_name\tProtein_res_no\tProtein_chain\tDistance\tRaw_line'


# ===================== 基础检查与 LigPlus 自动识别 =====================

die() {
    echo -e "\e[91m[ERROR] $*" >&2
    exit 1
}

need_file() {
    [[ -f "$1" ]] || die "Cannot find file: $1"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || [[ -x "$1" ]] || die "Cannot find command: $1"
}

normalize_ligplus_path() {
    # 支持用户输入 F:\SciApp\LigPlus 或 /f/SciApp/LigPlus
    python - "$1" <<'PY'
import sys, re
p = sys.argv[1].strip().strip('"').strip("'")
if re.match(r"^[A-Za-z]:[\\/]", p):
    drive = p[0].lower()
    rest = p[2:].replace("\\", "/")
    print(f"/{drive}{rest}")
else:
    print(p.replace("\\", "/"))
PY
}

has_exe_file() {
    local dir="$1"
    local base="$2"
    [[ -f "$dir/$base" || -f "$dir/$base.exe" ]]
}

pick_exe_file() {
    local dir="$1"
    local base="$2"

    if [[ -f "$dir/$base" ]]; then
        chmod +x "$dir/$base" 2>/dev/null || true
        echo "$dir/$base"
        return 0
    fi

    if [[ -f "$dir/$base.exe" ]]; then
        chmod +x "$dir/$base.exe" 2>/dev/null || true
        echo "$dir/$base.exe"
        return 0
    fi

    return 1
}

dir_has_ligplus_exes() {
    local dir="$1"
    has_exe_file "$dir" "ligplot" && has_exe_file "$dir" "hbadd" && has_exe_file "$dir" "hbplus"
}

resolve_ligplus_paths() {
    local input_dir="${LIGPLUS_DIR:-}"

    # 第一个命令行参数优先级最高
    if [[ "${1:-}" != "" ]]; then
        input_dir="$1"
    elif [[ -z "$input_dir" ]]; then
        input_dir="${DEFAULT_LIGPLUS_DIR:-}"
    fi

    if [[ "$ASK_LIGPLUS_DIR" == "1" ]]; then
        echo ""
        read -r -p "请输入 LigPlus目录 [默认: $input_dir]: " _ligplus_ans
        if [[ -n "${_ligplus_ans:-}" ]]; then
            input_dir="$_ligplus_ans"
        fi
    fi

    [[ -n "$input_dir" ]] || die "LigPlus directory is empty."

    LIGPLUS_DIR="$(normalize_ligplus_path "$input_dir")"
    LIGPLUS_DIR="${LIGPLUS_DIR%/}"

    [[ -d "$LIGPLUS_DIR" ]] || die "LigPlus directory does not exist: $LIGPLUS_DIR"
    [[ -d "$LIGPLUS_DIR/lib" ]] || die "Cannot find lib directory under LigPlus: $LIGPLUS_DIR/lib"

    local uname_s
    uname_s="$(uname -s 2>/dev/null || echo unknown)"

    local candidates=()
    case "$uname_s" in
        Linux*)
            LIGPLUS_OS="linux"
            # Linux 默认 64 位，无 .exe 后缀；pick_exe_file 会优先找无后缀文件。
            candidates=("exe_linux64" "exe_linux")
            ;;
        Darwin*)
            LIGPLUS_OS="macos"
            # macOS 默认 64 位，无 .exe 后缀；pick_exe_file 会优先找无后缀文件。
            candidates=("exe_mac64" "exe_mac")
            ;;
        MINGW*|MSYS*|CYGWIN*)
            LIGPLUS_OS="windows"
            # Windows 默认优先 exe_win；若不存在，再回退 exe_win32。
            # pick_exe_file 会自动寻找 ligplot 或 ligplot.exe。
            candidates=("exe_win" "exe_win32")
            ;;
        *)
            LIGPLUS_OS="unknown"
            candidates=("exe_linux64" "exe_mac64" "exe_win" "exe_linux" "exe_mac" "exe_win32")
            ;;
    esac

    LIGPLUS_EXE_DIR=""
    local c d
    for c in "${candidates[@]}"; do
        d="$LIGPLUS_DIR/lib/$c"
        if [[ -d "$d" ]] && dir_has_ligplus_exes "$d"; then
            LIGPLUS_EXE_DIR="$d"
            break
        fi
    done

    if [[ -z "$LIGPLUS_EXE_DIR" ]]; then
        echo -e "\e[93m[DEBUG] Tried executable directories:"
        for c in "${candidates[@]}"; do
            echo "  $LIGPLUS_DIR/lib/$c"
        done
        die "Cannot find usable LigPlus executable directory containing ligplot/hbadd/hbplus."
    fi

    LIGPLOT_BIN="$(pick_exe_file "$LIGPLUS_EXE_DIR" "ligplot")" || die "Cannot find ligplot in $LIGPLUS_EXE_DIR"
    HBADD_BIN="$(pick_exe_file "$LIGPLUS_EXE_DIR" "hbadd")" || die "Cannot find hbadd in $LIGPLUS_EXE_DIR"
    HBPLUS_BIN="$(pick_exe_file "$LIGPLUS_EXE_DIR" "hbplus")" || die "Cannot find hbplus in $LIGPLUS_EXE_DIR"

    # 参数文件位置，一般在 lib/params；少数安装包可能放在根目录或当前目录
    local prm_candidates=(
        "$LIGPLUS_DIR/lib/params/ligplot.prm"
        "$LIGPLUS_DIR/ligplot.prm"
        "./ligplot.prm"
    )

    LIGPLOT_PRM=""
    for p in "${prm_candidates[@]}"; do
        if [[ -f "$p" ]]; then
            LIGPLOT_PRM="$p"
            break
        fi
    done

    [[ -n "$LIGPLOT_PRM" ]] || die "Cannot find ligplot.prm. Tried: ${prm_candidates[*]}"

    echo -e "\e[33m"
    echo -e "\e[33m[LigPlus auto-detect]"
    echo -e "\e[33m  OS detected     : $LIGPLUS_OS ($uname_s)"
    echo -e "\e[33m  LigPlus root    : $LIGPLUS_DIR"
    echo -e "\e[33m  Executable dir  : $LIGPLUS_EXE_DIR"
    echo -e "\e[33m  ligplot         : $LIGPLOT_BIN"
    echo -e "\e[33m  hbadd           : $HBADD_BIN"
    echo -e "\e[33m  hbplus          : $HBPLUS_BIN"
    echo -e "\e[33m  ligplot.prm     : $LIGPLOT_PRM"
    echo -e "\e[33m"
}

ask_text() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local answer=""

    read -r -p "$prompt_text [默认: $default_value]: " answer
    if [[ -z "${answer:-}" ]]; then
        printf -v "$var_name" "%s" "$default_value"
    else
        printf -v "$var_name" "%s" "$answer"
    fi
}

ask_path_value() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local answer=""

    read -r -p "$prompt_text [默认: $default_value]: " answer
    if [[ -z "${answer:-}" ]]; then
        answer="$default_value"
    fi
    answer="$(normalize_ligplus_path "$answer")"
    printf -v "$var_name" "%s" "$answer"
}

ask_int_value() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local answer=""

    while true; do
        read -r -p "$prompt_text [默认: $default_value]: " answer
        if [[ -z "${answer:-}" ]]; then
            answer="$default_value"
        fi
        if [[ "$answer" =~ ^[0-9]+$ ]] && [[ "$answer" -ge 0 ]]; then
            printf -v "$var_name" "%s" "$answer"
            break
        fi
        echo -e "\e[93m请输入非负整数。\e[0m"
    done
}

ask_yes_no_01() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local answer=""

    while true; do
        local default_hint="N"
        [[ "$default_value" == "1" ]] && default_hint="Y"

        read -r -p "$prompt_text [默认: $default_hint]: " answer
        answer="${answer:-$default_hint}"
        answer="$(echo "$answer" | tr '[:upper:]' '[:lower:]')"

        case "$answer" in
            y|yes|1|true|on|是|需要|开启)
                printf -v "$var_name" "1"
                break
                ;;
            n|no|0|false|off|否|不需要|关闭)
                printf -v "$var_name" "0"
                break
                ;;
            *)
                echo "请输入 y/n。"
                ;;
        esac
    done
}

interactive_runtime_config() {
    [[ "${ASK_RUNTIME_CONFIG:-1}" == "1" ]] || return 0

    ask_int_value MAX_JOBS "01/12 最大并行任务数 MAX_JOBS，Windows 建议 4-8，服务器可更高" "${MAX_JOBS:-4}"
        if [[ "$MAX_JOBS" -lt 1 ]]; then
        echo -e "\e[91m[WARN] MAX_JOBS 不能小于 1，已自动改为 1。\e[0m"
        MAX_JOBS=1
    fi
    ask_path_value RECEPTOR_DIR "02/12 受体 PDB 文件夹" "${RECEPTOR_DIR:-./receptor}"
    ask_path_value DOCKING_DIR "03/12 Vina 对接结果文件夹 (*_out.pdbqt)" "${DOCKING_DIR:-./Docking_Results_Parallel}"
    ask_path_value OUT_DIR "04/12 LigPlot 批量输出文件夹" "${OUT_DIR:-./LigPlot_Batch_Results}"
    ask_text OBABEL_BIN "05/12 Open Babel 命令或完整路径" "${OBABEL_BIN:-obabel}"
    

    ask_yes_no_01 ONLY_LOWEST "06/12 是否只处理每个受体-配体组合的最低能量 pose" "${ONLY_LOWEST:-0}"
    ask_yes_no_01 OVERWRITE "07/12 是否覆盖已有结果" "${OVERWRITE:-1}"

    ask_text LIG_CHAIN "08/12 配体 chain ID" "${LIG_CHAIN:-X}"
    ask_int_value LIG_RESID "09/12 配体 residue number" "${LIG_RESID:-1}"
    ask_int_value PNG_DPI "10/12 PNG 分辨率 DPI" "${PNG_DPI:-300}"
    ask_yes_no_01 EXPORT_PNG "11/12 是否导出 PNG；选择否会明显更快，只保留 PS/txt" "${EXPORT_PNG:-1}"
    ask_yes_no_01 SHOW_PROGRESS "12/12 是否输出简短进度" "${SHOW_PROGRESS:-1}"

    echo ""
    echo "[运行参数确认]"
    echo "  RECEPTOR_DIR  = $RECEPTOR_DIR"
    echo "  DOCKING_DIR   = $DOCKING_DIR"
    echo "  OUT_DIR       = $OUT_DIR"
    echo "  OBABEL_BIN    = $OBABEL_BIN"
    echo "  MAX_JOBS      = $MAX_JOBS"
    echo "  ONLY_LOWEST   = $ONLY_LOWEST"
    echo "  OVERWRITE     = $OVERWRITE"
    echo "  LIG_CHAIN     = $LIG_CHAIN"
    echo "  LIG_RESID     = $LIG_RESID"
    echo "  PNG_DPI       = $PNG_DPI"
    echo "  EXPORT_PNG    = $EXPORT_PNG"
    echo "  SHOW_PROGRESS = $SHOW_PROGRESS"
    echo ""
}

setup_output_dirs() {
    SPLIT_DIR="$OUT_DIR/split_pose_pdbqt"
    LIG_PDB_DIR="$OUT_DIR/ligand_pose_pdb"
    COMPLEX_DIR="$OUT_DIR/complex_pdb"
    EACH_DIR="$OUT_DIR/ligplot_each"
    PS_DIR="$OUT_DIR/images_ps"
    PNG_DIR="$OUT_DIR/images_png"
    TXT_DIR="$OUT_DIR/txt_data"
    SUMMARY_PARTS_DIR="$OUT_DIR/summary_parts"
    LIST_PARTS_DIR="$OUT_DIR/list_parts"
    TABLE_PARTS_DIR="$OUT_DIR/table_parts"
    SUMMARY="$OUT_DIR/summary.tsv"
    ALL_LIST="$TXT_DIR/all_ligplot_interaction_lists.cleaned.txt"
    ALL_TABLE="$TXT_DIR/all_ligplot_interactions.tsv"

    mkdir -p "$SPLIT_DIR" "$LIG_PDB_DIR" "$COMPLEX_DIR" "$EACH_DIR" "$PS_DIR" "$PNG_DIR" "$TXT_DIR" "$SUMMARY_PARTS_DIR" "$LIST_PARTS_DIR" "$TABLE_PARTS_DIR"

    # 每次运行先清空 parts，避免旧结果混入
    rm -f "$SUMMARY_PARTS_DIR"/*.tsv "$LIST_PARTS_DIR"/*.txt "$TABLE_PARTS_DIR"/*.tsv 2>/dev/null || true
}

interactive_runtime_config
resolve_ligplus_paths "${1:-}"

need_cmd "$OBABEL_BIN"
need_file "$LIGPLOT_BIN"
need_file "$HBADD_BIN"
need_file "$HBPLUS_BIN"
need_file "$LIGPLOT_PRM"

# 交互设置 OUT_DIR 后，重新计算并创建所有输出目录
setup_output_dirs


# ===================== 小工具函数 =====================

safe_name() {
    echo "$1" | sed -E 's#[\\/:*?"<>| ]+#_#g; s/_+/_/g; s/^_//; s/_$//'
}

make_lig_code() {
    python - "$1" <<'PY'
import sys, re
name = sys.argv[1]
s = name.upper()
s = s.replace("ALPHA", "A").replace("BETA", "B").replace("GAMMA", "G").replace("DELTA", "D")
s = re.sub(r"[^A-Z0-9]+", "", s)
s2 = re.sub(r"^[0-9]+", "", s)
if len(s2) >= 3:
    code = s2[:3]
elif len(s) >= 3:
    code = "L" + s[:2]
else:
    code = ("L" + s + "X")[:3]
if not re.search(r"[A-Z]", code):
    code = "L" + code[:2]
print(code[:3])
PY
}

find_converter() {
    if command -v gswin64c >/dev/null 2>&1; then
        echo "gswin64c"
    elif command -v gswin32c >/dev/null 2>&1; then
        echo "gswin32c"
    elif command -v gs >/dev/null 2>&1; then
        echo "gs"
    elif command -v magick >/dev/null 2>&1; then
        echo "magick"
    elif command -v convert >/dev/null 2>&1; then
        echo "convert"
    else
        echo ""
    fi
}

CONVERTER="$(find_converter)"

convert_ps_to_png() {
    local ps_file="$1"
    local png_file="$2"

    [[ "$EXPORT_PNG" == "1" ]] || return 0
    [[ -n "$CONVERTER" ]] || return 0
    [[ -f "$ps_file" ]] || return 0

    case "$(basename "$CONVERTER" | tr '[:upper:]' '[:lower:]')" in
        gswin64c|gswin32c|gs)
            "$CONVERTER" \
                -dSAFER -dBATCH -dNOPAUSE \
                -sDEVICE=pngalpha \
                -r"$PNG_DPI" \
                -sOutputFile="$png_file" \
                "$ps_file" >/dev/null 2>&1 || true
            ;;
        magick)
            magick -density "$PNG_DPI" "$ps_file" -trim -background white -alpha remove -alpha off "$png_file" >/dev/null 2>&1 || true
            ;;
        convert)
            convert -density "$PNG_DPI" "$ps_file" -trim -background white -alpha remove -alpha off "$png_file" >/dev/null 2>&1 || true
            ;;
    esac
}

replace_lig_name_in_text() {
    local in_file="$1"
    local out_file="$2"
    local code="$3"
    local ligand="$4"

    python - "$in_file" "$out_file" "$code" "$ligand" <<'PY'
import sys, re
inp, outp, code, ligand = sys.argv[1:5]
text = open(inp, "r", encoding="utf-8", errors="replace").read()
text = re.sub(rf"\b{re.escape(code)}\b", ligand, text)
text = text.replace("Ligand residues: " + code, "Ligand residues: " + ligand)
open(outp, "w", encoding="utf-8", errors="replace").write(text)
PY
}

replace_lig_name_in_ps() {
    local in_ps="$1"
    local out_ps="$2"
    local code="$3"
    local ligand="$4"
    local title="${5:-$ligand}"

    python - "$in_ps" "$out_ps" "$code" "$ligand" "$title" <<'PY'
import sys, re
inp, outp, code, ligand, title = sys.argv[1:6]

def ps_escape(s):
    return s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")

lig = ps_escape(ligand)
ttl = ps_escape(title)
raw = open(inp, "rb").read()
text = raw.decode("latin-1", errors="replace")

# LigPlot 的标签有时会把 HEX 写成 Hex，所以这里同时替换大写、首字母大写、小写形式。
codes = sorted({code, code.upper(), code.capitalize(), code.lower()}, key=len, reverse=True)

for c in codes:
    patterns = [
        f"({c})",
        f"({c} 1)",
        f"({c}    1)",
        f"({c}  1)",
        f"({c} 1 X)",
        f"({c}    1  X)",
    ]
    for p in patterns:
        text = text.replace(p, "(" + lig + ")")

    text = re.sub(rf"\({re.escape(c)}\s+1\s+X\)", "(" + lig + ")", text)
    text = re.sub(rf"\({re.escape(c)}\s+1\)", "(" + lig + ")", text)

# 底部标题通常是输入文件 basename，例如 complex；这里强制改成 tag，避免所有图底部都叫 complex
text = text.replace("(complex)", "(" + ttl + ")")
text = text.replace("Title: complex", "Title: " + ttl)

open(outp, "wb").write(text.encode("latin-1", errors="replace"))
PY
}
count_data_lines() {
    local file="$1"
    [[ -f "$file" ]] || { echo 0; return; }
    grep -v -E '^[[:space:]]*$|output:|Donor[[:space:]]+Acceptor|Atom 1[[:space:]]+Atom 2|^#' "$file" 2>/dev/null | wc -l | tr -d ' '
}

make_clean_interaction_list_and_table() {
    local list_out="$1"
    local table_out="$2"
    local receptor="$3"
    local ligand="$4"
    local lig_code="$5"
    local pose="$6"
    local energy="$7"
    local tag="$8"
    local hhb_file="$9"
    local nnb_file="${10}"
    local work_dir="${11:-}"

    python - "$list_out" "$table_out" "$receptor" "$ligand" "$lig_code" "$pose" "$energy" "$tag" "$hhb_file" "$nnb_file" "$work_dir" "$LIG_CHAIN" "$LIG_RESID" <<'PY'
import sys
import re
from pathlib import Path

(
    list_out, table_out, receptor, ligand, lig_code, pose, energy, tag,
    hhb_file, nnb_file, work_dir, lig_chain, lig_resid
) = sys.argv[1:14]

lig_chain = (lig_chain or "X").strip()
lig_resid_int = int(lig_resid) if str(lig_resid).isdigit() else 1
lig_resid = str(lig_resid_int)
lig_resid_4 = f"{lig_resid_int:04d}"

AA = {
    "ALA","ARG","ASN","ASP","CYS","GLN","GLU","GLY","HIS","ILE",
    "LEU","LYS","MET","PHE","PRO","SER","THR","TRP","TYR","VAL",
    "SEC","PYL","ASX","GLX"
}

LIG_NAMES = {
    lig_code, lig_code.upper(), lig_code.capitalize(), lig_code.lower(),
    ligand, ligand.upper(), ligand.capitalize(), "LIG", "UNL"
}
LIG_NAMES = {x for x in LIG_NAMES if x}

def read_text_safe(path):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except Exception:
        return ""

def norm_resno(x):
    m = re.search(r"\d+", str(x))
    return str(int(m.group(0))) if m else str(x).strip()

def is_float(x):
    try:
        float(x)
        return True
    except Exception:
        return False

def is_protein_residue(res):
    return str(res).strip().upper() in AA

def is_ligand_atom(atom):
    """
    Ligand 判断严格以 chain X + residue 0001 为主；
    同时允许 residue name 为 lig_code/LIG/UNL 兜底。
    """
    chain = str(atom.get("chain", "")).strip()
    resno = norm_resno(atom.get("resno", ""))
    res = str(atom.get("res", "")).strip()

    if chain == lig_chain and resno == lig_resid:
        return True
    if res in LIG_NAMES and resno == lig_resid:
        return True
    return False

def first_distance_token(tokens, start_index):
    """
    HBPLUS 距离经常写成 3.06HM，不一定和后面的类型码分开；
    因此取剩余 token 中第一个浮点数作为原子间距离。
    """
    for tok in tokens[start_index:]:
        m = re.search(r"\d+\.\d+", tok)
        if m:
            return m.group(0)
    return ""

def parse_hbplus_atom(tokens, i):
    """
    解析 HBPLUS 原生格式中的一个原子描述。

    常见格式：
      A /A0075-SER O        -> chain=A, resno=0075, res=SER, atom=O
      X /X0001-HEXN1        -> chain=X, resno=0001, res=HEX, atom=N1
      X /X0001-HEXH1        -> chain=X, resno=0001, res=HEX, atom=H1

    返回: atom_dict, next_index
    """
    if i + 1 >= len(tokens):
        return None, i

    chain_col = tokens[i].strip()
    spec = tokens[i + 1].strip()

    m = re.match(r"^/([A-Za-z0-9])\s*(\d+)-([A-Za-z0-9]{3})(.*)$", spec)
    if not m:
        return None, i

    chain_in_spec, resno_raw, res, suffix = m.groups()
    chain = chain_in_spec.strip() or chain_col.strip()
    resno = norm_resno(resno_raw)
    res = res.strip()
    suffix = suffix.strip()

    if suffix:
        atom_name = suffix
        next_i = i + 2
    else:
        if i + 2 >= len(tokens):
            return None, i
        atom_name = tokens[i + 2].strip()
        next_i = i + 3

    return {
        "chain": chain,
        "resno": resno,
        "res": res,
        "atom": atom_name,
        "raw_spec": spec,
    }, next_i

def parse_hbplus_file(path, interaction_type):
    """
    只解析含配体 X0001 的 HBPLUS 行。
    这一步解决之前把蛋白内部相互作用全部抓进去的问题。
    """
    rows = []
    text = read_text_safe(path)
    idx = 0

    # 强过滤：没有 /X0001- 直接跳过
    lig_marker = f"/{lig_chain}{lig_resid_4}-"

    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if lig_marker not in line:
            continue
        if line.lower().endswith("output:"):
            continue
        if line.startswith(("Donor", "Acceptor", "Atom 1", "<-----", "Atom Atom")):
            continue

        toks = line.split()
        if len(toks) < 5:
            continue

        a1, j = parse_hbplus_atom(toks, 0)
        if a1 is None:
            continue
        a2, k = parse_hbplus_atom(toks, j)
        if a2 is None:
            continue

        dist = first_distance_token(toks, k)
        if not dist:
            continue

        a1_is_lig = is_ligand_atom(a1)
        a2_is_lig = is_ligand_atom(a2)

        if a1_is_lig and is_protein_residue(a2["res"]):
            lig, prot = a1, a2
        elif a2_is_lig and is_protein_residue(a1["res"]):
            lig, prot = a2, a1
        else:
            # 必须是一边配体，一边蛋白氨基酸，否则不要
            continue

        idx += 1
        rows.append({
            "type": interaction_type,
            "idx": str(idx),
            "lig_atom_no": "",
            "lig_atom_name": lig["atom"],
            "lig_res_name": ligand,
            "lig_res_no": lig["resno"],
            "lig_chain": lig["chain"] or ".",
            "prot_atom_no": "",
            "prot_atom_name": prot["atom"],
            "prot_res_name": prot["res"],
            "prot_res_no": prot["resno"],
            "prot_chain": prot["chain"] or ".",
            "distance": dist,
            "raw": line,
        })

    return rows

def parse_gui_like_list(text):
    """
    若 LigPlot 自己生成了 GUI 风格 list，也只保留 ligand-protein 行。
    """
    rows = []
    current_type = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue

        low = line.lower()
        if low.startswith("hydrogen bonds"):
            current_type = "Hydrogen_bond"
            continue
        if low.startswith("non-bonded contacts"):
            current_type = "Non_bonded_contact"
            continue
        if current_type is None:
            continue

        toks = line.split()
        if len(toks) < 8 or not toks[0].isdigit() or "---" not in toks:
            continue

        try:
            idx = toks[0]
            sep = toks.index("---")
            left = toks[1:sep]
            right_all = toks[sep + 1:]

            if len(left) < 4 or len(right_all) < 5:
                continue

            distance = right_all[-1]
            if not is_float(distance):
                continue
            right = right_all[:-1]

            left_atom_no, left_atom_name, left_res_name, left_res_no = left[:4]
            left_chain = left[4] if len(left) >= 5 else ""

            right_atom_no, right_atom_name, right_res_name, right_res_no = right[:4]
            right_chain = right[4] if len(right) >= 5 else ""

            left_atom = {"chain": left_chain, "resno": left_res_no, "res": left_res_name, "atom": left_atom_name}
            right_atom = {"chain": right_chain, "resno": right_res_no, "res": right_res_name, "atom": right_atom_name}

            if is_ligand_atom(left_atom) and is_protein_residue(right_res_name):
                lig = (left_atom_no, left_atom_name, ligand, norm_resno(left_res_no), left_chain or ".")
                prot = (right_atom_no, right_atom_name, right_res_name, norm_resno(right_res_no), right_chain or ".")
            elif is_ligand_atom(right_atom) and is_protein_residue(left_res_name):
                lig = (right_atom_no, right_atom_name, ligand, norm_resno(right_res_no), right_chain or ".")
                prot = (left_atom_no, left_atom_name, left_res_name, norm_resno(left_res_no), left_chain or ".")
            else:
                continue

            rows.append({
                "type": current_type,
                "idx": idx,
                "lig_atom_no": lig[0],
                "lig_atom_name": lig[1],
                "lig_res_name": lig[2],
                "lig_res_no": lig[3],
                "lig_chain": lig[4],
                "prot_atom_no": prot[0],
                "prot_atom_name": prot[1],
                "prot_res_name": prot[2],
                "prot_res_no": prot[3],
                "prot_chain": prot[4],
                "distance": distance,
                "raw": line,
            })
        except Exception:
            continue
    return rows

def find_native_ligplot_list(work_dir):
    if not work_dir:
        return None, ""
    wd = Path(work_dir)
    if not wd.exists():
        return None, ""

    candidates = []
    for f in wd.iterdir():
        if not f.is_file():
            continue
        if f.suffix.lower() in {".ps", ".png", ".pdb", ".frm", ".drw"}:
            continue
        try:
            if f.stat().st_size > 2_000_000:
                continue
        except Exception:
            continue
        txt = read_text_safe(f)
        low = txt.lower()
        if "list of protein-ligand interactions" in low or ("hydrogen bonds" in low and "non-bonded contacts" in low and "---" in txt):
            candidates.append((f, txt))
    if not candidates:
        return None, ""
    candidates.sort(key=lambda x: len(x[1]), reverse=True)
    return candidates[0]

native_file, native_text = find_native_ligplot_list(work_dir)

# 直接以 hhb/nnb 里含 /X0001- 的行为准；这样和你观察到的文件格式一致
hb_rows = parse_hbplus_file(hhb_file, "Hydrogen_bond")
nb_rows = parse_hbplus_file(nnb_file, "Non_bonded_contact")
rows = hb_rows + nb_rows

# 如果 hhb/nnb 没解析到，但 LigPlot 自己生成了 list，再用 list 兜底
source_note = f"Source: complex.hhb / complex.nnb lines containing /{lig_chain}{lig_resid_4}- only"
if not rows and native_text:
    rows = parse_gui_like_list(native_text)
    source_note = f"Source: native LigPlot list file = {native_file.name}; ligand-protein only"

def table_line(r):
    vals = [
        tag, receptor, ligand, lig_code, pose, energy, r["type"], r["idx"],
        r["lig_atom_no"], r["lig_atom_name"], r["lig_res_name"], r["lig_res_no"], r["lig_chain"],
        r["prot_atom_no"], r["prot_atom_name"], r["prot_res_name"], r["prot_res_no"], r["prot_chain"],
        r["distance"], r["raw"],
    ]
    return "\t".join(str(v).replace("\t", " ") for v in vals)

Path(table_out).write_text("\n".join(table_line(r) for r in rows) + ("\n" if rows else ""), encoding="utf-8")

hb_rows = [r for r in rows if r["type"] == "Hydrogen_bond"]
nb_rows = [r for r in rows if r["type"] == "Non_bonded_contact"]

lines = []
lines.append("List of ligand-receptor interactions")
lines.append("------------------------------------")
lines.append(f"PDB code: {tag}")
lines.append(f"Receptor: {receptor}")
lines.append(f"Ligand: {ligand}")
lines.append(f"LigPlot ligand code: {lig_code}")
lines.append(f"Pose: {pose}")
lines.append(f"Energy_kcal_mol: {energy}")
lines.append(source_note)

def append_section(title, section_rows):
    lines.append(title)
    lines.append("-" * len(title))
    lines.append("Index\tLigAtom\tLigand\tProteinAtom\tProteinRes\tProteinResNo\tProteinChain\tDistance")
    if section_rows:
        for r in section_rows:
            lines.append("\t".join([
                r["idx"],
                r["lig_atom_name"],
                r["lig_res_name"],
                r["prot_atom_name"],
                r["prot_res_name"],
                r["prot_res_no"],
                r["prot_chain"] or ".",
                r["distance"],
            ]))
    else:
        lines.append("None")

append_section("Hydrogen bonds", hb_rows)
append_section("Non-bonded contacts", nb_rows)

Path(list_out).write_text("\n".join(x for x in lines if x.strip()) + "\n", encoding="utf-8")
PY
}

make_residue_summary_from_table() {
    local table_file="$1"
    local interaction_type="$2"

    python - "$table_file" "$interaction_type" <<'PY'
import sys
from pathlib import Path

table_file, interaction_type = sys.argv[1:3]
p = Path(table_file)
if not p.exists():
    print("None")
    raise SystemExit

seen = []
for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    # columns:
    # 0 PDB, 1 Receptor, 2 Ligand, 3 LigCode, 4 Pose, 5 Energy,
    # 6 type, 14 Protein_atom_name, 15 Protein_res_name, 16 Protein_res_no, 17 Protein_chain
    if len(parts) < 18:
        continue
    if parts[6] != interaction_type:
        continue

    res = parts[15].strip()
    no = parts[16].strip()
    chain = parts[17].strip()
    if not res or not no:
        continue
    item = f"{res}{no}({chain})" if chain and chain != "." else f"{res}{no}"
    if item not in seen:
        seen.append(item)

print("; ".join(seen) if seen else "None")
PY
}



make_selected_results_from_summary() {
    local summary_file="$1"
    local selected_file="$2"

    python - "$summary_file" "$selected_file" <<'PY'
import sys
import csv
from pathlib import Path
from collections import defaultdict

summary_file, selected_file = sys.argv[1:3]
summary_path = Path(summary_file)
selected_path = Path(selected_file)

out_cols = [
    "Receptor",
    "Ligand",
    "LigCode",
    "Pose",
    "Energy_kcal_mol",
    "Hydrogen_bond_residues",
    "Non_bonded_contact_residues",
]

def is_missing_interaction(x):
    x = (x or "").strip()
    return x == "" or x.lower() in {"none", "na", "nan", "null", "-"}

def to_float(x):
    try:
        return float(str(x).strip())
    except Exception:
        return None

if not summary_path.exists():
    selected_path.write_text("\t".join(out_cols) + "\n", encoding="utf-8")
    raise SystemExit

with summary_path.open("r", encoding="utf-8", errors="replace", newline="") as f:
    reader = csv.DictReader(f, delimiter="\t")
    rows = list(reader)

groups = defaultdict(list)
for r in rows:
    receptor = (r.get("Receptor") or "").strip()
    ligand = (r.get("Ligand") or "").strip()
    ligcode = (r.get("LigCode") or "").strip()
    energy = to_float(r.get("Energy_kcal_mol"))

    # 没有能量的失败行不参与筛选
    if not receptor or not ligand or energy is None:
        continue

    r["_energy_float"] = energy
    groups[(receptor, ligand, ligcode)].append(r)

selected = []
for key in sorted(groups.keys()):
    candidates = groups[key]

    # 新筛选逻辑：
    # 1）先找 Receptor-Ligand 组合中结合能最低的 pose
    # 2）再找有氢键的 pose 中结合能最低的
    # 3）如果“最佳有氢键 pose”的结合能与“全局最低结合能 pose”的差值 < 1 kcal/mol，则选有氢键的
    # 4）否则选全局最低结合能 pose

    lowest_energy_pose = min(
        candidates,
        key=lambda r: (r["_energy_float"], int(r.get("Pose") or 999999))
    )

    hb_candidates = [
        r for r in candidates
        if not is_missing_interaction(r.get("Hydrogen_bond_residues"))
    ]

    if hb_candidates:
        best_hbond_pose = min(
            hb_candidates,
            key=lambda r: (r["_energy_float"], int(r.get("Pose") or 999999))
        )

        energy_gap = best_hbond_pose["_energy_float"] - lowest_energy_pose["_energy_float"]

        if energy_gap < 1.0:
            best = best_hbond_pose
        else:
            best = lowest_energy_pose
    else:
        best = lowest_energy_pose

    selected.append(best)

selected_path.parent.mkdir(parents=True, exist_ok=True)
with selected_path.open("w", encoding="utf-8", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=out_cols, delimiter="\t", extrasaction="ignore")
    writer.writeheader()
    for r in selected:
        writer.writerow({c: (r.get(c) or "None" if c.endswith("_residues") else r.get(c, "")) for c in out_cols})
PY
}



throttle_jobs() {
    while true; do
        local n
        n="$(jobs -rp | wc -l | tr -d ' ')"
        if [[ "$n" -lt "$MAX_JOBS" ]]; then
            break
        fi
        sleep 0.5
    done
}


# ===================== 拆分 Vina PDBQT =====================

split_vina_pdbqt() {
    local in_pdbqt="$1"
    local out_dir="$2"

    mkdir -p "$out_dir"

    python - "$in_pdbqt" "$out_dir" <<'PY'
import sys
from pathlib import Path

inp = Path(sys.argv[1])
out_dir = Path(sys.argv[2])
out_dir.mkdir(parents=True, exist_ok=True)

lines = inp.read_text(encoding="utf-8", errors="replace").splitlines()

poses = []
current = []
pose_id = None
energy = "NA"
in_model = False

for line in lines:
    if line.startswith("MODEL"):
        in_model = True
        current = []
        energy = "NA"
        parts = line.split()
        pose_id = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else len(poses) + 1
        continue

    if line.startswith("ENDMDL"):
        if in_model and current:
            p = out_dir / f"pose_{pose_id:02d}.pdbqt"
            e = out_dir / f"pose_{pose_id:02d}.energy.txt"
            p.write_text("\n".join(current) + "\n", encoding="utf-8")
            e.write_text(str(energy), encoding="utf-8")
            poses.append(pose_id)
        in_model = False
        current = []
        continue

    if in_model:
        if line.startswith("REMARK VINA RESULT:"):
            parts = line.split()
            if len(parts) >= 4:
                energy = parts[3]
        current.append(line)

if not poses:
    energy = "NA"
    for line in lines:
        if line.startswith("REMARK VINA RESULT:"):
            parts = line.split()
            if len(parts) >= 4:
                energy = parts[3]
    (out_dir / "pose_01.pdbqt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (out_dir / "pose_01.energy.txt").write_text(str(energy), encoding="utf-8")
PY
}


# ===================== 标准化 complex PDB =====================

make_complex_pdb() {
    local receptor_pdb="$1"
    local ligand_pdb="$2"
    local complex_pdb="$3"
    local lig_code="$4"

    python - "$receptor_pdb" "$ligand_pdb" "$complex_pdb" "$lig_code" "$LIG_CHAIN" "$LIG_RESID" <<'PY'
import sys, re
from pathlib import Path

receptor_pdb, ligand_pdb, complex_pdb, lig_code, lig_chain, lig_resid = sys.argv[1:7]
lig_resid = int(lig_resid)

def norm_elem(elem, atom_name=""):
    elem = (elem or "").strip()
    atom_name = (atom_name or "").strip()
    mapping = {
        "A": "C", "C": "C", "N": "N", "O": "O", "S": "S", "P": "P",
        "F": "F", "I": "I", "H": "H", "HD": "H",
        "NA": "N", "NS": "N", "OA": "O", "OS": "O", "SA": "S",
        "CL": "Cl", "Cl": "Cl", "BR": "Br", "Br": "Br"
    }
    if elem in mapping:
        return mapping[elem]
    up = elem.upper()
    if up in mapping:
        return mapping[up]
    name = re.sub(r"[^A-Za-z]", "", atom_name)
    if not name:
        return "C"
    if name[:2].upper() in ("CL", "BR"):
        return name[:2].capitalize()
    return name[0].upper()

def parse_atom(line):
    try:
        old_serial = int(line[6:11])
    except Exception:
        parts = line.split()
        old_serial = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None
    atom_name = line[12:16].strip() if len(line) >= 16 else ""
    x = float(line[30:38])
    y = float(line[38:46])
    z = float(line[46:54])
    occ = line[54:60].strip() if len(line) >= 60 and line[54:60].strip() else "1.00"
    bfac = line[60:66].strip() if len(line) >= 66 and line[60:66].strip() else "0.00"
    elem = line[76:78].strip() if len(line) >= 78 else ""
    if not elem:
        parts = line.split()
        elem = parts[-1] if parts else ""
    elem = norm_elem(elem, atom_name)
    return old_serial, atom_name, x, y, z, occ, bfac, elem

def fmt_atom(record, serial, atom_name, resname, chain, resid, x, y, z, occ, bfac, elem):
    return (
        f"{record:<6}{serial:5d} "
        f"{atom_name[:4]:<4s} "
        f"{resname[:3]:>3s} "
        f"{chain[:1]:1s}"
        f"{resid:4d}"
        f"    {x:8.3f}{y:8.3f}{z:8.3f}"
        f"{float(occ):6.2f}{float(bfac):6.2f}"
        f"          {elem[:2]:>2s}"
    )

out = []
serial = 1

for line in open(receptor_pdb, "r", encoding="utf-8", errors="replace"):
    if line.startswith("ATOM  "):
        out.append(line[:6] + f"{serial:5d}" + line[11:].rstrip("\n"))
        serial += 1
    elif line.startswith("TER"):
        out.append("TER")

out.append("TER")

lig_atoms = []
conects = []
for line in open(ligand_pdb, "r", encoding="utf-8", errors="replace"):
    if line.startswith(("ATOM  ", "HETATM")):
        lig_atoms.append(parse_atom(line))
    elif line.startswith("CONECT"):
        parts = line.split()
        if len(parts) >= 3:
            try:
                src = int(parts[1])
                for t in parts[2:]:
                    if t.isdigit():
                        conects.append((src, int(t)))
            except Exception:
                pass

old_to_new = {}
elem_count = {}

for old_serial, atom_name, x, y, z, occ, bfac, elem in lig_atoms:
    key = elem.upper()
    elem_count[key] = elem_count.get(key, 0) + 1
    new_atom_name = f"{elem.upper()}{elem_count[key]}"[:4]

    new_serial = serial
    if old_serial is not None:
        old_to_new[old_serial] = new_serial

    out.append(fmt_atom("HETATM", new_serial, new_atom_name, lig_code, lig_chain, lig_resid, x, y, z, occ, bfac, elem))
    serial += 1

seen = set()
for a, b in conects:
    if a in old_to_new and b in old_to_new:
        na, nb = old_to_new[a], old_to_new[b]
        key = tuple(sorted((na, nb)))
        if key not in seen:
            seen.add(key)
            out.append(f"CONECT{na:5d}{nb:5d}")

out.append("END")
Path(complex_pdb).parent.mkdir(parents=True, exist_ok=True)
Path(complex_pdb).write_text("\n".join(out) + "\n", encoding="utf-8")
PY
}


# ===================== 单个 pose 任务 =====================

process_pose_job() {
    local receptor_name="$1"
    local receptor_pdb="$2"
    local ligand_name="$3"
    local lig_code="$4"
    local pose_pdbqt="$5"
    local pose_id="$6"
    local energy="$7"
    local tag="$8"

    local ligand_pose_pdb="$LIG_PDB_DIR/${tag}.pdb"
    local complex_pdb="$COMPLEX_DIR/${tag}.pdb"
    local work_dir="$EACH_DIR/$tag"
    local log_file="$work_dir/run.log"

    # 最终只保留一套图片，不再同时生成 raw 和 .named 两套重复文件
    local ps_raw="$PS_DIR/${tag}.ps"
    local ps_named="$ps_raw"
    local png_raw="$PNG_DIR/${tag}.png"
    local png_named="$png_raw"

    local hhb_raw="$TXT_DIR/${tag}.hhb.txt"
    local nnb_raw="$TXT_DIR/${tag}.nnb.txt"
    local hhb_named="$TXT_DIR/${tag}.hhb.named.txt"
    local nnb_named="$TXT_DIR/${tag}.nnb.named.txt"
    local interaction_txt="$TXT_DIR/${tag}.interactions.named.txt"
    local clean_list="$TXT_DIR/${tag}.ligplot_list.cleaned.txt"
    local list_part="$LIST_PARTS_DIR/${tag}.list.txt"
    local table_part="$TABLE_PARTS_DIR/${tag}.interactions.tsv"

    local summary_part="$SUMMARY_PARTS_DIR/${tag}.tsv"

    local status="OK"

    if [[ "$OVERWRITE" == "0" && -f "$ps_raw" && -f "$nnb_named" && -f "$interaction_txt" ]]; then
        status="SKIPPED"
        local hb_residues="None"
        local nb_residues="None"
        [[ -f "$table_part" ]] && hb_residues="$(make_residue_summary_from_table "$table_part" "Hydrogen_bond")"
        [[ -f "$table_part" ]] && nb_residues="$(make_residue_summary_from_table "$table_part" "Non_bonded_contact")"
        echo -e "$receptor_name\t$ligand_name\t$lig_code\t$((10#$pose_id))\t$energy\t$status\t$complex_pdb\t$ps_raw\t$ps_named\t${png_raw:-NA}\t${png_named:-NA}\t$hhb_raw\t$nnb_raw\t$hhb_named\t$nnb_named\t$interaction_txt\t$clean_list\t$table_part\t$hb_residues\t$nb_residues\t$log_file" > "$summary_part"
        return 0
    fi

    rm -rf "$work_dir"
    mkdir -p "$work_dir"

    {
        echo -e "\e[33m[INFO] receptor=$receptor_name"
        echo -e "\e[33m[INFO] ligand=$ligand_name"
        echo -e "\e[33m[INFO] lig_code=$lig_code"
        echo -e "\e[33m[INFO] pose=$pose_id"
        echo -e "\e[33m[INFO] energy=$energy"
        echo -e "\e[33m[INFO] tag=$tag"
        echo ""
    } > "$log_file"

    # 1. Open Babel
    if ! "$OBABEL_BIN" -ipdbqt "$pose_pdbqt" -opdb -O "$ligand_pose_pdb" >> "$log_file" 2>&1; then
        status="OBABEL_FAIL"
        echo -e "$receptor_name\t$ligand_name\t$lig_code\t$((10#$pose_id))\t$energy\t$status\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNone\tNone\t$log_file" > "$summary_part"
        return 0
    fi

    # 2. Complex PDB
    if ! make_complex_pdb "$receptor_pdb" "$ligand_pose_pdb" "$complex_pdb" "$lig_code" >> "$log_file" 2>&1; then
        status="COMPLEX_FAIL"
        echo -e "$receptor_name\t$ligand_name\t$lig_code\t$((10#$pose_id))\t$energy\t$status\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNone\tNone\t$log_file" > "$summary_part"
        return 0
    fi

    cp "$complex_pdb" "$work_dir/complex.pdb"
    cp "$LIGPLOT_PRM" "$work_dir/ligplot.prm"
    : > "$work_dir/dummy_het_dictionary.txt"

    # 3. HBADD + HBPLUS + LigPlot
    (
        cd "$work_dir"

        echo -e "\e[36m[STEP] hbadd" >> run.log
        "$HBADD_BIN" "complex.pdb" "dummy_het_dictionary.txt" -wkdir "." >> run.log 2>&1 || true

        echo "" >> run.log
        echo -e "\e[36m[STEP] hbplus non-bonded contacts" >> run.log
        "$HBPLUS_BIN" -L -f "hbplus.rc" -h 2.90 -d 3.90 -N "complex.pdb" -wkdir "." >> run.log 2>&1 || true

        if [[ -f ".complex.nnb" ]]; then
            cp ".complex.nnb" "complex.nnb"
        elif [[ -f "complex.nnb" ]]; then
            true
        else
            echo -e "\e[91m[WARN] No .complex.nnb / complex.nnb generated" >> run.log
            : > "complex.nnb"
        fi

        echo "" >> run.log
        echo -e "\e[36m[STEP] hbplus hydrogen bonds" >> run.log
        "$HBPLUS_BIN" -L -f "hbplus.rc" -h 2.70 -d 3.35 "complex.pdb" -wkdir "." >> run.log 2>&1 || true

        if [[ -f ".complex.hhb" ]]; then
            cp ".complex.hhb" "complex.hhb"
        elif [[ -f "complex.hhb" ]]; then
            true
        else
            echo -e "\e[91m[WARN] No .complex.hhb / complex.hhb generated" >> run.log
            : > "complex.hhb"
        fi

        echo "" >> run.log
        echo -e "\e[36m[STEP] ligplot" >> run.log
        "$LIGPLOT_BIN" "complex.pdb" "$lig_code" "$LIG_RESID" "$lig_code" "$LIG_RESID" "$LIG_CHAIN" >> run.log 2>&1 || true
    )

    if [[ -f "$work_dir/ligplot.ps" ]]; then
        # 直接把 LigPlot 原始 PS 处理成最终 PS：
        # 1) 尝试把内部 3 字符配体代码替换为完整配体名
        # 2) 把底部标题 complex 改成当前 receptor-ligand-pose 的 tag
        replace_lig_name_in_ps "$work_dir/ligplot.ps" "$ps_raw" "$lig_code" "$ligand_name" "$tag" || cp "$work_dir/ligplot.ps" "$ps_raw"
    else
        status="NO_PS"
    fi

    if [[ -f "$work_dir/complex.hhb" ]]; then
        cp "$work_dir/complex.hhb" "$hhb_raw"
        replace_lig_name_in_text "$hhb_raw" "$hhb_named" "$lig_code" "$ligand_name" || true
    else
        echo "No complex.hhb generated." > "$hhb_raw"
        echo "No complex.hhb generated." > "$hhb_named"
        status="${status}_NO_HHB"
    fi

    if [[ -f "$work_dir/complex.nnb" ]]; then
        cp "$work_dir/complex.nnb" "$nnb_raw"
        replace_lig_name_in_text "$nnb_raw" "$nnb_named" "$lig_code" "$ligand_name" || true
    else
        echo "No complex.nnb generated." > "$nnb_raw"
        echo "No complex.nnb generated." > "$nnb_named"
        status="${status}_NO_NNB"
    fi

    if [[ -f "$ps_raw" ]]; then
        convert_ps_to_png "$ps_raw" "$png_raw"
    fi

    {
        echo "Receptor: $receptor_name"
        echo "Ligand: $ligand_name"
        echo "LigPlot_internal_ligand_code: $lig_code"
        echo "Pose: $((10#$pose_id))"
        echo "Energy_kcal_mol: $energy"
        echo "Complex_PDB: $complex_pdb"
        echo "PS: $ps_raw"
        echo "PNG: $png_raw"
        echo ""
        echo "============================================================"
        echo "Hydrogen bonds / .hhb"
        echo "============================================================"
        cat "$hhb_named" 2>/dev/null || true
        echo ""
        echo "============================================================"
        echo "Non-bonded contacts / .nnb"
        echo "============================================================"
        cat "$nnb_named" 2>/dev/null || true
        echo ""
        echo "============================================================"
        echo "Run log"
        echo "============================================================"
        cat "$log_file" 2>/dev/null || true
    } > "$interaction_txt"

    make_clean_interaction_list_and_table "$clean_list" "$table_part" "$receptor_name" "$ligand_name" "$lig_code" "$((10#$pose_id))" "$energy" "$tag" "$hhb_raw" "$nnb_raw" "$work_dir" || true
    cp "$clean_list" "$list_part" 2>/dev/null || true

    local nnb_count
    nnb_count="$(count_data_lines "$nnb_named")"
    if [[ "$nnb_count" -eq 0 ]]; then
        status="${status}_NNB_EMPTY"
    fi

    local hb_residues
    local nb_residues
    hb_residues="$(make_residue_summary_from_table "$table_part" "Hydrogen_bond")"
    nb_residues="$(make_residue_summary_from_table "$table_part" "Non_bonded_contact")"

    echo -e "$receptor_name\t$ligand_name\t$lig_code\t$((10#$pose_id))\t$energy\t$status\t$complex_pdb\t$ps_raw\t$ps_named\t${png_raw:-NA}\t${png_named:-NA}\t$hhb_raw\t$nnb_raw\t$hhb_named\t$nnb_named\t$interaction_txt\t$clean_list\t$table_part\t$hb_residues\t$nb_residues\t$log_file" > "$summary_part"

    if [[ "$SHOW_PROGRESS" == "1" ]]; then
        echo -e "\e[32m[DONE]$tag status=$status"
    fi
}


# ===================== 主循环：提交并行任务 =====================

echo "============================================================"
echo "Parallel Batch LigPlot+ / HBPLUS for Vina"
echo "============================================================"
echo "RECEPTOR_DIR = $RECEPTOR_DIR"
echo "DOCKING_DIR  = $DOCKING_DIR"
echo "OUT_DIR      = $OUT_DIR"
echo "LIGPLUS_DIR  = $LIGPLUS_DIR"
echo "LIGPLUS_EXE  = $LIGPLUS_EXE_DIR"
echo "MAX_JOBS     = $MAX_JOBS"
echo "ONLY_LOWEST  = $ONLY_LOWEST"
echo "LIG_CHAIN    = $LIG_CHAIN"
echo "LIG_RESID    = $LIG_RESID"
echo "OVERWRITE    = $OVERWRITE"
echo "EXPORT_PNG   = $EXPORT_PNG"
echo "CONVERTER    = ${CONVERTER:-None}"
echo "============================================================"

submitted=0
pair_count=0

shopt -s nullglob

for receptor_pdb in "$RECEPTOR_DIR"/*.pdb; do
    receptor_name="$(basename "$receptor_pdb" .pdb)"

    echo ""
    echo "------------------------------------------------------------"
    echo -e "\e[34m[RECEPTOR] $receptor_name"
    echo "------------------------------------------------------------"

    docking_files=( "$DOCKING_DIR"/"${receptor_name}"_*_out.pdbqt )

    if [[ "${#docking_files[@]}" -eq 0 ]]; then
        echo -e "\e[91m[WARN] No docking files found for receptor: $receptor_name"
        continue
    fi

    for out_pdbqt in "${docking_files[@]}"; do
        pair_count=$((pair_count + 1))

        out_base="$(basename "$out_pdbqt" .pdbqt)"
        ligand_name="${out_base#${receptor_name}_}"
        ligand_name="${ligand_name%_out}"

        lig_code="$(make_lig_code "$ligand_name")"
        pair_safe="$(safe_name "${receptor_name}__${ligand_name}")"

        echo -e "\e[96m[PAIR] $receptor_name - $ligand_name  [code=$lig_code]"

        pair_split_dir="$SPLIT_DIR/$pair_safe"
        split_vina_pdbqt "$out_pdbqt" "$pair_split_dir"

        pose_files=( "$pair_split_dir"/pose_*.pdbqt )

        if [[ "$ONLY_LOWEST" == "1" ]]; then
            lowest_pose_file=""
            lowest_energy=""
            for pose_pdbqt in "${pose_files[@]}"; do
                pose_id="$(basename "$pose_pdbqt" .pdbqt | sed 's/pose_//')"
                energy_file="$pair_split_dir/pose_${pose_id}.energy.txt"
                energy="NA"
                [[ -f "$energy_file" ]] && energy="$(cat "$energy_file" | tr -d '[:space:]')"

                if [[ "$energy" != "NA" && -n "$energy" ]]; then
                    if [[ -z "$lowest_energy" ]]; then
                        lowest_energy="$energy"
                        lowest_pose_file="$pose_pdbqt"
                    else
                        if awk -v e="$energy" -v le="$lowest_energy" 'BEGIN{exit !(e < le)}'; then
                            lowest_energy="$energy"
                            lowest_pose_file="$pose_pdbqt"
                        fi
                    fi
                fi
            done

            if [[ -n "$lowest_pose_file" ]]; then
                pose_files=( "$lowest_pose_file" )
            else
                pose_files=( "${pose_files[0]}" )
            fi
        fi

        for pose_pdbqt in "${pose_files[@]}"; do
            pose_id="$(basename "$pose_pdbqt" .pdbqt | sed 's/pose_//')"
            energy_file="$pair_split_dir/pose_${pose_id}.energy.txt"
            energy="NA"
            [[ -f "$energy_file" ]] && energy="$(cat "$energy_file" | tr -d '[:space:]')"

            tag="${pair_safe}__pose_${pose_id}"

            throttle_jobs

            if [[ "$SHOW_PROGRESS" == "1" ]]; then
                running="$(jobs -rp | wc -l | tr -d ' ')"
                echo -e "\e[34m[SUBMIT] $tag energy=$energy  running=$running/$MAX_JOBS"
            fi

            process_pose_job "$receptor_name" "$receptor_pdb" "$ligand_name" "$lig_code" "$pose_pdbqt" "$pose_id" "$energy" "$tag" &

            submitted=$((submitted + 1))
        done
    done
done

# echo ""
echo -e "\e[32m[INFO] All jobs submitted: $submitted"
echo -e "\e[33;5m[INFO] Waiting for background jobs...\e[0m"
wait

# 合并 summary
{
    echo "$SUMMARY_HEADER"
    if compgen -G "$SUMMARY_PARTS_DIR/*.tsv" > /dev/null; then
        cat "$SUMMARY_PARTS_DIR"/*.tsv
    fi
} > "$SUMMARY"

# 根据 summary.tsv 筛选每一组 receptor-ligand 的最佳 pose：
# 1) 如果有氢键，选“有氢键且结合能最低”的 pose；
# 2) 如果没有氢键，选“结合能最低”的 pose。
make_selected_results_from_summary "$SUMMARY" "$SELECTED_RESULT"

# 合并所有 cleaned list：无空行，每个 pose 之间用分隔线
: > "$ALL_LIST"
if compgen -G "$LIST_PARTS_DIR/*.txt" > /dev/null; then
    first_list=1
    for f in "$LIST_PARTS_DIR"/*.txt; do
        if [[ "$first_list" -eq 0 ]]; then
            echo "============================================================" >> "$ALL_LIST"
        fi
        grep -v -E '^[[:space:]]*$' "$f" >> "$ALL_LIST" || true
        first_list=0
    done
fi

# 合并所有结构化 TSV 表格
{
    echo "$TABLE_HEADER"
    if compgen -G "$TABLE_PARTS_DIR/*.tsv" > /dev/null; then
        cat "$TABLE_PARTS_DIR"/*.tsv
    fi
} > "$ALL_TABLE"

echo -e "\e[0m"
echo "============================================================"
echo "Finished."
echo "Pairs processed : $pair_count"
echo "Pose jobs       : $submitted"
echo "Summary         : $SUMMARY"
echo "Selected result : $SELECTED_RESULT"
echo "All clean list  : $ALL_LIST"
echo "All table       : $ALL_TABLE"
echo "PS images       : $PS_DIR"
echo "PNG images      : $PNG_DIR"
echo "TXT data        : $TXT_DIR"
echo "Complex PDB     : $COMPLEX_DIR"
echo "============================================================"
