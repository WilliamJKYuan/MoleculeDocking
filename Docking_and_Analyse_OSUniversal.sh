#!/usr/bin/env bash
set -o pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

OS_NAME=$(uname -s 2>/dev/null || echo "Unknown")
case "$OS_NAME" in
    Linux*) SYSTEM_TYPE="Linux" ;;
    MINGW*|MSYS*|CYGWIN*) SYSTEM_TYPE="Windows" ;;
    *) SYSTEM_TYPE="Unknown" ;;
esac
[ "$SYSTEM_TYPE" = "Windows" ] && chcp.com 65001 >/dev/null 2>&1  # Git Bash 下切换 UTF-8 代码页

SCRIPT_SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR=$(cd "$(dirname "$SCRIPT_SELF")" >/dev/null 2>&1 && pwd)

bar() { echo "----------------------------------------"; }

normalize_path() {  # 统一清理用户输入路径，并把 Windows 反斜杠路径转成 Git Bash 路径
    local p="$1"
    p=$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    p="${p%\"}"; p="${p#\"}"; p="${p%\'}"; p="${p#\'}"
    p="${p/#\~/$HOME}"
    if [[ "$SYSTEM_TYPE" = "Windows" && "$p" =~ ^[A-Za-z]:\\ ]]; then
        if command -v cygpath >/dev/null 2>&1; then
            p=$(cygpath -u "$p")
        else
            local drive rest
            drive=$(echo "${p:0:1}" | tr 'A-Z' 'a-z')
            rest="${p:2}"; rest="${rest//\\//}"
            p="/${drive}${rest}"
        fi
    fi
    echo "$p"
}

to_native_path() {  # Windows路径转换
    local p="$1"
    if [ "$SYSTEM_TYPE" = "Windows" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$p"
    else
        echo "$p"
    fi
}

abs_dir() {  # 检查目录是否存在，并返回绝对路径
    local p
    p=$(normalize_path "$1")
    [ -z "$p" ] && return 1
    [ ! -d "$p" ] && return 1
    cd "$p" && pwd
}

rel_to_workdir() {  # 用户输入相对路径时，默认相对于工作目录
    local p base="$2"
    p=$(normalize_path "$1")
    [ -z "$p" ] && echo "" && return
    [[ "$p" = /* ]] && echo "$p" && return
    echo "$base/$p"
}

detect_cpu_threads() {  # 自动检测 CPU 线程数，用于推荐并行任务数
    if command -v nproc >/dev/null 2>&1; then nproc; return; fi
    if command -v getconf >/dev/null 2>&1; then getconf _NPROCESSORS_ONLN; return; fi
    if [ -n "${NUMBER_OF_PROCESSORS:-}" ]; then echo "$NUMBER_OF_PROCESSORS"; return; fi
    if command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command "[Environment]::ProcessorCount" | tr -d '\r'
        return
    fi
    echo 4
}

safe_cpu_threads() {
    local total
    total=$(detect_cpu_threads)
    if ! [[ "$total" =~ ^[0-9]+$ ]] || [ "$total" -lt 1 ]; then
        total=4
    fi
    echo "$total"
}

min_int() {
    local a="$1" b="$2"
    [ "$a" -le "$b" ] && echo "$a" || echo "$b"
}

ask_existing_dir_var() {  # 统一询问一个必须存在的目录，支持相对工作目录
    local var_name="$1" prompt="$2" default_dir="$3" input p abs
    read -r -p "$prompt" input
    input=$(normalize_path "$input")
    if [ -z "$input" ]; then
        p="$default_dir"
    else
        p=$(rel_to_workdir "$input" "$WORK_DIR_ABS")
    fi
    abs=$(abs_dir "$p") || { echo "错误: 找不到目录: $p"; return 1; }
    printf -v "$var_name" '%s' "$abs"
}

ask_output_dir_var() {  # 统一询问输出目录；不存在则自动创建
    local var_name="$1" prompt="$2" default_dir="$3" input p abs
    read -r -p "$prompt" input
    input=$(normalize_path "$input")
    if [ -z "$input" ]; then
        p="$default_dir"
    else
        p=$(rel_to_workdir "$input" "$WORK_DIR_ABS")
    fi
    mkdir -p "$p" || { echo "错误: 无法创建输出目录: $p"; return 1; }
    abs=$(abs_dir "$p") || { echo "错误: 无法进入输出目录: $p"; return 1; }
    printf -v "$var_name" '%s' "$abs"
}

ask_parallel_jobs() {  # 所有并行步骤共用一次询问，避免重复询问 MAX_JOBS
    local need_pdbqt="$1" need_vina="$2" total default_jobs input label
    total=$(safe_cpu_threads)
    if [ "$need_pdbqt" -eq 1 ] && [ "$need_vina" -eq 0 ]; then
        default_jobs=$(min_int "$total" 8)
        label="PDBQT 转换最大并行任务数 [默认: $default_jobs，已检测到 $total 个 CPU 线程，建议 ≤ 8]: "
    elif [ "$need_pdbqt" -eq 1 ] && [ "$need_vina" -eq 1 ]; then
        default_jobs=$(min_int "$total" 8)
        label="最大并行任务数[默认: $default_jobs，已检测到 $total 个 CPU 线程，PDBQT 建议 ≤ 8]: "
    else
        default_jobs="$total"
        label="Vina 最大并行任务数 MAX_JOBS [默认: $default_jobs，已检测到 $total 个 CPU 线程]: "
    fi
    read -r -p "$label" input
    [ -z "$input" ] && input="$default_jobs"
    if ! [[ "$input" =~ ^[0-9]+$ ]] || [ "$input" -lt 1 ]; then
        echo "请输入大于等于 1 的整数。"
        return 1
    fi
    COMMON_MAX_JOBS="$input"
    PDBQT_MAX_JOBS="$input"
    VINA_MAX_JOBS="$input"
    TOTAL_CPU_THREADS="$total"
}

detect_pymol_cmd() {  # 自动识别 PyMOL 可执行文件
    if command -v pymol >/dev/null 2>&1; then command -v pymol; return 0; fi
    local candidates=()
    if [ "$SYSTEM_TYPE" = "Windows" ]; then
        candidates=(
            "/c/Program Files/PyMOL/PyMOLWin.exe"
            "/c/Program Files/Schrodinger/PyMOL2/PyMOLWin.exe"
            "/c/Program Files (x86)/PyMOL/PyMOLWin.exe"
            "/d/Program Files/PyMOL/PyMOLWin.exe"
            "/d/Program Files/Schrodinger/PyMOL2/PyMOLWin.exe"
        )
    else
        candidates=(/usr/bin/pymol /usr/local/bin/pymol /opt/pymol/pymol)
    fi
    for f in "${candidates[@]}"; do
        [ -f "$f" ] && echo "$f" && return 0
    done
    return 1
}

collect_pymol_cmd() {  # 只在参数收集阶段获取 PyMOL 命令
    PYMOL_CMD=$(detect_pymol_cmd)
    if [ -n "$PYMOL_CMD" ]; then
        echo "已找到 PyMOL: $PYMOL_CMD"
    else
        echo "未找到 PyMOL。请输入路径或命令，例如 /c/Program Files/PyMOL/PyMOLWin.exe"
        read -r -p "PyMOL: " PYMOL_CMD
        PYMOL_CMD=$(normalize_path "$PYMOL_CMD")
    fi
    command -v "$PYMOL_CMD" >/dev/null 2>&1 || [ -f "$PYMOL_CMD" ] || { echo "错误: 找不到 PyMOL: $PYMOL_CMD"; return 1; }
}

find_prepare_script() {  # 兼容 Windows 与 Linux 两种 MGLTools 目录结构
    local d="$1"
    [ -f "$d/Lib/site-packages/AutoDockTools/Utilities24/prepare_ligand4.py" ] && echo "$d/Lib/site-packages/AutoDockTools/Utilities24/prepare_ligand4.py" && return 0
    [ -f "$d/MGLToolsPckgs/AutoDockTools/Utilities24/prepare_ligand4.py" ] && echo "$d/MGLToolsPckgs/AutoDockTools/Utilities24/prepare_ligand4.py" && return 0
    return 1
}

detect_mgltools_dir() {  # 自动搜索 MGLTools 根目录，不固定版本号
    local candidates=()
    if [ "$SYSTEM_TYPE" = "Linux" ]; then
        candidates=(
            "$HOME"/Applications/Autodock/mgltools* "$HOME"/Applications/Autodock/MGLTools*
            "$HOME"/Applications/mgltools* "$HOME"/Applications/MGLTools*
            "$HOME"/mgltools* "$HOME"/MGLTools*
            /opt/mgltools* /opt/MGLTools* /usr/local/mgltools* /usr/local/MGLTools*
        )
    elif [ "$SYSTEM_TYPE" = "Windows" ]; then
        candidates=(
            /c/MGLTools* /c/mgltools*
            "/c/Program Files"/MGLTools* "/c/Program Files"/mgltools*
            "/c/Program Files (x86)"/MGLTools* "/c/Program Files (x86)"/mgltools*
            /d/MGLTools* /d/mgltools*
            "/d/Program Files"/MGLTools* "/d/Program Files"/mgltools*
            "/d/Program Files (x86)"/MGLTools* "/d/Program Files (x86)"/mgltools*
        )
    fi
    for d in "${candidates[@]}"; do
        [ -d "$d" ] && find_prepare_script "$d" >/dev/null 2>&1 && echo "$d" && return 0
    done
    return 1
}

collect_mgltools() {  # 只在参数收集阶段获取 MGLTools 根目录、prepare_ligand4.py 和自带 Python
    MGLTOOLS_DIR=$(detect_mgltools_dir)
    if [ -n "$MGLTOOLS_DIR" ]; then
        echo "已找到 MGLTools: $MGLTOOLS_DIR"
    else
        echo "未识别 MGLTools，请输入安装目录，例如 C:\\Program Files (x86)\\MGLTools-x.x.x"
        read -r -p "MGLTools: " MGLTOOLS_DIR
        MGLTOOLS_DIR=$(normalize_path "$MGLTOOLS_DIR")
    fi
    [ -d "$MGLTOOLS_DIR" ] || { echo "错误: MGLTools 目录不存在: $MGLTOOLS_DIR"; return 1; }
    PREP_SCRIPT=$(find_prepare_script "$MGLTOOLS_DIR")
    [ -z "$PREP_SCRIPT" ] && { echo "错误: 找不到 prepare_ligand4.py"; return 1; }
    unset MGL_PYTHON
    if [ "$SYSTEM_TYPE" = "Windows" ]; then
        [ -f "$MGLTOOLS_DIR/python.exe" ] && MGL_PYTHON="$MGLTOOLS_DIR/python.exe"
        [ -z "${MGL_PYTHON:-}" ] && [ -f "$MGLTOOLS_DIR/bin/python.exe" ] && MGL_PYTHON="$MGLTOOLS_DIR/bin/python.exe"
    else
        [ -f "$MGLTOOLS_DIR/bin/pythonsh" ] && MGL_PYTHON="$MGLTOOLS_DIR/bin/pythonsh"
        [ -z "${MGL_PYTHON:-}" ] && [ -f "$MGLTOOLS_DIR/pythonsh" ] && MGL_PYTHON="$MGLTOOLS_DIR/pythonsh"
        [ -z "${MGL_PYTHON:-}" ] && [ -f "$MGLTOOLS_DIR/bin/python" ] && MGL_PYTHON="$MGLTOOLS_DIR/bin/python"
    fi
    [ -z "${MGL_PYTHON:-}" ] && { echo "错误: 找不到 MGLTools 自带 Python"; return 1; }
    return 0
}

detect_vina_cmd() {  # Vina 默认放在工作目录：Windows 为 vina.exe，Linux 为 vina
    local cmd=""
    if [ "$SYSTEM_TYPE" = "Windows" ]; then
        [ -f "$WORK_DIR_ABS/vina.exe" ] && cmd="./vina.exe"
    else
        [ -f "$WORK_DIR_ABS/vina" ] && cmd="./vina"
    fi
    [ -z "$cmd" ] && [ -f "$WORK_DIR_ABS/vina.exe" ] && cmd="./vina.exe"
    [ -z "$cmd" ] && [ -f "$WORK_DIR_ABS/vina" ] && cmd="./vina"
    echo "$cmd"
}

collect_vina_cmd() {  # 只在参数收集阶段获取 Vina 命令
    VINA_CMD=$(detect_vina_cmd)
    if [ -n "$VINA_CMD" ]; then
        echo "已找到 Vina: $VINA_CMD"
    else
        echo "未找到 Vina。请输入 vina 或 vina.exe 的路径/命令；输入 vina 将使用环境变量中的命令"
        read -r -p "Vina: " VINA_CMD
        VINA_CMD=$(normalize_path "$VINA_CMD")
        if [ -f "$WORK_DIR_ABS/$VINA_CMD" ]; then
            VINA_CMD="./$VINA_CMD"
        fi
    fi
    command -v "$VINA_CMD" >/dev/null 2>&1 || [ -f "$WORK_DIR_ABS/${VINA_CMD#./}" ] || [ -f "$VINA_CMD" ] || { echo "错误: 找不到 Vina: $VINA_CMD"; return 1; }
}

ask_yes_no_var() {  # 统一询问 yes/no，结果写入变量: 1/0
    local var_name="$1" prompt="$2" default_value="$3" input
    read -r -p "$prompt" input
    input=$(echo "$input" | tr 'A-Z' 'a-z' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$input" ]; then
        input=$(echo "$default_value" | tr 'A-Z' 'a-z')
    fi
    case "$input" in
        y|yes|1|true|是|运行|需要) printf -v "$var_name" '%s' "1" ;;
        n|no|0|false|否|不运行|不需要) printf -v "$var_name" '%s' "0" ;;
        *) echo "请输入 y 或 n。"; return 1 ;;
    esac
}

detect_chimerax_cmd() {  # 自动查找 Windows/Linux 下的 ChimeraX 可执行文件
    local cmd f root found

    # 1) 优先使用 PATH 中的命令
    for cmd in chimerax ChimeraX ChimeraX.exe; do
        if command -v "$cmd" >/dev/null 2>&1; then
            command -v "$cmd"
            return 0
        fi
    done

    local candidates=()

    # 2) ChimeraX常见安装位置 + 版本号目录
    if [ "$SYSTEM_TYPE" = "Windows" ]; then
        local drives=(/c /d /e)
        for root in "${drives[@]}"; do
            candidates+=(
                "$root/Program Files/ChimeraX/bin/ChimeraX.exe"
                "$root/Program Files"/ChimeraX*/bin/ChimeraX.exe
                "$root/Program Files"/"UCSF ChimeraX"*/bin/ChimeraX.exe
                "$root/Program Files (x86)/ChimeraX/bin/ChimeraX.exe"
                "$root/Program Files (x86)"/ChimeraX*/bin/ChimeraX.exe
                "$root/Program Files (x86)"/"UCSF ChimeraX"*/bin/ChimeraX.exe
            )
        done

        # Git Bash 下尝试读取 Windows 环境变量中的安装根目录
        if command -v cygpath >/dev/null 2>&1; then
            local win_dir unix_dir
            for win_dir in "${ProgramFiles:-}" "${PROGRAMFILES:-}" "${ProgramW6432:-}" "${LOCALAPPDATA:-}"; do
                [ -z "$win_dir" ] && continue
                unix_dir=$(cygpath -u "$win_dir" 2>/dev/null || true)
                [ -z "$unix_dir" ] && continue
                candidates+=(
                    "$unix_dir/ChimeraX/bin/ChimeraX.exe"
                    "$unix_dir"/ChimeraX*/bin/ChimeraX.exe
                    "$unix_dir"/"UCSF ChimeraX"*/bin/ChimeraX.exe
                    "$unix_dir/Programs/ChimeraX/bin/ChimeraX.exe"
                    "$unix_dir/Programs"/ChimeraX*/bin/ChimeraX.exe
                    "$unix_dir/Programs"/"UCSF ChimeraX"*/bin/ChimeraX.exe
                )
            done
        fi
    else
        candidates=(
            /usr/bin/chimerax /usr/local/bin/chimerax /snap/bin/chimerax
            /usr/bin/ChimeraX /usr/local/bin/ChimeraX
            /usr/lib/ucsf-chimerax/bin/ChimeraX
            /opt/ChimeraX/bin/ChimeraX
            /opt/ChimeraX*/bin/ChimeraX /opt/chimerax*/bin/chimerax
            "$HOME"/Applications/ChimeraX*/bin/ChimeraX
            "$HOME"/Applications/chimerax*/bin/chimerax
            "$HOME"/.local/bin/chimerax
            "$HOME"/Downloads/ChimeraX*.AppImage "$HOME"/Downloads/chimerax*.AppImage
        )
    fi

    for f in "${candidates[@]}"; do
        [ -f "$f" ] && echo "$f" && return 0
    done

    # 3) 轻量级兜底搜索：仅扫描常见安装根目录，避免全盘搜索过慢
    local search_roots=()
    if [ "$SYSTEM_TYPE" = "Windows" ]; then
        for root in /c/Program\ Files /c/Program\ Files\ \(x86\) /d/Program\ Files /d/Program\ Files\ \(x86\) /e/Program\ Files /e/Program\ Files\ \(x86\); do
            [ -d "$root" ] && search_roots+=("$root")
        done
        found=""
        if [ "${#search_roots[@]}" -gt 0 ]; then
            found=$(find "${search_roots[@]}" -maxdepth 5 -type f \( -iname "ChimeraX.exe" -o -iname "chimerax.exe" \) 2>/dev/null | sort -Vr | head -n 1)
        fi
    else
        for root in /opt /usr/local /usr/lib/ucsf-chimerax "$HOME/Applications" "$HOME/.local"; do
            [ -d "$root" ] && search_roots+=("$root")
        done
        found=""
        if [ "${#search_roots[@]}" -gt 0 ]; then
            found=$(find "${search_roots[@]}" -maxdepth 5 -type f \( -iname "chimerax" -o -iname "ChimeraX" -o -iname "ChimeraX*.AppImage" \) 2>/dev/null | sort -Vr | head -n 1)
        fi
    fi

    [ -n "$found" ] && echo "$found" && return 0
    return 1
}

collect_chimerax_cmd() {  # 只在参数收集阶段获取 ChimeraX 命令
    CHIMERAX_CMD=$(detect_chimerax_cmd)
    if [ -n "$CHIMERAX_CMD" ]; then
        echo "已找到 ChimeraX: $CHIMERAX_CMD"
    else
        echo "未找到 ChimeraX。请输入可执行文件路径或命令。"
        if [ "$SYSTEM_TYPE" = "Windows" ]; then
            echo "示例: /c/Program Files/ChimeraX 1.12/bin/ChimeraX.exe"
        else
            echo "示例: /usr/bin/chimerax 或 /opt/ChimeraX/bin/ChimeraX"
        fi
        read -r -p "ChimeraX 路径: " CHIMERAX_CMD
        CHIMERAX_CMD=$(normalize_path "$CHIMERAX_CMD")
    fi
    command -v "$CHIMERAX_CMD" >/dev/null 2>&1 || [ -f "$CHIMERAX_CMD" ] || { echo "无法继续：找不到 ChimeraX: $CHIMERAX_CMD"; return 1; }
}

path_relative_or_absolute_to_workdir() {  # 文件路径可不存在；相对路径默认相对于工作目录
    local p="$1"
    p=$(normalize_path "$p")
    [ -z "$p" ] && echo "" && return
    [[ "$p" = /* ]] && echo "$p" && return
    echo "$WORK_DIR_ABS/$p"
}

collect_chimerax_inputs() {  # 获取 ChimeraX 分析所需参数；正式运行前一次性完成
    collect_chimerax_cmd || return 1

    local default_script input script_abs default_txt out_abs out_parent
    default_script="$SCRIPT_DIR/chimerax_vina_hbond_batch_pipeline.py"
    [ ! -f "$default_script" ] && default_script="$WORK_DIR_ABS/chimerax_vina_hbond_batch_pipeline.py"

    read -r -p "ChimeraX 分析脚本 [默认: $default_script]: " input
    input=$(normalize_path "$input")
    [ -z "$input" ] && input="$default_script"
    script_abs=$(path_relative_or_absolute_to_workdir "$input")
    [ -f "$script_abs" ] || { echo "错误: 找不到 ChimeraX 分析脚本: $script_abs"; return 1; }
    CHIMERAX_SCRIPT_ABS="$script_abs"

    read -r -p "受体名称（多个用逗号分隔；留空自动检测 receptor 目录中的 receptor.pdbqt）: " CHIMERAX_RECEPTORS
    CHIMERAX_RECEPTORS=$(echo "$CHIMERAX_RECEPTORS" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    default_txt="$DOCK_OUT_DIR_ABS/vina_hbond_summary_with_progress.txt"
    read -r -p "ChimeraX 结果 TXT [默认: $default_txt；输入目录时自动追加文件名]: " input
    input=$(normalize_path "$input")
    [ -z "$input" ] && input="$default_txt"
    out_abs=$(path_relative_or_absolute_to_workdir "$input")
    if [ -d "$out_abs" ]; then
        out_abs="$out_abs/vina_hbond_summary_with_progress.txt"
    fi
    out_parent=$(dirname "$out_abs")
    mkdir -p "$out_parent" || { echo "错误: 无法创建ChimeraX输出目录: $out_parent"; return 1; }
    CHIMERAX_OUTPUT_TXT_ABS="$out_abs"

    ask_yes_no_var CHIMERAX_RELAX_HBOND "使用宽松氢键判定标准（relax=true）？[Y/n]: " "y" || return 1
    ask_yes_no_var CHIMERAX_PRINT_EACH_POSE "在 ChimeraX Log 中显示每个 pose 的进度？[Y/n]: " "y" || return 1
    ask_yes_no_var CHIMERAX_KEEP_DETAILS "保留每个 pose 的氢键明细文件？[y/N]: " "n" || return 1
}

ask_work_dir_once() {  # 工作目录只询问一次
    local input
    read -r -p "工作目录 [默认: 当前目录]: " input
    input=$(normalize_path "$input")
    [ -z "$input" ] && input="$PWD"
    WORK_DIR_ABS=$(abs_dir "$input") || { echo "错误: 找不到工作目录: $input"; return 1; }
}

collect_all_inputs() {  # 所有需要询问的内容集中放在正式运行之前
    local need_pymol=0 need_mgl=0 need_vina=0 need_pdbqt=0 need_chimerax=0 can_run_chimerax_after=0
    RUN_CHIMERAX_AFTER=0
    case "$choice" in
        1) need_pymol=1 ;;
        2) need_mgl=1; need_pdbqt=1 ;;
        3) need_vina=1; can_run_chimerax_after=1 ;;
        4) need_pymol=1; need_mgl=1; need_vina=1; need_pdbqt=1; can_run_chimerax_after=1 ;;
        5) need_chimerax=1 ;;
        *) echo "输入无效"; return 1 ;;
    esac

    bar
    echo "开始设置。请先确认本次流程需要的选项。"
    echo "设置完成后，将开始执行任务。"
    bar

    ask_work_dir_once || return 1

    if [ "$choice" = "1" ]; then
        ask_existing_dir_var LIGAND_DIR_ABS "Ligand 目录 [默认: 工作目录/ligand]: " "$WORK_DIR_ABS/ligand" || return 1
        PDB_INPUT_DIR_ABS="$LIGAND_DIR_ABS"
        SDF_INPUT_DIR_ABS="$LIGAND_DIR_ABS"
        ask_output_dir_var PDB_OUT_DIR_ABS "PDB 输出目录 [默认: $LIGAND_DIR_ABS]: " "$LIGAND_DIR_ABS" || return 1
    elif [ "$choice" = "2" ]; then
        ask_existing_dir_var LIGAND_DIR_ABS "Ligand 目录 [默认: 工作目录/ligand]: " "$WORK_DIR_ABS/ligand" || return 1
        PDB_INPUT_DIR_ABS="$LIGAND_DIR_ABS"
        ask_output_dir_var PDBQT_OUT_DIR_ABS "PDBQT 输出目录 [默认: $LIGAND_DIR_ABS]: " "$LIGAND_DIR_ABS" || return 1
    elif [ "$choice" = "3" ]; then
        ask_existing_dir_var RECEPTOR_DIR_ABS "Receptor 目录 [默认: 工作目录/receptor]: " "$WORK_DIR_ABS/receptor" || return 1
        ask_existing_dir_var VINA_LIGAND_DIR_ABS "配体 PDBQT 目录 [默认: 工作目录/ligand]: " "$WORK_DIR_ABS/ligand" || return 1
        ask_existing_dir_var CONFIG_DIR_ABS "配置文件目录 [默认: 工作目录/dockingConfigs]: " "$WORK_DIR_ABS/dockingConfigs" || return 1
        ask_output_dir_var DOCK_OUT_DIR_ABS "Vina 结果输出目录 [默认: 工作目录/Docking_Results_Parallel]: " "$WORK_DIR_ABS/Docking_Results_Parallel" || return 1
    elif [ "$choice" = "4" ]; then
        ask_existing_dir_var LIGAND_DIR_ABS "Ligand 原始目录 [默认: 工作目录/ligand]: " "$WORK_DIR_ABS/ligand" || return 1
        SDF_INPUT_DIR_ABS="$LIGAND_DIR_ABS"
        ask_output_dir_var PDB_OUT_DIR_ABS "PDB 输出目录 [默认: $LIGAND_DIR_ABS]: " "$LIGAND_DIR_ABS" || return 1
        PDB_INPUT_DIR_ABS="$PDB_OUT_DIR_ABS"
        ask_output_dir_var PDBQT_OUT_DIR_ABS "PDBQT 输出目录 [默认: $PDB_OUT_DIR_ABS]: " "$PDB_OUT_DIR_ABS" || return 1
        VINA_LIGAND_DIR_ABS="$PDBQT_OUT_DIR_ABS"
        echo "Vina配体目录将使用PDBQT输出目录: $VINA_LIGAND_DIR_ABS"
        ask_existing_dir_var RECEPTOR_DIR_ABS "Receptor 目录 [默认: 工作目录/receptor]: " "$WORK_DIR_ABS/receptor" || return 1
        ask_existing_dir_var CONFIG_DIR_ABS "配置文件目录 [默认: 工作目录/dockingConfigs]: " "$WORK_DIR_ABS/dockingConfigs" || return 1
        ask_output_dir_var DOCK_OUT_DIR_ABS "Vina 结果输出目录 [默认: 工作目录/Docking_Results_Parallel]: " "$WORK_DIR_ABS/Docking_Results_Parallel" || return 1
    elif [ "$choice" = "5" ]; then
        ask_existing_dir_var RECEPTOR_DIR_ABS "Receptor 目录 [默认: 工作目录/receptor]: " "$WORK_DIR_ABS/receptor" || return 1
        ask_existing_dir_var DOCK_OUT_DIR_ABS "Vina 结果目录 [默认: 工作目录/Docking_Results_Parallel]: " "$WORK_DIR_ABS/Docking_Results_Parallel" || return 1
    fi

    if [ "$can_run_chimerax_after" -eq 1 ]; then
        ask_yes_no_var RUN_CHIMERAX_AFTER "Vina 对接完成后，继续运行 ChimeraX 氢键分析？[Y/n]（默认Y）: " "y" || return 1
        [ "$RUN_CHIMERAX_AFTER" -eq 1 ] && need_chimerax=1
    fi

    if [ "$need_pymol" -eq 1 ]; then
        collect_pymol_cmd || return 1
        echo "PyMOL 运行模式：1) GUI（默认）  2) No-GUI"
        read -r -p "选择 PyMOL 运行模式 [默认: 1]: " PYMOL_MODE
        [ -z "$PYMOL_MODE" ] && PYMOL_MODE=1
        if [ "$PYMOL_MODE" != "1" ] && [ "$PYMOL_MODE" != "2" ]; then
            echo "错误: PyMOL 运行模式只能输入 1 或 2"
            return 1
        fi
    fi

    if [ "$need_mgl" -eq 1 ]; then
        collect_mgltools || return 1
    fi

    if [ "$need_vina" -eq 1 ]; then
        collect_vina_cmd || return 1
    fi

    if [ "$need_pdbqt" -eq 1 ] || [ "$need_vina" -eq 1 ]; then
        ask_parallel_jobs "$need_pdbqt" "$need_vina" || return 1
    fi

    if [ "$need_chimerax" -eq 1 ]; then
        collect_chimerax_inputs || return 1
    fi

    bar
    echo "设置完成"
    echo "工作目录: $WORK_DIR_ABS"
    [ -n "${SDF_INPUT_DIR_ABS:-}" ] && echo "SDF目录: $SDF_INPUT_DIR_ABS"
    [ -n "${PDB_INPUT_DIR_ABS:-}" ] && echo "PDB输入目录: $PDB_INPUT_DIR_ABS"
    [ -n "${PDB_OUT_DIR_ABS:-}" ] && echo "PDB输出目录: $PDB_OUT_DIR_ABS"
    [ -n "${PDBQT_OUT_DIR_ABS:-}" ] && echo "PDBQT输出目录: $PDBQT_OUT_DIR_ABS"
    [ -n "${RECEPTOR_DIR_ABS:-}" ] && echo "受体目录: $RECEPTOR_DIR_ABS"
    [ -n "${VINA_LIGAND_DIR_ABS:-}" ] && echo "Vina配体目录: $VINA_LIGAND_DIR_ABS"
    [ -n "${CONFIG_DIR_ABS:-}" ] && echo "配置目录: $CONFIG_DIR_ABS"
    [ -n "${DOCK_OUT_DIR_ABS:-}" ] && echo "Vina结果输出目录: $DOCK_OUT_DIR_ABS"
    [ -n "${COMMON_MAX_JOBS:-}" ] && echo "最大并行任务数: $COMMON_MAX_JOBS"
    if [ "${need_chimerax:-0}" -eq 1 ]; then
        echo "ChimeraX分析: 是"
        echo "ChimeraX程序: $CHIMERAX_CMD"
        echo "ChimeraX脚本: $CHIMERAX_SCRIPT_ABS"
        echo "ChimeraX结果TXT: $CHIMERAX_OUTPUT_TXT_ABS"
        [ -n "${CHIMERAX_RECEPTORS:-}" ] && echo "ChimeraX指定受体: $CHIMERAX_RECEPTORS" || echo "ChimeraX指定受体: 自动检测"
    fi
    bar
}

step_sdf_to_pdb() {  # Step 1: 用 PyMOL 将 ligand 目录中的 SDF 批量转成 PDB
    shopt -s nullglob
    local sdf_files=("$SDF_INPUT_DIR_ABS"/*.sdf)
    local n=${#sdf_files[@]}
    [ "$n" -eq 0 ] && { echo "错误: 在 $SDF_INPUT_DIR_ABS 中没有找到 .sdf 文件"; return 1; }
    local py_script="$WORK_DIR_ABS/_pymol_sdf_to_pdb_temp.py"
    local lig_py out_py mode_text
    lig_py=$(to_native_path "$SDF_INPUT_DIR_ABS")
    out_py=$(to_native_path "$PDB_OUT_DIR_ABS")
    cat > "$py_script" <<PYEOF
# -*- coding: utf-8 -*-
import glob, os, sys
from pymol import cmd

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

ligand_dir = r'''$lig_py'''
out_dir = r'''$out_py'''

def norm_path(x):
    return x.replace('\\\\', '/')

def main():
    os.makedirs(out_dir, exist_ok=True)
    files = sorted(glob.glob(os.path.join(ligand_dir, '*.sdf')))
    if not files:
        print('No SDF files found.')
        cmd.quit()
        return
    print('Found %d SDF files. Start converting...' % len(files))
    ok = 0
    fail = 0
    for i, sdf in enumerate(files, 1):
        name = os.path.splitext(os.path.basename(sdf))[0]
        obj = cmd.get_unused_name('lig_%04d' % i)
        out = norm_path(os.path.join(out_dir, name + '.pdb'))
        try:
            print('[%d/%d] Converting: %s' % (i, len(files), os.path.basename(sdf)))
            cmd.load(sdf, obj)
            cmd.save(out, obj)
            print('    [OK] Saved: %s' % out)
            ok += 1
        except Exception as e:
            print('    [FAILED] %s | %s' % (os.path.basename(sdf), str(e)))
            fail += 1
        finally:
            cmd.delete(obj)
    print('Batch conversion finished. Success: %d, Failed: %d' % (ok, fail))
    cmd.quit()

main()
PYEOF
    if [ "$PYMOL_MODE" = "2" ]; then
        PYMOL_ARGS=(-cq "$py_script")
        mode_text="No-GUI"
    else
        PYMOL_ARGS=(-r "$py_script")
        mode_text="GUI"
    fi
    bar
    echo "SDF目录: $SDF_INPUT_DIR_ABS"
    echo "输出目录: $PDB_OUT_DIR_ABS"
    echo "SDF数量: $n"
    echo "PyMOL模式: $mode_text"
    bar
    "$PYMOL_CMD" "${PYMOL_ARGS[@]}"
}

step_pdb_to_pdbqt() {  # Step 2: 用 MGLTools 将 PDB 批量转成 PDBQT
    cd "$PDB_INPUT_DIR_ABS" || return 1
    shopt -s nullglob
    local pdb_files=(*.pdb)
    local n=${#pdb_files[@]}
    [ "$n" -eq 0 ] && { echo "错误: 在 $PDB_INPUT_DIR_ABS 中没有找到 .pdb 文件"; return 1; }
    local log_dir="$PDBQT_OUT_DIR_ABS/_prep_logs"
    local failed_list="$log_dir/_failed_files.txt"
    local prep_tool max_jobs
    mkdir -p "$log_dir"
    : > "$failed_list"
    prep_tool=$(to_native_path "$PREP_SCRIPT")
    max_jobs="$PDBQT_MAX_JOBS"

    run_prep_one() {  # 单个 PDB→PDBQT；Windows 下输入文件只传文件名更稳定
        local pdb="$1"
        local name="${pdb%.pdb}"
        local out_mgl log
        out_mgl=$(to_native_path "$PDBQT_OUT_DIR_ABS/${name}.pdbqt")
        log="$log_dir/${name}_prep.log"
        (cd "$PDB_INPUT_DIR_ABS" && "$MGL_PYTHON" "$prep_tool" -l "$pdb" -o "$out_mgl" -A hydrogens > "$log" 2>&1)
        if [ "$?" -eq 0 ]; then
            echo "[OK] ${name}.pdbqt"
        else
            echo "[FAILED] $pdb | log: $log"
            echo "$pdb" >> "$failed_list"
        fi
    }

    bar
    echo "PDB目录: $PDB_INPUT_DIR_ABS"
    echo "输出目录: $PDBQT_OUT_DIR_ABS"
    echo "PDB数量: $n"
    echo "并行数: $max_jobs"
    echo "日志目录: $log_dir"
    bar
    for pdb in "${pdb_files[@]}"; do
        run_prep_one "$pdb" &
        while [ "$(jobs -rp | wc -l)" -ge "$max_jobs" ]; do sleep 0.3; done  # 控制同时运行的 MGLTools 进程数
    done
    wait
    local fail_count
    fail_count=$(wc -l < "$failed_list" | tr -d ' ')
    echo "PDBQT转换结束: 成功 $((n - fail_count)) / $n"
    [ "$fail_count" -gt 0 ] && echo "失败列表: $failed_list"
    return 0
}

step_vina_docking() {
    cd "$WORK_DIR_ABS" || return 1

    local output_dir="$DOCK_OUT_DIR_ABS"
    local config_dir="$CONFIG_DIR_ABS"
    local receptor_dir="$RECEPTOR_DIR_ABS"
    local ligand_dir="$VINA_LIGAND_DIR_ABS"
    local max_jobs="$VINA_MAX_JOBS"
    local total_cpu_threads="$TOTAL_CPU_THREADS"

    if ! [[ "$max_jobs" =~ ^[0-9]+$ ]] || [ "$max_jobs" -lt 1 ]; then
        echo "错误: MAX_JOBS 必须是大于等于 1 的整数。"
        return 1
    fi

    if ! command -v "$VINA_CMD" >/dev/null 2>&1 && [ ! -f "$WORK_DIR_ABS/${VINA_CMD#./}" ] && [ ! -f "$VINA_CMD" ]; then
        echo "错误: 未找到 Vina 程序: $VINA_CMD"
        echo "请确认 vina 或 vina.exe 与脚本位于同一目录，或在参数预设阶段输入正确路径。"
        return 1
    fi

    if [ "$SYSTEM_TYPE" = "Linux" ] && [ -f "$WORK_DIR_ABS/${VINA_CMD#./}" ]; then
        chmod +x "$WORK_DIR_ABS/${VINA_CMD#./}" 2>/dev/null
    elif [ "$SYSTEM_TYPE" = "Linux" ] && [ -f "$VINA_CMD" ]; then
        chmod +x "$VINA_CMD" 2>/dev/null
    fi

    mkdir -p "$output_dir"

    echo "=================================================="
    echo "开始批量对接任务"
    echo "当前系统: $SYSTEM_TYPE"
    echo "Vina 程序路径: $VINA_CMD"
    echo "CPU 总线程数: $total_cpu_threads"
    echo "最大并发任务数 MAX_JOBS: $max_jobs"
    echo "结果输出目录: $output_dir"
    echo "=================================================="

    shopt -s nullglob
    local receptor_files=("$receptor_dir"/*.pdbqt)
    local ligand_files=("$ligand_dir"/*.pdbqt)
    [ "${#receptor_files[@]}" -eq 0 ] && { echo "错误: 未在 $receptor_dir 中找到任何 .pdbqt 受体文件。"; return 1; }
    [ "${#ligand_files[@]}" -eq 0 ] && { echo "错误: 未在 $ligand_dir 中找到任何 .pdbqt 配体文件。"; return 1; }

    local receptor_file rec_name config_file ligand_file lig_name
    for receptor_file in "${receptor_files[@]}"; do
        rec_name=$(basename "$receptor_file" .pdbqt)

        echo "========================================="
        echo "正在处理受体: $rec_name"

        config_file="${config_dir}/${rec_name}_vinaConfig.txt"

        if [ ! -f "$config_file" ]; then
            echo "警告: 未找到该受体对应的配置文件: $config_file"
            echo "跳过该受体..."
            continue
        fi

        for ligand_file in "${ligand_files[@]}"; do
            lig_name=$(basename "$ligand_file" .pdbqt)
            mkdir -p "${output_dir}/${lig_name}"

            echo "    >>> 提交任务: 受体 $rec_name | 配体 $lig_name"

            (
                out_pdbqt="${output_dir}/${lig_name}/${rec_name}_${lig_name}_out.pdbqt"
                log_file="${output_dir}/${lig_name}/${rec_name}_${lig_name}_log.txt"

                # 临时配置文件，加入 $$ 和 $RANDOM 避免并行冲突
                temp_config="${config_dir}/temp_${rec_name}_${lig_name}_$$_${RANDOM}_config.txt"

                ligand_for_config=$(to_native_path "$ligand_file")
                receptor_for_vina=$(to_native_path "$receptor_file")
                out_for_vina=$(to_native_path "$out_pdbqt")
                temp_config_for_vina=$(to_native_path "$temp_config")

                # 替换配置文件中的 ligand 路径
                sed "s#ligand[[:space:]]*=.*#ligand = $ligand_for_config#g" "$config_file" > "$temp_config"

                # 运行 Vina；只控制并发任务数，不设置 vina --cpu
                "$VINA_CMD" \
                    --config "$temp_config_for_vina" \
                    --receptor "$receptor_for_vina" \
                    --out "$out_for_vina" \
                    > "$log_file" 2>&1

                exit_code=$?

                # 清理临时配置文件
                rm -f "$temp_config"

                if [ "$exit_code" -eq 0 ]; then
                    echo "    [✔] 任务完成: ${rec_name}_${lig_name}"
                else
                    echo "    [×] 任务失败: ${rec_name}_${lig_name}，请查看日志: $log_file"
                fi

            ) &

            # 控制后台并发任务数
            while [ "$(jobs -rp | wc -l)" -ge "$max_jobs" ]; do
                sleep 1
            done
        done
    done

    echo "========================================="
    echo "所有任务已提交，等待最后几批任务完成..."
    wait

    echo "========================================="
    echo "所有批量对接任务均已结束！"
    echo "全部结果已归档至: $output_dir"

    return 0
}

step_chimerax_analysis() {  # Step 4: 直接读取 receptor 目录与 Vina 输出目录，运行 ChimeraX 氢键分析
    cd "$WORK_DIR_ABS" || return 1

    [ -n "${CHIMERAX_CMD:-}" ] || { echo "错误: 未设置 ChimeraX 程序路径"; return 1; }
    [ -n "${CHIMERAX_SCRIPT_ABS:-}" ] || { echo "错误: 未设置 ChimeraX 分析脚本路径"; return 1; }
    [ -f "$CHIMERAX_SCRIPT_ABS" ] || { echo "错误: 找不到 ChimeraX 分析脚本: $CHIMERAX_SCRIPT_ABS"; return 1; }
    [ -d "$RECEPTOR_DIR_ABS" ] || { echo "错误: receptor 目录不存在: $RECEPTOR_DIR_ABS"; return 1; }
    [ -d "$DOCK_OUT_DIR_ABS" ] || { echo "错误: Vina结果目录不存在: $DOCK_OUT_DIR_ABS"; return 1; }

    local cmd_to_run script_for_chimerax
    cmd_to_run="$CHIMERAX_CMD"
    script_for_chimerax=$(to_native_path "$CHIMERAX_SCRIPT_ABS")

    export CHIMERAX_WORK_DIR="$(to_native_path "$WORK_DIR_ABS")"
    export CHIMERAX_RECEPTOR_DIR="$(to_native_path "$RECEPTOR_DIR_ABS")"
    export CHIMERAX_DOCKING_DIR="$(to_native_path "$DOCK_OUT_DIR_ABS")"
    export CHIMERAX_OUTPUT_TXT="$(to_native_path "$CHIMERAX_OUTPUT_TXT_ABS")"
    export CHIMERAX_RECEPTORS="${CHIMERAX_RECEPTORS:-}"
    export CHIMERAX_RELAX_HBOND_CRITERIA="${CHIMERAX_RELAX_HBOND:-1}"
    export CHIMERAX_PRINT_EACH_POSE="${CHIMERAX_PRINT_EACH_POSE:-1}"
    export CHIMERAX_KEEP_HBOND_DETAIL_FILES="${CHIMERAX_KEEP_DETAILS:-0}"

    bar
    echo "开始 ChimeraX 氢键分析"
    echo "受体目录: $RECEPTOR_DIR_ABS"
    echo "Vina结果目录: $DOCK_OUT_DIR_ABS"
    echo "结果TXT: $CHIMERAX_OUTPUT_TXT_ABS"
    bar

    "$cmd_to_run" --nogui --exit --script "$script_for_chimerax"
    local exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo "ChimeraX分析完成: $CHIMERAX_OUTPUT_TXT_ABS"
    else
        echo "错误: ChimeraX分析失败，退出码: $exit_code"
        return "$exit_code"
    fi
}

run_all() {  # 全流程串联运行，中途任一步失败就停止
    if [ "${RUN_CHIMERAX_AFTER:-0}" -eq 1 ]; then
        echo "将依次运行: SDF→PDB、PDB→PDBQT、Vina对接、ChimeraX氢键分析"
    else
        echo "将依次运行: SDF→PDB、PDB→PDBQT、Vina对接"
    fi
    step_sdf_to_pdb || return 1
    step_pdb_to_pdbqt || return 1
    step_vina_docking || return 1
    if [ "${RUN_CHIMERAX_AFTER:-0}" -eq 1 ]; then
        step_chimerax_analysis || return 1
    fi
}

execute_choice() {
    case "$choice" in
        1) step_sdf_to_pdb ;;
        2) step_pdb_to_pdbqt ;;
        3)
            step_vina_docking || return 1
            if [ "${RUN_CHIMERAX_AFTER:-0}" -eq 1 ]; then
                step_chimerax_analysis || return 1
            fi
            ;;
        4) run_all ;;
        5) step_chimerax_analysis ;;
        0) exit 0 ;;
        *) echo "输入无效"; exit 1 ;;
    esac
}

main_menu() {  # 主菜单
    echo "========================================"
    echo " AutoDock 批处理工具"
    echo " 系统：$SYSTEM_TYPE"
    echo "========================================"
    echo "1) SDF → PDB（PyMOL）"
    echo "2) PDB → PDBQT（MGLTools）"
    echo "3) Vina 批量对接"
    echo "4) 全流程"
    echo "5) ChimeraX 氢键分析"
    echo "0) 退出"
    read -r -p "选择一个流程 [默认: 4]: " choice
    [ -z "$choice" ] && choice=4
    [ "$choice" = "0" ] && exit 0
    collect_all_inputs || exit 1
    execute_choice
}

main_menu
