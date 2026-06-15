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

normalize_path() {  # Windows路径转换
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

to_native_path() {  # 传给 Windows 原生程序时，把 /d/xxx 转成 D:/xxx
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
        label="请输入 PDBQT 转换最大并行任务数（检测到 $total 个 CPU 线程，建议不超过 8；默认 $default_jobs）: "
    elif [ "$need_pdbqt" -eq 1 ] && [ "$need_vina" -eq 1 ]; then
        default_jobs=$(min_int "$total" 8)
        label="请输入最大并行任务数（检测到 $total 个 CPU 线程，PDBQT 建议不超过 8；默认 $default_jobs）: "
    else
        default_jobs="$total"
        label="请输入 Vina 最大并行任务数 MAX_JOBS（检测到 $total 个 CPU 线程；默认 $default_jobs）: "
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
        read -r -p "未找到 PyMOL。请输入 PyMOL 应用程序路径或命令（例如 /c/Program Files/PyMOL/PyMOLWin.exe）: " PYMOL_CMD
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

find_prepare_receptor_script() {  # 兼容 Windows 与 Linux 两种 MGLTools 目录结构
    local d="$1"
    [ -f "$d/Lib/site-packages/AutoDockTools/Utilities24/prepare_receptor4.py" ] && echo "$d/Lib/site-packages/AutoDockTools/Utilities24/prepare_receptor4.py" && return 0
    [ -f "$d/MGLToolsPckgs/AutoDockTools/Utilities24/prepare_receptor4.py" ] && echo "$d/MGLToolsPckgs/AutoDockTools/Utilities24/prepare_receptor4.py" && return 0
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
        read -r -p "未找到 MGLTools。请输入 MGLTools 安装文件夹（例如 C:\\Program Files (x86)\\MGLTools-x.x.x）: " MGLTOOLS_DIR
        MGLTOOLS_DIR=$(normalize_path "$MGLTOOLS_DIR")
    fi
    [ -d "$MGLTOOLS_DIR" ] || { echo "错误: MGLTools 目录不存在: $MGLTOOLS_DIR"; return 1; }
    PREP_SCRIPT=$(find_prepare_script "$MGLTOOLS_DIR")
    [ -z "$PREP_SCRIPT" ] && { echo "错误: 找不到 prepare_ligand4.py"; return 1; }
    PREP_RECEPTOR_SCRIPT=$(find_prepare_receptor_script "$MGLTOOLS_DIR" || true)
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
        read -r -p "未找到 Vina。请输入 vina 或 vina.exe 的路径/命令（输入 vina 将使用 PATH 中的命令）: " VINA_CMD
        VINA_CMD=$(normalize_path "$VINA_CMD")
        if [ -f "$WORK_DIR_ABS/$VINA_CMD" ]; then
            VINA_CMD="./$VINA_CMD"
        fi
    fi
    command -v "$VINA_CMD" >/dev/null 2>&1 || [ -f "$WORK_DIR_ABS/${VINA_CMD#./}" ] || [ -f "$VINA_CMD" ] || { echo "错误: 找不到 Vina: $VINA_CMD"; return 1; }
}

detect_p2rank_cmd() {  # 自动识别 P2Rank 启动脚本；Windows Git Bash 优先使用无后缀 prank
    local candidates=() f
    if [ -n "${P2RANK_HOME:-}" ]; then
        candidates+=("$P2RANK_HOME/prank" "$P2RANK_HOME/prank.bat")
    fi
    candidates+=(
        "$WORK_DIR_ABS/prank" "$WORK_DIR_ABS/prank.bat"
        "$WORK_DIR_ABS/p2rank/prank" "$WORK_DIR_ABS/p2rank/prank.bat"
        "$WORK_DIR_ABS"/p2rank_*/prank "$WORK_DIR_ABS"/p2rank_*/prank.bat
        "$SCRIPT_DIR/prank" "$SCRIPT_DIR/prank.bat"
        "$SCRIPT_DIR"/p2rank_*/prank "$SCRIPT_DIR"/p2rank_*/prank.bat
    )
    for f in "${candidates[@]}"; do
        [ -f "$f" ] && echo "$f" && return 0
    done
    for f in prank prank.bat; do
        if command -v "$f" >/dev/null 2>&1; then
            command -v "$f"
            return 0
        fi
    done
    return 1
}

collect_p2rank_cmd() {  # 只在参数收集阶段获取 P2Rank 命令
    local p2rank_base p2rank_sibling
    P2RANK_CMD=$(detect_p2rank_cmd || true)
    if [ -n "$P2RANK_CMD" ]; then
        echo "已找到 P2Rank: $P2RANK_CMD"
    else
        read -r -p "未找到 P2Rank。请输入 P2Rank 的 prank 路径（例如 D:\\p2rank_2.5.1\\prank，不建议使用 prank.bat）: " P2RANK_CMD
        P2RANK_CMD=$(normalize_path "$P2RANK_CMD")
        if [ -f "$WORK_DIR_ABS/$P2RANK_CMD" ]; then
            P2RANK_CMD="$WORK_DIR_ABS/$P2RANK_CMD"
        fi
    fi
    p2rank_base=$(basename "$P2RANK_CMD" | tr 'A-Z' 'a-z')
    if [ "$SYSTEM_TYPE" = "Windows" ] && { [ "$p2rank_base" = "prank.bat" ] || [ "$p2rank_base" = "prank.cmd" ]; }; then
        p2rank_sibling="${P2RANK_CMD%.*}"
        if [ -f "$p2rank_sibling" ]; then
            echo "检测到 bat/cmd 启动脚本，Git Bash 下将改用同目录无后缀 prank: $p2rank_sibling"
            P2RANK_CMD="$p2rank_sibling"
        elif command -v prank >/dev/null 2>&1; then
            P2RANK_CMD=$(command -v prank)
            echo "检测到 bat/cmd 启动脚本，Git Bash 下将改用 PATH 中的 prank: $P2RANK_CMD"
        else
            echo "错误: Git Bash 下请使用无后缀的 P2Rank 启动脚本 prank，不建议使用 prank.bat。"
            return 1
        fi
    fi
    command -v "$P2RANK_CMD" >/dev/null 2>&1 || [ -f "$P2RANK_CMD" ] || { echo "错误: 找不到 P2Rank: $P2RANK_CMD"; return 1; }
}

ask_number_var() {
    local var_name="$1" prompt="$2" default_value="$3" input
    read -r -p "$prompt" input
    input=$(echo "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$input" ] && input="$default_value"
    if ! [[ "$input" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "请输入数字。"
        return 1
    fi
    printf -v "$var_name" '%s' "$input"
}

collect_p2rank_inputs() {
    collect_p2rank_cmd || return 1
    ask_output_dir_var P2RANK_OUT_DIR_ABS "请输入 P2Rank 预测结果文件夹（默认 工作文件夹/p2rank_results）: " "$WORK_DIR_ABS/p2rank_results" || return 1
    ask_number_var P2RANK_BOX_SIZE "请输入 Vina 对接盒子边长 Å（默认 22）: " "22" || return 1
    ask_number_var P2RANK_EXHAUSTIVENESS "请输入 Vina exhaustiveness（默认 16）: " "16" || return 1
    ask_number_var P2RANK_NUM_MODES "请输入 Vina num_modes（默认 9）: " "9" || return 1
    ask_number_var P2RANK_ENERGY_RANGE "请输入 Vina energy_range（默认 3）: " "3" || return 1
    ask_yes_no_var P2RANK_USE_ALPHAFOLD "受体是否主要来自 AlphaFold/预测结构？[Y/n]（默认y）: " "y" || return 1
    ask_yes_no_var P2RANK_OVERWRITE_CONFIGS "是否用 P2Rank 结果覆盖同名 Vina 配置文件？[Y/n]（默认y）: " "y" || return 1
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
        local chimerax_prompt
        if [ "$SYSTEM_TYPE" = "Windows" ]; then
            chimerax_prompt="未找到 ChimeraX。请输入 ChimeraX 应用程序路径或命令（例如 /c/Program Files/ChimeraX 1.12/bin/ChimeraX.exe）: "
        else
            chimerax_prompt="未找到 ChimeraX。请输入 ChimeraX 应用程序路径或命令（例如 /usr/bin/chimerax 或 /opt/ChimeraX/bin/ChimeraX）: "
        fi
        read -r -p "$chimerax_prompt" CHIMERAX_CMD
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

    read -r -p "请输入 ChimeraX 分析脚本路径（默认 $default_script）: " input
    input=$(normalize_path "$input")
    [ -z "$input" ] && input="$default_script"
    script_abs=$(path_relative_or_absolute_to_workdir "$input")
    [ -f "$script_abs" ] || { echo "错误: 找不到 ChimeraX 分析脚本: $script_abs"; return 1; }
    CHIMERAX_SCRIPT_ABS="$script_abs"

    read -r -p "请输入要分析的受体名称（多个用逗号分隔；留空则自动检测 receptor 文件夹中的 .pdbqt）: " CHIMERAX_RECEPTORS
    CHIMERAX_RECEPTORS=$(echo "$CHIMERAX_RECEPTORS" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    default_txt="$DOCK_OUT_DIR_ABS/vina_hbond_hydrophobic_summary.txt"
    read -r -p "请输入 ChimeraX 结果 TXT 路径（默认 $default_txt；输入文件夹时将自动追加文件名）: " input
    input=$(normalize_path "$input")
    [ -z "$input" ] && input="$default_txt"
    out_abs=$(path_relative_or_absolute_to_workdir "$input")
    if [ -d "$out_abs" ]; then
        out_abs="$out_abs/vina_hbond_hydrophobic_summary.txt"
    fi
    out_parent=$(dirname "$out_abs")
    mkdir -p "$out_parent" || { echo "错误: 无法创建ChimeraX输出目录: $out_parent"; return 1; }
    CHIMERAX_OUTPUT_TXT_ABS="$out_abs"

    ask_yes_no_var CHIMERAX_RELAX_HBOND "是否使用宽松氢键判定标准（relax=true）？[Y/n]（默认y）: " "y" || return 1
    ask_yes_no_var CHIMERAX_PRINT_EACH_POSE "是否在 ChimeraX Log 中显示每个 pose 的进度？[Y/n]（默认y）: " "y" || return 1
    ask_yes_no_var CHIMERAX_KEEP_DETAILS "是否保留每个 pose 的氢键明细文件？[y/N]（默认n）: " "n" || return 1
}

ask_work_dir_once() {  # 工作目录只询问一次
    local input
    read -r -p "请输入工作文件夹（默认 当前文件夹）: " input
    input=$(normalize_path "$input")
    [ -z "$input" ] && input="$PWD"
    WORK_DIR_ABS=$(abs_dir "$input") || { echo "错误: 找不到工作目录: $input"; return 1; }
}

collect_all_inputs() {  # 所有需要询问的内容集中放在正式运行之前
    local need_pymol_sdf=0 need_pymol_final=0 need_mgl=0 need_vina=0 need_pdbqt=0 need_receptor_pdbqt=0 need_p2rank=0 need_chimerax=0 can_run_chimerax_after=0 can_run_pymol_after_chimerax=0
    RUN_CHIMERAX_AFTER=0
    RUN_PYMOL_FINAL_AFTER=0
    case "$choice" in
        1) need_pymol_sdf=1 ;;
        2) need_mgl=1; need_pdbqt=1 ;;
        3) need_vina=1; can_run_chimerax_after=1 ;;
        4) need_pymol_sdf=1; need_mgl=1; need_vina=1; need_pdbqt=1; can_run_chimerax_after=1 ;;
        5) need_chimerax=1; can_run_pymol_after_chimerax=1 ;;
        6) need_pymol_final=1 ;;
        *) echo "输入无效"; return 1 ;;
    esac

    bar
    echo "开始设置。请先确认本次流程需要的选项。"
    echo "设置完成后，将开始执行任务。"
    bar

    ask_work_dir_once || return 1

    if [ "$choice" = "1" ]; then
        ask_existing_dir_var LIGAND_DIR_ABS "请输入 Ligand 文件夹（默认 工作文件夹/ligand）: " "$WORK_DIR_ABS/ligand" || return 1
        PDB_INPUT_DIR_ABS="$LIGAND_DIR_ABS"
        SDF_INPUT_DIR_ABS="$LIGAND_DIR_ABS"
        ask_output_dir_var PDB_OUT_DIR_ABS "请输入 PDB 输出文件夹（默认 $LIGAND_DIR_ABS）: " "$LIGAND_DIR_ABS" || return 1
    elif [ "$choice" = "2" ]; then
        ask_existing_dir_var LIGAND_DIR_ABS "请输入 Ligand 文件夹（默认 工作文件夹/ligand）: " "$WORK_DIR_ABS/ligand" || return 1
        PDB_INPUT_DIR_ABS="$LIGAND_DIR_ABS"
        ask_output_dir_var PDBQT_OUT_DIR_ABS "请输入 PDBQT 输出文件夹（默认 $LIGAND_DIR_ABS）: " "$LIGAND_DIR_ABS" || return 1
    elif [ "$choice" = "3" ]; then
        ask_existing_dir_var RECEPTOR_DIR_ABS "请输入 Receptor 文件夹（默认 工作文件夹/receptor）: " "$WORK_DIR_ABS/receptor" || return 1
        ask_existing_dir_var VINA_LIGAND_DIR_ABS "请输入配体 PDBQT 文件夹（默认 工作文件夹/ligand）: " "$WORK_DIR_ABS/ligand" || return 1
        ask_output_dir_var CONFIG_DIR_ABS "请输入配置文件夹（默认 工作文件夹/dockingConfigs）: " "$WORK_DIR_ABS/dockingConfigs" || return 1
        ask_output_dir_var DOCK_OUT_DIR_ABS "请输入 Vina 结果输出文件夹（默认 工作文件夹/Docking_Results_Parallel）: " "$WORK_DIR_ABS/Docking_Results_Parallel" || return 1
        ask_yes_no_var RUN_RECEPTOR_PDBQT_PREP "是否将受体 PDB 自动转换为 PDBQT？[y/N]（默认n）: " "n" || return 1
        ask_yes_no_var RUN_P2RANK_BEFORE_VINA "是否先运行 P2Rank 预测口袋并自动生成 Vina 配置？[Y/n]（默认y）: " "y" || return 1
        if [ "$RUN_RECEPTOR_PDBQT_PREP" -eq 1 ] || [ "$RUN_P2RANK_BEFORE_VINA" -eq 1 ]; then
            ask_existing_dir_var RECEPTOR_PDB_DIR_ABS "请输入受体 PDB 文件夹（默认 Receptor 文件夹）: " "$RECEPTOR_DIR_ABS" || return 1
        fi
        if [ "$RUN_RECEPTOR_PDBQT_PREP" -eq 1 ]; then
            need_mgl=1
            need_receptor_pdbqt=1
        fi
        if [ "$RUN_P2RANK_BEFORE_VINA" -eq 1 ]; then
            need_p2rank=1
        fi
    elif [ "$choice" = "4" ]; then
        ask_existing_dir_var LIGAND_DIR_ABS "请输入 Ligand 原始文件夹（默认 工作文件夹/ligand）: " "$WORK_DIR_ABS/ligand" || return 1
        SDF_INPUT_DIR_ABS="$LIGAND_DIR_ABS"
        ask_output_dir_var PDB_OUT_DIR_ABS "请输入 PDB 输出文件夹（默认 $LIGAND_DIR_ABS）: " "$LIGAND_DIR_ABS" || return 1
        PDB_INPUT_DIR_ABS="$PDB_OUT_DIR_ABS"
        ask_output_dir_var PDBQT_OUT_DIR_ABS "请输入 PDBQT 输出文件夹（默认 $PDB_OUT_DIR_ABS）: " "$PDB_OUT_DIR_ABS" || return 1
        VINA_LIGAND_DIR_ABS="$PDBQT_OUT_DIR_ABS"
        echo "Vina 配体文件夹将使用 PDBQT 输出文件夹: $VINA_LIGAND_DIR_ABS"
        ask_existing_dir_var RECEPTOR_DIR_ABS "请输入 Receptor 文件夹（默认 工作文件夹/receptor）: " "$WORK_DIR_ABS/receptor" || return 1
        ask_output_dir_var CONFIG_DIR_ABS "请输入配置文件夹（默认 工作文件夹/dockingConfigs）: " "$WORK_DIR_ABS/dockingConfigs" || return 1
        ask_output_dir_var DOCK_OUT_DIR_ABS "请输入 Vina 结果输出文件夹（默认 工作文件夹/Docking_Results_Parallel）: " "$WORK_DIR_ABS/Docking_Results_Parallel" || return 1
        ask_yes_no_var RUN_RECEPTOR_PDBQT_PREP "是否将受体 PDB 自动转换为 PDBQT？[y/N]（默认n）: " "n" || return 1
        ask_yes_no_var RUN_P2RANK_BEFORE_VINA "是否先运行 P2Rank 预测口袋并自动生成 Vina 配置？[Y/n]（默认y）: " "y" || return 1
        if [ "$RUN_RECEPTOR_PDBQT_PREP" -eq 1 ] || [ "$RUN_P2RANK_BEFORE_VINA" -eq 1 ]; then
            ask_existing_dir_var RECEPTOR_PDB_DIR_ABS "请输入受体 PDB 文件夹（默认 Receptor 文件夹）: " "$RECEPTOR_DIR_ABS" || return 1
        fi
        if [ "$RUN_RECEPTOR_PDBQT_PREP" -eq 1 ]; then
            need_mgl=1
            need_receptor_pdbqt=1
        fi
        if [ "$RUN_P2RANK_BEFORE_VINA" -eq 1 ]; then
            need_p2rank=1
        fi
    elif [ "$choice" = "5" ]; then
        ask_existing_dir_var RECEPTOR_DIR_ABS "请输入 Receptor 文件夹（默认 工作文件夹/receptor）: " "$WORK_DIR_ABS/receptor" || return 1
        ask_existing_dir_var DOCK_OUT_DIR_ABS "请输入 Vina 结果文件夹（默认 工作文件夹/Docking_Results_Parallel）: " "$WORK_DIR_ABS/Docking_Results_Parallel" || return 1
    elif [ "$choice" = "6" ]; then
        ask_existing_dir_var RECEPTOR_DIR_ABS "请输入 Receptor 文件夹（默认 工作文件夹/receptor）: " "$WORK_DIR_ABS/receptor" || return 1
        ask_existing_dir_var DOCK_OUT_DIR_ABS "请输入 Vina 结果文件夹（默认 工作文件夹/Docking_Results_Parallel）: " "$WORK_DIR_ABS/Docking_Results_Parallel" || return 1
    fi

    if [ "$can_run_chimerax_after" -eq 1 ]; then
        ask_yes_no_var RUN_CHIMERAX_AFTER "Vina 对接完成后是否继续运行 ChimeraX 氢键分析？[Y/n]（默认y）: " "y" || return 1
        if [ "$RUN_CHIMERAX_AFTER" -eq 1 ]; then
            need_chimerax=1
            ask_yes_no_var RUN_PYMOL_FINAL_AFTER "ChimeraX 氢键分析完成后是否继续运行 PyMOL 最终可视化？[y/N]（默认n）: " "n" || return 1
            [ "$RUN_PYMOL_FINAL_AFTER" -eq 1 ] && need_pymol_final=1
        fi
    fi

    if [ "$can_run_pymol_after_chimerax" -eq 1 ]; then
        ask_yes_no_var RUN_PYMOL_FINAL_AFTER "ChimeraX 氢键分析完成后是否继续运行 PyMOL 最终可视化？[y/N]（默认n）: " "n" || return 1
        [ "$RUN_PYMOL_FINAL_AFTER" -eq 1 ] && need_pymol_final=1
    fi

    if [ "$need_pymol_sdf" -eq 1 ] || [ "$need_pymol_final" -eq 1 ]; then
        collect_pymol_cmd || return 1
    fi

    if [ "$need_pymol_sdf" -eq 1 ]; then
        read -r -p "请选择 PyMOL SDF→PDB 运行模式：1) GUI（默认）  2) No-GUI: " PYMOL_MODE
        [ -z "$PYMOL_MODE" ] && PYMOL_MODE=1
        if [ "$PYMOL_MODE" != "1" ] && [ "$PYMOL_MODE" != "2" ]; then
            echo "错误: PyMOL运行模式只能输入 1 或 2"
            return 1
        fi
    fi

    if [ "$need_mgl" -eq 1 ]; then
        collect_mgltools || return 1
    fi

    if [ "$need_receptor_pdbqt" -eq 1 ] && [ -z "${PREP_RECEPTOR_SCRIPT:-}" ]; then
        echo "错误: 当前 MGLTools 目录中找不到 prepare_receptor4.py，无法自动转换受体 PDB。"
        return 1
    fi

    if [ "$need_vina" -eq 1 ]; then
        collect_vina_cmd || return 1
    fi

    if [ "$need_p2rank" -eq 1 ]; then
        collect_p2rank_inputs || return 1
    fi

    if [ "$need_pdbqt" -eq 1 ] || [ "$need_receptor_pdbqt" -eq 1 ] || [ "$need_vina" -eq 1 ]; then
        local any_pdbqt="$need_pdbqt"
        [ "$need_receptor_pdbqt" -eq 1 ] && any_pdbqt=1
        ask_parallel_jobs "$any_pdbqt" "$need_vina" || return 1
    fi

    if [ "$need_chimerax" -eq 1 ]; then
        collect_chimerax_inputs || return 1
    fi

    if [ "$need_pymol_final" -eq 1 ]; then
        collect_pymol_final_inputs || return 1
    fi

    bar
    echo "设置完成"
    echo "工作目录: $WORK_DIR_ABS"
    [ -n "${SDF_INPUT_DIR_ABS:-}" ] && echo "SDF目录: $SDF_INPUT_DIR_ABS"
    [ -n "${PDB_INPUT_DIR_ABS:-}" ] && echo "PDB输入目录: $PDB_INPUT_DIR_ABS"
    [ -n "${PDB_OUT_DIR_ABS:-}" ] && echo "PDB输出目录: $PDB_OUT_DIR_ABS"
    [ -n "${PDBQT_OUT_DIR_ABS:-}" ] && echo "PDBQT输出目录: $PDBQT_OUT_DIR_ABS"
    [ -n "${RECEPTOR_DIR_ABS:-}" ] && echo "受体目录: $RECEPTOR_DIR_ABS"
    [ -n "${RECEPTOR_PDB_DIR_ABS:-}" ] && echo "受体PDB目录: $RECEPTOR_PDB_DIR_ABS"
    [ -n "${VINA_LIGAND_DIR_ABS:-}" ] && echo "Vina配体目录: $VINA_LIGAND_DIR_ABS"
    [ -n "${CONFIG_DIR_ABS:-}" ] && echo "配置目录: $CONFIG_DIR_ABS"
    [ -n "${DOCK_OUT_DIR_ABS:-}" ] && echo "Vina结果输出目录: $DOCK_OUT_DIR_ABS"
    [ -n "${COMMON_MAX_JOBS:-}" ] && echo "最大并行任务数: $COMMON_MAX_JOBS"
    if [ "${need_receptor_pdbqt:-0}" -eq 1 ]; then
        echo "受体PDB→PDBQT: 是"
    fi
    if [ "${need_p2rank:-0}" -eq 1 ]; then
        echo "P2Rank预测口袋: 是"
        echo "P2Rank程序: $P2RANK_CMD"
        echo "P2Rank输出目录: $P2RANK_OUT_DIR_ABS"
        echo "Vina自动盒子边长: $P2RANK_BOX_SIZE Å"
    fi
    if [ "${need_chimerax:-0}" -eq 1 ]; then
        echo "ChimeraX分析: 是"
        echo "ChimeraX程序: $CHIMERAX_CMD"
        echo "ChimeraX脚本: $CHIMERAX_SCRIPT_ABS"
        echo "ChimeraX结果TXT: $CHIMERAX_OUTPUT_TXT_ABS"
        [ -n "${CHIMERAX_RECEPTORS:-}" ] && echo "ChimeraX指定受体: $CHIMERAX_RECEPTORS" || echo "ChimeraX指定受体: 自动检测"
    fi
    if [ "${need_pymol_final:-0}" -eq 1 ]; then
        echo "PyMOL最终可视化: 是"
        echo "PyMOL程序: $PYMOL_CMD"
        echo "PyMOL读取TXT: $PYMOL_FINAL_SUMMARY_ABS"
        echo "PyMOL输出目录: $PYMOL_FINAL_OUT_DIR_ABS"
        case "${PYMOL_FINAL_OUTPUT_MODE:-both}" in
            pse) echo "PyMOL输出内容: 仅输出PSE文件" ;;
            image) echo "PyMOL输出内容: 仅渲染图像" ;;
            both) echo "PyMOL输出内容: 输出PSE文件和渲染图像" ;;
            *) echo "PyMOL输出内容: ${PYMOL_FINAL_OUTPUT_MODE:-both}" ;;
        esac
        [ "${PYMOL_FINAL_RENDER_ENGINE:-none}" != "none" ] && echo "PyMOL渲染方式: ${PYMOL_FINAL_RENDER_ENGINE:-ray}"
        if [ "${PYMOL_FINAL_MODE:-2}" = "2" ]; then echo "PyMOL运行模式: No-GUI"; else echo "PyMOL运行模式: GUI"; fi
        [ -n "${PYMOL_FINAL_RECEPTORS:-}" ] && echo "PyMOL指定受体: $PYMOL_FINAL_RECEPTORS" || echo "PyMOL指定受体: 读取TXT全部结果"
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

step_receptor_pdb_to_pdbqt() {  # 可选步骤: 用 MGLTools 将受体 PDB 批量转成 PDBQT
    cd "$RECEPTOR_PDB_DIR_ABS" || return 1
    shopt -s nullglob
    local pdb_files=(*.pdb)
    local n=${#pdb_files[@]}
    [ "$n" -eq 0 ] && { echo "错误: 在 $RECEPTOR_PDB_DIR_ABS 中没有找到 .pdb 受体文件"; return 1; }
    [ -n "${PREP_RECEPTOR_SCRIPT:-}" ] && [ -f "$PREP_RECEPTOR_SCRIPT" ] || { echo "错误: 找不到 prepare_receptor4.py"; return 1; }

    local log_dir="$RECEPTOR_DIR_ABS/_prep_receptor_logs"
    local failed_list="$log_dir/_failed_receptors.txt"
    local prep_tool max_jobs
    mkdir -p "$log_dir" "$RECEPTOR_DIR_ABS"
    : > "$failed_list"
    prep_tool=$(to_native_path "$PREP_RECEPTOR_SCRIPT")
    max_jobs="$PDBQT_MAX_JOBS"

    run_receptor_prep_one() {
        local pdb="$1"
        local name="${pdb%.pdb}"
        local out_mgl log
        out_mgl=$(to_native_path "$RECEPTOR_DIR_ABS/${name}.pdbqt")
        log="$log_dir/${name}_prepare_receptor.log"
        (cd "$RECEPTOR_PDB_DIR_ABS" && "$MGL_PYTHON" "$prep_tool" -r "$pdb" -o "$out_mgl" -A hydrogens > "$log" 2>&1)
        if [ "$?" -eq 0 ]; then
            echo "[OK] receptor ${name}.pdbqt"
        else
            echo "[FAILED] receptor $pdb | log: $log"
            echo "$pdb" >> "$failed_list"
        fi
    }

    bar
    echo "受体PDB目录: $RECEPTOR_PDB_DIR_ABS"
    echo "受体PDBQT输出目录: $RECEPTOR_DIR_ABS"
    echo "受体PDB数量: $n"
    echo "并行数: $max_jobs"
    echo "日志目录: $log_dir"
    bar
    for pdb in "${pdb_files[@]}"; do
        run_receptor_prep_one "$pdb" &
        while [ "$(jobs -rp | wc -l)" -ge "$max_jobs" ]; do sleep 0.3; done
    done
    wait
    local fail_count
    fail_count=$(wc -l < "$failed_list" | tr -d ' ')
    echo "受体PDBQT转换结束: 成功 $((n - fail_count)) / $n"
    [ "$fail_count" -gt 0 ] && echo "失败列表: $failed_list"
    [ "$fail_count" -gt 0 ] && return 1
    return 0
}

step_p2rank_generate_configs() {  # 可选步骤: P2Rank预测口袋，并用rank 1口袋生成Vina配置
    cd "$WORK_DIR_ABS" || return 1
    [ -n "${P2RANK_CMD:-}" ] || { echo "错误: 未设置 P2Rank 程序路径"; return 1; }
    [ -d "$RECEPTOR_PDB_DIR_ABS" ] || { echo "错误: 受体PDB目录不存在: $RECEPTOR_PDB_DIR_ABS"; return 1; }
    mkdir -p "$P2RANK_OUT_DIR_ABS" "$CONFIG_DIR_ABS" || return 1

    shopt -s nullglob
    local receptor_pdbs=("$RECEPTOR_PDB_DIR_ABS"/*.pdb)
    local n=${#receptor_pdbs[@]}
    [ "$n" -eq 0 ] && { echo "错误: 在 $RECEPTOR_PDB_DIR_ABS 中没有找到 .pdb 受体文件，P2Rank无法预测。"; return 1; }

    local p2rank_exec p2rank_dir p2rank_runner pdb_file pdb_native rec_name rec_out_dir p2rank_native p2rank_args exit_code
    p2rank_exec="$P2RANK_CMD"
    if [ -f "$p2rank_exec" ]; then
        p2rank_dir=$(cd "$(dirname "$p2rank_exec")" >/dev/null 2>&1 && pwd)
        p2rank_runner="./$(basename "$p2rank_exec")"
    else
        p2rank_dir="$WORK_DIR_ABS"
        p2rank_runner="$p2rank_exec"
    fi
    if [ "$SYSTEM_TYPE" = "Linux" ] && [ -f "$p2rank_exec" ]; then
        chmod +x "$p2rank_exec" 2>/dev/null
    fi
    if [ -f "$p2rank_exec" ] && [ ! -d "$p2rank_dir" ]; then
        echo "错误: P2Rank程序目录不存在: $p2rank_dir"
        return 1
    fi

    bar
    echo "开始 P2Rank 口袋预测"
    echo "P2Rank程序目录: $p2rank_dir"
    echo "受体PDB目录: $RECEPTOR_PDB_DIR_ABS"
    echo "P2Rank输出目录: $P2RANK_OUT_DIR_ABS"
    echo "配置输出目录: $CONFIG_DIR_ABS"
    echo "受体数量: $n"
    bar

    for pdb_file in "${receptor_pdbs[@]}"; do
        rec_name=$(basename "$pdb_file" .pdb)
        rec_out_dir="$P2RANK_OUT_DIR_ABS/$rec_name"
        mkdir -p "$rec_out_dir"
        pdb_native=$(to_native_path "$pdb_file")
        p2rank_native=$(to_native_path "$rec_out_dir")
        p2rank_args=(predict -f "$pdb_native" -o "$p2rank_native")
        [ "${P2RANK_USE_ALPHAFOLD:-1}" -eq 1 ] && p2rank_args+=(-c alphafold)

        echo ">>> P2Rank预测: $rec_name"
        (cd "$p2rank_dir" && "$p2rank_runner" "${p2rank_args[@]}")
        exit_code=$?
        if [ "$exit_code" -ne 0 ]; then
            echo "错误: P2Rank预测失败: $rec_name"
            return "$exit_code"
        fi
    done

    local py_script="$WORK_DIR_ABS/_p2rank_to_vina_config_temp.py"
    local p2rank_out_for_python config_dir_for_python
    p2rank_out_for_python=$(to_native_path "$P2RANK_OUT_DIR_ABS")
    config_dir_for_python=$(to_native_path "$CONFIG_DIR_ABS")
    cat > "$py_script" <<PYEOF
# -*- coding: utf-8 -*-
import csv
import os
import re
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

p2rank_root = Path(r'''$p2rank_out_for_python''')
config_dir = Path(r'''$config_dir_for_python''')
box_size = float(r'''$P2RANK_BOX_SIZE''')
exhaustiveness = r'''$P2RANK_EXHAUSTIVENESS'''
num_modes = r'''$P2RANK_NUM_MODES'''
energy_range = r'''$P2RANK_ENERGY_RANGE'''
overwrite = str(r'''${P2RANK_OVERWRITE_CONFIGS:-1}''') == "1"

def norm_key(key):
    return re.sub(r"[^a-z0-9]", "", key.lower())

def find_col(fieldnames, candidates):
    normalized = {norm_key(k): k for k in fieldnames or []}
    for cand in candidates:
        hit = normalized.get(norm_key(cand))
        if hit:
            return hit
    for k in fieldnames or []:
        nk = norm_key(k)
        for cand in candidates:
            if norm_key(cand) in nk:
                return k
    return None

def as_float(value):
    return float(str(value).strip())

def pick_prediction_csv(folder):
    preferred = sorted(folder.glob("*_predictions.csv"))
    if preferred:
        return preferred[0]
    fallback = sorted(folder.glob("*predictions*.csv"))
    return fallback[0] if fallback else None

def best_row(rows, rank_col, score_col, prob_col):
    if not rows:
        return None
    if rank_col:
        ranked = []
        for row in rows:
            try:
                ranked.append((float(row.get(rank_col, "")), row))
            except Exception:
                pass
        if ranked:
            return sorted(ranked, key=lambda x: x[0])[0][1]
    for col in (score_col, prob_col):
        if col:
            scored = []
            for row in rows:
                try:
                    scored.append((float(row.get(col, "")), row))
                except Exception:
                    pass
            if scored:
                return sorted(scored, key=lambda x: x[0], reverse=True)[0][1]
    return rows[0]

ok = 0
failed = 0
config_dir.mkdir(parents=True, exist_ok=True)

for rec_dir in sorted([p for p in p2rank_root.iterdir() if p.is_dir()]):
    rec_name = rec_dir.name
    csv_path = pick_prediction_csv(rec_dir)
    if csv_path is None:
        print(f"[FAILED] {rec_name}: no P2Rank predictions csv found")
        failed += 1
        continue

    with csv_path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames or []
        rows = list(reader)

    x_col = find_col(fieldnames, ["center_x", "center x", "x"])
    y_col = find_col(fieldnames, ["center_y", "center y", "y"])
    z_col = find_col(fieldnames, ["center_z", "center z", "z"])
    rank_col = find_col(fieldnames, ["rank"])
    score_col = find_col(fieldnames, ["score"])
    prob_col = find_col(fieldnames, ["probability", "prob"])

    if not (x_col and y_col and z_col):
        print(f"[FAILED] {rec_name}: cannot find center_x/center_y/center_z columns in {csv_path.name}")
        failed += 1
        continue

    row = best_row(rows, rank_col, score_col, prob_col)
    if row is None:
        print(f"[FAILED] {rec_name}: empty predictions csv")
        failed += 1
        continue

    try:
        cx = as_float(row[x_col])
        cy = as_float(row[y_col])
        cz = as_float(row[z_col])
    except Exception as exc:
        print(f"[FAILED] {rec_name}: invalid pocket center values: {exc}")
        failed += 1
        continue

    out = config_dir / f"{rec_name}_vinaConfig.txt"
    if out.exists() and not overwrite:
        print(f"[SKIP] {rec_name}: config exists: {out}")
        continue

    ligand_placeholder = "__LIGAND_WILL_BE_REPLACED_BY_PIPELINE__"
    text = "\n".join([
        f"receptor = {rec_name}.pdbqt",
        f"ligand = {ligand_placeholder}",
        "",
        f"center_x = {cx:.3f}",
        f"center_y = {cy:.3f}",
        f"center_z = {cz:.3f}",
        "",
        f"size_x = {box_size:g}",
        f"size_y = {box_size:g}",
        f"size_z = {box_size:g}",
        "",
        f"exhaustiveness = {exhaustiveness}",
        f"num_modes = {num_modes}",
        f"energy_range = {energy_range}",
        "",
    ])
    out.write_text(text, encoding="utf-8")
    rank_info = row.get(rank_col, "1") if rank_col else "best"
    print(f"[OK] {rec_name}: rank={rank_info}, center=({cx:.3f}, {cy:.3f}, {cz:.3f}) -> {out}")
    ok += 1

print(f"P2Rank配置生成结束: 成功 {ok}, 失败 {failed}")
sys.exit(1 if failed else 0)
PYEOF

    local python_cmd
    python_cmd=$(command -v python 2>/dev/null || command -v python3 2>/dev/null || command -v py 2>/dev/null || true)
    [ -z "$python_cmd" ] && { echo "错误: 找不到 Python，无法解析 P2Rank 结果并生成 Vina 配置。"; rm -f "$py_script"; return 1; }
    if [[ "$(basename "$python_cmd")" = "py" || "$(basename "$python_cmd")" = "py.exe" ]]; then
        "$python_cmd" -3 "$py_script"
    else
        "$python_cmd" "$py_script"
    fi
    exit_code=$?
    rm -f "$py_script"
    [ "$exit_code" -ne 0 ] && return "$exit_code"
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


collect_pymol_final_inputs() {  # 获取 PyMOL 最终可视化参数；输出默认放入工作目录/Final
    local input default_summary summary_abs out_abs

    if [ -n "${CHIMERAX_OUTPUT_TXT_ABS:-}" ]; then
        default_summary="$CHIMERAX_OUTPUT_TXT_ABS"
    elif [ -f "$WORK_DIR_ABS/Final/vina_hbond_hydrophobic_summary.txt" ]; then
        default_summary="$WORK_DIR_ABS/Final/vina_hbond_hydrophobic_summary.txt"
    else
        default_summary="$DOCK_OUT_DIR_ABS/vina_hbond_hydrophobic_summary.txt"
    fi

    read -r -p "请输入 PyMOL 要读取的 ChimeraX 结果 TXT 路径（默认 $default_summary）: " input
    input=$(normalize_path "$input")
    [ -z "$input" ] && input="$default_summary"
    summary_abs=$(path_relative_or_absolute_to_workdir "$input")
    # 这里不强制要求文件已经存在，因为在“Vina→ChimeraX→PyMOL”连续流程中，TXT 会在稍后由 ChimeraX 生成。
    # 真正运行 PyMOL 前会再次检查文件是否存在。
    PYMOL_FINAL_SUMMARY_ABS="$summary_abs"

    read -r -p "请输入 PyMOL 最终图像/PSE 输出文件夹（默认 工作文件夹/Final）: " input
    input=$(normalize_path "$input")
    if [ -z "$input" ]; then
        out_abs="$WORK_DIR_ABS/Final"
    else
        out_abs=$(path_relative_or_absolute_to_workdir "$input")
    fi
    mkdir -p "$out_abs" || { echo "错误: 无法创建PyMOL输出目录: $out_abs"; return 1; }
    PYMOL_FINAL_OUT_DIR_ABS=$(abs_dir "$out_abs") || { echo "错误: 无法进入PyMOL输出目录: $out_abs"; return 1; }

    read -r -p "请输入 PyMOL 可视化受体名称（多个用逗号分隔；留空则读取 TXT 中的全部结果）: " PYMOL_FINAL_RECEPTORS
    PYMOL_FINAL_RECEPTORS=$(echo "$PYMOL_FINAL_RECEPTORS" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    read -r -p "请选择 PyMOL 输出内容：1) 仅保存 PSE  2) 仅渲染图像  3) 保存 PSE 并渲染图像（默认）: " PYMOL_FINAL_OUTPUT_CHOICE
    [ -z "$PYMOL_FINAL_OUTPUT_CHOICE" ] && PYMOL_FINAL_OUTPUT_CHOICE=3
    case "$PYMOL_FINAL_OUTPUT_CHOICE" in
        1|pse|PSE|Pse)
            PYMOL_FINAL_OUTPUT_MODE="pse"
            PYMOL_FINAL_SAVE_PSE=1
            PYMOL_FINAL_RENDER_IMAGES=0
            ;;
        2|image|images|png|PNG|render|Render|RENDER)
            PYMOL_FINAL_OUTPUT_MODE="image"
            PYMOL_FINAL_SAVE_PSE=0
            PYMOL_FINAL_RENDER_IMAGES=1
            ;;
        3|both|Both|BOTH|all|All|ALL)
            PYMOL_FINAL_OUTPUT_MODE="both"
            PYMOL_FINAL_SAVE_PSE=1
            PYMOL_FINAL_RENDER_IMAGES=1
            ;;
        *)
            echo "错误: PyMOL输出只能选择 1/pse、2/image 或 3/both"
            return 1
            ;;
    esac

    if [ "$PYMOL_FINAL_RENDER_IMAGES" -eq 1 ]; then
        read -r -p "请选择 PyMOL 渲染方式：1) ray（默认，质量更高）  2) draw（速度更快，将自动禁用 GUI）: " PYMOL_FINAL_RENDER_CHOICE
        [ -z "$PYMOL_FINAL_RENDER_CHOICE" ] && PYMOL_FINAL_RENDER_CHOICE=1
        case "$PYMOL_FINAL_RENDER_CHOICE" in
            1|ray|Ray|RAY)
                PYMOL_FINAL_RENDER_ENGINE="ray"
                ;;
            2|draw|Draw|DRAW)
                PYMOL_FINAL_RENDER_ENGINE="draw"
                ;;
            *)
                echo "错误: PyMOL渲染方式只能输入 1/ray 或 2/draw"
                return 1
                ;;
        esac
    else
        PYMOL_FINAL_RENDER_ENGINE="none"
    fi

    if [ "$PYMOL_FINAL_RENDER_ENGINE" = "draw" ]; then
        PYMOL_FINAL_MODE=2
        echo "已选择 draw 渲染：自动禁用 GUI。"
    else
        read -r -p "请选择 PyMOL 运行模式：1) GUI  2) No-GUI（默认）: " PYMOL_FINAL_MODE
        [ -z "$PYMOL_FINAL_MODE" ] && PYMOL_FINAL_MODE=2
        if [ "$PYMOL_FINAL_MODE" != "1" ] && [ "$PYMOL_FINAL_MODE" != "2" ]; then
            echo "错误: PyMOL运行模式只能输入 1 或 2"
            return 1
        fi
    fi
}

write_pymol_final_visualization_script() {  # 将PyMOL可视化Python脚本写入工作目录临时文件
    PYMOL_FINAL_SCRIPT_ABS="$WORK_DIR_ABS/_pymol_vina_final_visualization_temp.py"
    cat > "$PYMOL_FINAL_SCRIPT_ABS" <<'PYMOL_FINAL_PYEOF'
from pymol import cmd, util
import os
import sys
import re
import csv
from pathlib import Path

# =========================
# Pipeline / environment configuration
# =========================
# These values are normally injected by autodock_universal_pipeline_with_pymol_final.sh.
# They can still be edited manually if this Python file is run independently in PyMOL.
SUMMARY_FILE = os.environ.get("PYMOL_VINA_SUMMARY_FILE", r"")
WORK_DIR = os.environ.get("PYMOL_VINA_WORK_DIR", r"")
RECEPTOR_DIR = os.environ.get("PYMOL_VINA_RECEPTOR_DIR", r"")
DOCKING_DIR = os.environ.get("PYMOL_VINA_DOCKING_DIR", r"")
OUTPUT_DIR = os.environ.get("PYMOL_VINA_OUTPUT_DIR", r"")

if not OUTPUT_DIR:
    OUTPUT_DIR = str(Path(WORK_DIR or ".") / "Final")

_receptors_env = os.environ.get("PYMOL_VINA_RECEPTORS", "").strip()
RECEPTORS = [x.strip() for x in re.split(r"[,;\s]+", _receptors_env) if x.strip()] if _receptors_env else []

OUTPUT_MODE = os.environ.get("PYMOL_VINA_OUTPUT_MODE", "both").strip().lower()
if OUTPUT_MODE not in {"pse", "image", "both"}:
    print(f"[WARN] Unknown PYMOL_VINA_OUTPUT_MODE={OUTPUT_MODE!r}; fallback to both.")
    OUTPUT_MODE = "both"

# Backward compatibility: if an older wrapper only sets PYMOL_VINA_SAVE_FOCUS_PSE,
# still honor it unless the new PYMOL_VINA_OUTPUT_MODE is provided.
_legacy_save_pse = os.environ.get("PYMOL_VINA_SAVE_FOCUS_PSE", "1").strip().lower() not in {"0", "false", "no", "n", "否"}
OUTPUT_PSE = OUTPUT_MODE in {"pse", "both"} and _legacy_save_pse
OUTPUT_IMAGES = OUTPUT_MODE in {"image", "both"}

RENDER_ENGINE = os.environ.get("PYMOL_VINA_RENDER_ENGINE", "ray").strip().lower()
if not OUTPUT_IMAGES:
    RENDER_ENGINE = "none"
elif RENDER_ENGINE not in {"ray", "draw"}:
    print(f"[WARN] Unknown PYMOL_VINA_RENDER_ENGINE={RENDER_ENGINE!r}; fallback to ray.")
    RENDER_ENGINE = "ray"

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

if not SUMMARY_FILE:
    raise RuntimeError("PYMOL_VINA_SUMMARY_FILE is empty. Please set the ChimeraX summary txt path.")

# Image settings
IMG_W = 3840
IMG_H = 2400
IMG_DPI = 300
# RENDER_ENGINE is controlled by pipeline: "ray" for ray tracing, "draw" for OpenGL draw rendering.

# Naming convention
RECEPTOR_SUFFIX = ".pdbqt"
DOCK_SUFFIX = "_out.pdbqt"   # receptor_ligand_out.pdbqt

# Distances / pocket fallback
HBOND_CUTOFF = 3.6
POCKET_CUTOFF_IF_NO_HBOND = 4.0
LABEL_ONLY_HBOND_RESIDUES = True  # True -> focus only labels hbond residues; no-hbond poses show no residue labels
SHOW_NEAR_POCKET_IF_NO_HBOND = False  # True -> no-hbond poses show nearby pocket residues as sticks
FOCUS_BUFFER = 7
OVERVIEW_BUFFER = 12

# Clipping: use a very large slab so the near/far planes do not cut off the scene
CLIP_SLAB = 1000
NEAR_CLIP_RELAX = -50

# Colors / style
# Use custom RGB colors instead of fragile built-in PyMOL color names.
# PyMOL color names with hyphens such as "tints-lightpink" may fail in some versions,
# so we define stable internal names with underscores.
BG_COLOR = "white"
TRANSPARENT_BACKGROUND = True   # True -> export PNG with transparent background

# Display -> Color Space -> CMYK
# This makes PyMOL render with CMYK-friendly display colors.
# Final PNG is still RGB/RGBA; convert to CMYK TIFF/PDF later if the journal requires a true CMYK file.
PYMOL_COLOR_SPACE = "cmyk"

LIGAND_COLOR = "tints_lightpink"
HBOND_RES_COLORS = [
    "tints_lightblue",
    "tints_lightgreen",
    "tints_lightorange",
    "tints_lightpurple",
    "tints_lightcyan",
    "tints_lightyellow",
    "tints_lightteal",
    "tints_lightrose",
]
NEAR_POCKET_COLOR = "tints_lightgreen"
DASH_COLOR = "yellow"
LABEL_COLOR = "black"

# Transparency in PyMOL = 1 - opacity
# Requested opacity: focus 20%, overview 60%
FOCUS_CARTOON_TRANSPARENCY = 0.20
OVERVIEW_CARTOON_TRANSPARENCY = 0.60

# If your summary file columns differ, add aliases here.
FIELD_ALIASES = {
    "receptor": ["Receptor", "receptor", "Target", "target"],
    "ligand": ["Ligand", "ligand"],
    "pose": ["Selected_pose", "selected_pose", "Pose", "pose", "best_pose"],
    "energy": ["Energy_kcal_mol", "energy", "Energy", "binding_energy"],
    "hbond_count": ["Hbond_count", "hbond_count", "HBond_count", "n_hbonds"],
    "residues": ["Receptor_residues", "residues", "Residues", "hbond_residues"],
}

# =========================
# Helpers
# =========================

def _norm_header(h):
    if h is None:
        return ""
    return str(h).strip().lower()


def find_existing_field(row, logical_key):
    aliases = FIELD_ALIASES.get(logical_key, [logical_key])
    norm_map = {}
    for k in row.keys():
        if k is None:
            continue
        nk = _norm_header(k)
        if nk:
            norm_map[nk] = k
    for alias in aliases:
        real = norm_map.get(_norm_header(alias))
        if real is not None:
            return real
    return None


def _clean_line(line):
    return line.strip().replace("\ufeff", "")



def read_work_dir_from_summary(summary_file):
    try:
        text = Path(summary_file).read_text(encoding="utf-8-sig", errors="ignore")
    except Exception:
        return ""
    for line in text.splitlines():
        if line.lower().startswith("work directory:"):
            return line.split(":", 1)[1].strip()
    return ""


def _split_table_line(line):
    """
    Support tab-separated ChimeraX summary, comma-separated csv,
    or whitespace-aligned txt table.
    """
    line = _clean_line(line)
    if not line:
        return []
    if "\t" in line:
        return [x.strip() for x in line.split("\t")]
    if "," in line and line.count(",") >= 2:
        return [x.strip() for x in line.split(",")]
    parts = re.split(r"\s{2,}", line)
    if len(parts) <= 1:
        parts = line.split()
    return [x.strip() for x in parts if x.strip()]


def _row_to_record(raw):
    r_field = find_existing_field(raw, "receptor")
    l_field = find_existing_field(raw, "ligand")
    p_field = find_existing_field(raw, "pose")
    if not (r_field and l_field and p_field):
        return None

    receptor = (raw.get(r_field) or "").strip()
    ligand = (raw.get(l_field) or "").strip()
    pose_txt = (raw.get(p_field) or "").strip()
    if not receptor or not ligand or not pose_txt:
        return None

    e_field = find_existing_field(raw, "energy")
    h_field = find_existing_field(raw, "hbond_count")
    res_field = find_existing_field(raw, "residues")

    try:
        pose = int(float(re.sub(r"[^0-9.]+", "", pose_txt)))
    except Exception:
        return None

    energy = None
    if e_field and str(raw.get(e_field, "")).strip() != "":
        try:
            energy = float(str(raw[e_field]).strip())
        except Exception:
            pass

    hbond_count = 0
    if h_field and str(raw.get(h_field, "")).strip() != "":
        try:
            hbond_count = int(float(str(raw[h_field]).strip()))
        except Exception:
            pass

    residues_text = ""
    if res_field:
        residues_text = (raw.get(res_field) or "").strip()

    return {
        "receptor": receptor,
        "ligand": ligand,
        "pose": pose,
        "energy": energy,
        "hbond_count": hbond_count,
        "residues_text": residues_text,
    }


def read_summary_table(summary_file):
    """
    Robust parser for either:
    1) normal CSV/TSV file;
    2) txt report containing a selected-result table, e.g.
       ===== SELECTED RESULT PER RECEPTOR-LIGAND PAIR =====
       Receptor    Ligand    Selected_pose ...
       OR1A1       Linalool  1 ...
    """
    text = Path(summary_file).read_text(encoding="utf-8-sig", errors="ignore")
    lines = text.splitlines()

    header_idx = None
    headers = None
    for i, line in enumerate(lines):
        low = line.lower()
        if ("receptor" in low and "ligand" in low and ("pose" in low or "selected_pose" in low)):
            cand = _split_table_line(line)
            if len(cand) >= 3:
                header_idx = i
                headers = cand
                break

    records = []
    if header_idx is not None and headers is not None:
        for line in lines[header_idx + 1:]:
            clean = _clean_line(line)
            if not clean:
                if records:
                    break
                continue
            if clean.startswith("===== ALL POSES DETAIL"):
                break
            if clean.startswith("="):
                if records:
                    break
                continue
            if set(clean) <= {"-", " ", "\t"}:
                continue

            parts = _split_table_line(line)
            if len(parts) < 3:
                if records:
                    break
                continue

            if len(parts) > len(headers):
                parts = parts[:len(headers)-1] + [" ".join(parts[len(headers)-1:])]
            elif len(parts) < len(headers):
                parts += [""] * (len(headers) - len(parts))

            raw = dict(zip(headers, parts))
            rec = _row_to_record(raw)
            if rec is not None:
                records.append(rec)

        if records:
            return records

    for delim in ["\t", ",", ";", "|"]:
        try:
            f_lines = [ln for ln in lines if ln.strip()]
            if not f_lines:
                continue
            reader = csv.DictReader(f_lines, delimiter=delim)
            tmp = []
            for raw in reader:
                if not raw:
                    continue
                raw = {k: v for k, v in raw.items() if k is not None}
                rec = _row_to_record(raw)
                if rec is not None:
                    tmp.append(rec)
            if tmp:
                return tmp
        except Exception:
            pass

    return records


def parse_residues(res_text):
    """
    Parse residue strings like:
      ASN109(A)
      ASN-109(A)
      ASN109
      ASN-109
      ASN109(A), TYR181(A)
      ASN109(A);TYR181(B)
    Returns list of dicts: [{resn:'ASN', resi:'109', chain:'A'} ...]
    """
    residues = []
    if not res_text or res_text.lower() in {"none", "na", "n/a", "-"}:
        return residues

    # Find all occurrences with optional chain
    pattern = re.compile(r"([A-Za-z]{3})[-\s]?([0-9]+)(?:\(([A-Za-z0-9])\))?", re.I)
    seen = set()
    for m in pattern.finditer(res_text):
        resn = m.group(1).upper()
        resi = m.group(2)
        chain = m.group(3) if m.group(3) else ""
        key = (resn, resi, chain)
        if key not in seen:
            residues.append({"resn": resn, "resi": resi, "chain": chain})
            seen.add(key)
    return residues


def residue_selector(res_list):
    sels = []
    for r in res_list:
        if r["chain"]:
            sels.append(f"(chain {r['chain']} and resn {r['resn']} and resi {r['resi']})")
        else:
            sels.append(f"(resn {r['resn']} and resi {r['resi']})")
    if not sels:
        return "none"
    return " or ".join(sels)


def safe_name(text):
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", str(text))


def _is_model_line(line):
    return line.strip().upper().startswith("MODEL")


def _is_endmdl_line(line):
    return line.strip().upper().startswith("ENDMDL")


def read_pdbqt_pose_blocks(pdbqt_file):
    """
    Read a Vina output PDBQT and return one text block per pose.

    PyMOL can load PDBQT, but in some versions it does not convert Vina's
    MODEL/ENDMDL sections into PyMOL states.  ChimeraX does, which is why the
    same file can show 9 poses in ChimeraX while PyMOL reports only 1 state.
    To avoid depending on PyMOL's state parser, we split the PDBQT ourselves.
    """
    path = Path(pdbqt_file)
    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines(keepends=True)
    if not any(line.strip() for line in lines):
        return []

    blocks = []
    current = []
    preamble = []
    in_model = False
    saw_model = False

    for line in lines:
        if _is_model_line(line):
            saw_model = True
            if in_model and current:
                blocks.append(current)
            current = preamble + [line]
            preamble = []
            in_model = True
            continue

        if in_model:
            current.append(line)
            if _is_endmdl_line(line):
                blocks.append(current)
                current = []
                in_model = False
            continue

        if not saw_model:
            # Preserve comments/REMARKs before the first MODEL, if present.
            preamble.append(line)

    if in_model and current:
        blocks.append(current)

    # If the file is not MODEL/ENDMDL-style, treat the whole file as one pose.
    if not saw_model:
        return [lines]
    return blocks


def extract_pdbqt_pose_to_file(pdbqt_file, desired_pose, receptor, ligand):
    """Extract desired Vina pose to a single-pose temporary PDBQT for PyMOL."""
    blocks = read_pdbqt_pose_blocks(pdbqt_file)
    pose_count = len(blocks)
    if pose_count == 0:
        raise RuntimeError(f"Docking PDBQT is empty or unreadable: {pdbqt_file}")
    if desired_pose < 1 or desired_pose > pose_count:
        raise RuntimeError(
            f"Requested pose {desired_pose}, but PDBQT file has only {pose_count} MODEL pose(s): {pdbqt_file}"
        )

    # For a real single-pose file without MODEL records, loading it directly is fine.
    if pose_count == 1 and not any(_is_model_line(line) for line in blocks[0]):
        return Path(pdbqt_file), pose_count

    pose_tmp_dir = Path(OUTPUT_DIR) / "_pymol_pose_extract"
    pose_tmp_dir.mkdir(parents=True, exist_ok=True)
    pose_file = pose_tmp_dir / f"{safe_name(receptor)}_{safe_name(ligand)}_pose{desired_pose}.pdbqt"
    pose_file.write_text("".join(blocks[desired_pose - 1]), encoding="utf-8")
    return pose_file, pose_count


def load_selected_pdbqt_pose(pdbqt_file, desired_pose, pose_obj, receptor, ligand):
    """Load exactly one selected Vina pose as a normal PyMOL object."""
    pose_file, pose_count = extract_pdbqt_pose_to_file(pdbqt_file, desired_pose, receptor, ligand)
    print(f"[INFO] Loading pose {desired_pose}/{pose_count} from {Path(pdbqt_file).name}")
    cmd.load(str(pose_file), pose_obj)
    atom_count = cmd.count_atoms(pose_obj)
    if atom_count <= 0:
        raise RuntimeError(
            f"PyMOL loaded zero atoms for pose {desired_pose} from extracted file: {pose_file}"
        )
    return pose_file, pose_count


def define_custom_colors():
    """
    Robust BioRender-like tint colors.
    These are defined manually so the script does not depend on whether
    a specific PyMOL installation knows a color name such as 'lavender'.
    """
    cmd.set_color("tints_lightpink",   [1.00, 0.72, 0.82])
    cmd.set_color("tints_lightblue",   [0.62, 0.82, 1.00])
    cmd.set_color("tints_lightgreen",  [0.62, 0.90, 0.66])
    cmd.set_color("tints_lightorange", [1.00, 0.72, 0.42])
    cmd.set_color("tints_lightpurple", [0.76, 0.68, 1.00])
    cmd.set_color("tints_lightcyan",   [0.58, 0.92, 0.94])
    cmd.set_color("tints_lightyellow", [1.00, 0.88, 0.42])
    cmd.set_color("tints_lightteal",   [0.50, 0.86, 0.78])
    cmd.set_color("tints_lightrose",   [1.00, 0.62, 0.68])
    cmd.set_color("hbond_dash_gray",   [0.25, 0.25, 0.25])


def setup_global_style():
    define_custom_colors()

    # Maximum Quality (same as PyMOL: util.performance(0)).
    # IMPORTANT: call this only once in main(), not once per receptor-ligand pair,
    # otherwise PyMOL prints the long "Setting: ..." block every loop.
    util.performance(0)
    cmd.bg_color(BG_COLOR)

    # Display -> Color Space -> CMYK
    # In PyMOL this is a command ('space cmyk'), not a normal setting.
    try:
        cmd.do(f"space {PYMOL_COLOR_SPACE}")
    except Exception as e:
        print(f"[WARN] Could not set PyMOL color space to {PYMOL_COLOR_SPACE}: {e}")

    # Keep transparent-background export enabled.
    cmd.set("ray_opaque_background", 0 if TRANSPARENT_BACKGROUND else 1)
    cmd.set("opaque_background", 0 if TRANSPARENT_BACKGROUND else 1)

    # Keep publication-style rendering preferences.
    cmd.set("orthoscopic", 1)
    cmd.set("cartoon_fancy_helices", 1)
    cmd.set("cartoon_smooth_loops", 1)
    cmd.set("cartoon_side_chain_helper", 0)
    cmd.set("stick_radius", 0.18)
    cmd.set("dash_gap", 0.25)
    cmd.set("dash_radius", 0.08)
    cmd.set("dash_length", 0.18)
    cmd.set("label_font_id", 7)
    cmd.set("label_color", LABEL_COLOR)
    cmd.set("label_size", 22)
    cmd.set("label_outline_color", "white")
    cmd.set("float_labels", 1)
    cmd.set("valence", 0)
    cmd.set("scene_buttons", 0)


def clear_pymol_scene():
    """
    Clear the previous receptor/ligand scene but keep global PyMOL settings.
    Do not use cmd.reinitialize() here, because it resets PyMOL settings and
    forces util.performance(0) to be called again in every render loop.
    """
    try:
        for name in list(cmd.get_names("all")):
            try:
                cmd.delete(name)
            except Exception:
                pass
    except Exception:
        cmd.delete("all")


def _first_existing_path(paths, kind):
    for p in paths:
        if p and Path(p).exists():
            return Path(p)
    msg = f"{kind} file not found. Tried:\n" + "\n".join(str(Path(p)) for p in paths if p)
    raise FileNotFoundError(msg)


def _active_receptor_dir(work_dir):
    if RECEPTOR_DIR and str(RECEPTOR_DIR).strip():
        return Path(RECEPTOR_DIR)
    return Path(work_dir) / "receptor"


def _active_docking_dir(work_dir):
    if DOCKING_DIR and str(DOCKING_DIR).strip():
        return Path(DOCKING_DIR)
    return Path(work_dir) / "Docking_Results_Parallel"


def find_receptor_file(work_dir, receptor):
    receptor_dir = _active_receptor_dir(work_dir)
    candidates = [
        receptor_dir / f"{receptor}{RECEPTOR_SUFFIX}",
        Path(work_dir) / f"{receptor}{RECEPTOR_SUFFIX}",
    ]
    return _first_existing_path(candidates, "Receptor")


def find_docking_file(work_dir, receptor, ligand):
    docking_dir = _active_docking_dir(work_dir)
    candidates = [
        docking_dir / ligand / f"{receptor}_{ligand}{DOCK_SUFFIX}",
        docking_dir / f"{receptor}_{ligand}{DOCK_SUFFIX}",
        Path(work_dir) / f"{receptor}_{ligand}{DOCK_SUFFIX}",
    ]
    return _first_existing_path(candidates, "Docking result")


def build_complex(record):
    receptor = record["receptor"]
    ligand = record["ligand"]
    pose = record["pose"]

    work_dir = get_active_work_dir()
    receptor_file = find_receptor_file(work_dir, receptor)
    dock_file = find_docking_file(work_dir, receptor, ligand)

    clear_pymol_scene()

    receptor_obj = "receptor"
    pose_obj = "pose_selected"
    cmd.load(str(receptor_file), receptor_obj)

    # Do not rely on PyMOL's PDBQT multi-state detection.  Some PyMOL builds load
    # Vina MODEL/ENDMDL output as one state, causing pose 2/3/9 to be rejected even
    # when the PDBQT really contains multiple poses.  Split the PDBQT text first and
    # load only the selected pose as a single PyMOL object.
    load_selected_pdbqt_pose(dock_file, pose, pose_obj, receptor, ligand)

    # Basic representation
    cmd.hide("everything", "all")
    cmd.show("cartoon", receptor_obj)
    cmd.spectrum("count", "rainbow", receptor_obj)

    # Ligand + hydrogen-bond residues shown as sticks.
    cmd.show("sticks", pose_obj)
    cmd.color(LIGAND_COLOR, pose_obj)

    # Residue selection from summary
    hb_res_list = parse_residues(record.get("residues_text", ""))
    hb_res_sel = residue_selector(hb_res_list)

    cmd.select("hbond_res", "none")
    cmd.select("focus_res", "none")

    if hb_res_list:
        cmd.select("hbond_res", f"{receptor_obj} and ({hb_res_sel})")
        cmd.select("focus_res", "hbond_res")
        pocket_kind = "hbond_residues"

        # Show and color each hydrogen-bond residue separately.
        for i, r in enumerate(hb_res_list):
            sel_name = f"hbond_res_{i+1}"
            if r["chain"]:
                sel_expr = f"{receptor_obj} and chain {r['chain']} and resn {r['resn']} and resi {r['resi']}"
            else:
                sel_expr = f"{receptor_obj} and resn {r['resn']} and resi {r['resi']}"
            cmd.select(sel_name, sel_expr)
            cmd.show("sticks", sel_name)
            cmd.color(HBOND_RES_COLORS[i % len(HBOND_RES_COLORS)], sel_name)
    else:
        pocket_kind = "near_pocket"
        cmd.select("focus_res", f"byres ({receptor_obj} within {POCKET_CUTOFF_IF_NO_HBOND} of {pose_obj})")
        if SHOW_NEAR_POCKET_IF_NO_HBOND:
            cmd.show("sticks", "focus_res")
            cmd.color(NEAR_POCKET_COLOR, "focus_res")

    # Keep ligand and selected residues above cartoon visually
    cmd.set("cartoon_side_chain_helper", 0, receptor_obj)
    cmd.show("sticks", pose_obj)
    if hb_res_list:
        for i in range(len(hb_res_list)):
            cmd.show("sticks", f"hbond_res_{i+1}")

    return receptor_obj, pose_obj, hb_res_list, pocket_kind


def make_offset_residue_labels(hb_res_list):
    """
    Put residue labels on invisible pseudoatoms with small 3D offsets,
    instead of labeling CA atoms directly. This reduces label overlap.
    """
    cmd.delete("residue_labels")
    if not hb_res_list:
        return

    offsets = [
        (2.6, 1.4, 0.8),
        (-2.6, 1.4, 0.8),
        (2.2, -1.6, 1.0),
        (-2.2, -1.6, 1.0),
        (1.5, 2.4, -0.7),
        (-1.5, 2.4, -0.7),
        (1.2, -2.4, -0.8),
        (-1.2, -2.4, -0.8),
    ]

    for i, r in enumerate(hb_res_list):
        sel = f"hbond_res_{i+1} and name CA"
        model = cmd.get_model(sel)
        if not model.atom:
            model = cmd.get_model(f"hbond_res_{i+1}")
        if not model.atom:
            continue

        x = sum(a.coord[0] for a in model.atom) / len(model.atom)
        y = sum(a.coord[1] for a in model.atom) / len(model.atom)
        z = sum(a.coord[2] for a in model.atom) / len(model.atom)
        dx, dy, dz = offsets[i % len(offsets)]
        label_obj = f"residue_label_{i+1}"
        label_text = f"{r['resn']}-{r['resi']}"
        cmd.pseudoatom(label_obj, pos=[x + dx, y + dy, z + dz], label=label_text)
        cmd.hide("everything", label_obj)
        cmd.show("labels", label_obj)
        cmd.group("residue_labels", label_obj)


def render_png(out_file):
    """Save current PyMOL view using either ray or draw rendering."""
    if not OUTPUT_IMAGES:
        return
    out_file = str(out_file)
    if RENDER_ENGINE == "draw":
        # draw is faster than ray and uses PyMOL's OpenGL renderer.
        # In this pipeline, choosing draw forces No-GUI mode at the shell level.
        try:
            cmd.draw(IMG_W, IMG_H, 2)
        except TypeError:
            try:
                cmd.draw(IMG_W, IMG_H)
            except Exception as e:
                print(f"[WARN] cmd.draw failed ({e}); falling back to png ray=0.")
        cmd.png(out_file, width=IMG_W, height=IMG_H, dpi=IMG_DPI, ray=0)
    else:
        cmd.png(out_file, width=IMG_W, height=IMG_H, dpi=IMG_DPI, ray=1)


def make_overview(record, receptor_obj, pose_obj, out_file=None):
    cmd.set("cartoon_transparency", OVERVIEW_CARTOON_TRANSPARENCY, receptor_obj)
    cmd.hide("labels", "all")
    cmd.delete("hbonds")

    # This view direction will also be used by the focus image.
    cmd.orient(f"{receptor_obj} or {pose_obj}")
    cmd.zoom(f"{receptor_obj} or {pose_obj}", buffer=OVERVIEW_BUFFER)

    # Relax clipping planes so nothing is cut away.
    cmd.clip("slab", CLIP_SLAB)
    cmd.clip("near", NEAR_CLIP_RELAX)

    overview_view = cmd.get_view()
    if OUTPUT_IMAGES and out_file is not None:
        render_png(out_file)
    return overview_view


def make_focus(record, receptor_obj, pose_obj, hb_res_list, pocket_kind, out_file=None, overview_view=None):
    cmd.set("cartoon_transparency", FOCUS_CARTOON_TRANSPARENCY, receptor_obj)
    cmd.hide("labels", "all")
    cmd.delete("hbonds")

    if hb_res_list:
        # Only use residues already identified in the summary file.
        cmd.distance("hbonds", pose_obj, "hbond_res", HBOND_CUTOFF, mode=2)
        cmd.color(DASH_COLOR, "hbonds")
        cmd.show("dashes", "hbonds")
        cmd.hide("labels", pose_obj)

        # Offset labels for cleaner publication-style focus panels.
        make_offset_residue_labels(hb_res_list)
    else:
        # No-hbond selected poses: by default do not label surrounding residues.
        if (not LABEL_ONLY_HBOND_RESIDUES) and SHOW_NEAR_POCKET_IF_NO_HBOND:
            cmd.label("focus_res and name CA", '"%s-%s" % (resn, resi)')

    # Keep exactly the same viewing direction as overview, then only change the zoom.
    if overview_view is not None:
        cmd.set_view(overview_view)
    else:
        cmd.orient(f"{receptor_obj} or {pose_obj}")

    if hb_res_list:
        cmd.zoom(f"{pose_obj} or hbond_res", buffer=FOCUS_BUFFER)
    else:
        cmd.zoom(f"{pose_obj} or focus_res", buffer=FOCUS_BUFFER)

    # Relax clipping planes so nothing is cut away.
    cmd.clip("slab", CLIP_SLAB)
    cmd.clip("near", NEAR_CLIP_RELAX)

    if OUTPUT_IMAGES and out_file is not None:
        render_png(out_file)


def get_active_work_dir():
    global WORK_DIR
    if WORK_DIR and str(WORK_DIR).strip():
        return Path(WORK_DIR)
    parsed = read_work_dir_from_summary(SUMMARY_FILE)
    if parsed:
        WORK_DIR = parsed
        print(f"[INFO] WORK_DIR auto-read from summary: {WORK_DIR}")
        return Path(WORK_DIR)
    raise RuntimeError("WORK_DIR is empty and no 'Work directory:' line was found in SUMMARY_FILE.")


def ensure_dirs(base_dir):
    base = Path(base_dir)
    overview_dir = base / "overview"
    focus_dir = base / "focus"
    pse_dir = base / "focus_pse"
    if OUTPUT_IMAGES:
        overview_dir.mkdir(parents=True, exist_ok=True)
        focus_dir.mkdir(parents=True, exist_ok=True)
    if OUTPUT_PSE:
        pse_dir.mkdir(parents=True, exist_ok=True)
    return overview_dir, focus_dir, pse_dir


def main():
    overview_dir, focus_dir, pse_dir = ensure_dirs(OUTPUT_DIR)
    records = read_summary_table(SUMMARY_FILE)
    if not records:
        raise RuntimeError(
            "No valid rows were parsed from the summary file. "
            "This compatible version expects the ChimeraX txt section headed by "
            "'===== SELECTED RESULT PER RECEPTOR-LIGAND PAIR =====' and columns "
            "Receptor, Ligand, Selected_pose, Energy_kcal_mol, Selection_rule, "
            "Hbond_count, Receptor_residues."
        )

    requested_receptors = set(RECEPTORS) if RECEPTORS else None
    if requested_receptors:
        records = [r for r in records if r["receptor"] in requested_receptors]

    setup_global_style()

    print(f"[INFO] Output mode: {OUTPUT_MODE} (PSE={OUTPUT_PSE}, images={OUTPUT_IMAGES})")
    if OUTPUT_IMAGES:
        print(f"[INFO] Render engine: {RENDER_ENGINE}")
    print(f"[INFO] Parsed {len(records)} selected docking records from summary file.")
    failed = []
    success = 0

    for idx, rec in enumerate(records, start=1):
        name_core = f"{safe_name(rec['receptor'])}_{safe_name(rec['ligand'])}_pose{rec['pose']}"
        ov_file = overview_dir / f"{name_core}_overview.png"
        fc_file = focus_dir / f"{name_core}_focus.png"

        action_text = "Processing" if OUTPUT_MODE == "pse" else "Rendering"
        print(
            f"[INFO] ({idx}/{len(records)}) {action_text} {rec['receptor']} vs {rec['ligand']} "
            f"pose {rec['pose']}"
        )
        try:
            receptor_obj, pose_obj, hb_res_list, pocket_kind = build_complex(rec)
            overview_view = make_overview(rec, receptor_obj, pose_obj, ov_file if OUTPUT_IMAGES else None)
            make_focus(rec, receptor_obj, pose_obj, hb_res_list, pocket_kind, fc_file if OUTPUT_IMAGES else None, overview_view=overview_view)
            if OUTPUT_PSE:
                pse_file = pse_dir / f"{name_core}_focus.pse"
                cmd.save(str(pse_file))
            success += 1
        except Exception as e:
            failed.append((rec, str(e)))
            print(f"[ERROR] {rec['receptor']} vs {rec['ligand']} pose {rec['pose']}: {e}")

    print("\n========== DONE ==========")
    print(f"Success: {success}")
    print(f"Failed : {len(failed)}")
    if OUTPUT_IMAGES:
        print(f"Overview images: {overview_dir}")
        print(f"Focus images   : {focus_dir}")
    if OUTPUT_PSE:
        print(f"Focus PSE files: {pse_dir}")

    if failed:
        log_file = Path(OUTPUT_DIR) / "render_failures.txt"
        with open(log_file, "w", encoding="utf-8") as f:
            for rec, err in failed:
                f.write(
                    f"{rec['receptor']}\t{rec['ligand']}\tpose {rec['pose']}\t{err}\n"
                )
        print(f"Failure log    : {log_file}")


# Run immediately when loaded in PyMOL
main()
PYMOL_FINAL_PYEOF
}

step_pymol_final_visualization() {  # Step 5/6: 根据ChimeraX汇总结果批量生成PyMOL最终图和/或focus PSE
    cd "$WORK_DIR_ABS" || return 1

    [ -n "${PYMOL_CMD:-}" ] || { echo "错误: 未设置PyMOL程序路径"; return 1; }
    [ -d "$RECEPTOR_DIR_ABS" ] || { echo "错误: receptor目录不存在: $RECEPTOR_DIR_ABS"; return 1; }
    [ -d "$DOCK_OUT_DIR_ABS" ] || { echo "错误: Vina结果目录不存在: $DOCK_OUT_DIR_ABS"; return 1; }
    [ -f "$PYMOL_FINAL_SUMMARY_ABS" ] || { echo "错误: 找不到ChimeraX结果TXT: $PYMOL_FINAL_SUMMARY_ABS"; return 1; }

    write_pymol_final_visualization_script || return 1

    export PYMOL_VINA_SUMMARY_FILE="$(to_native_path "$PYMOL_FINAL_SUMMARY_ABS")"
    export PYMOL_VINA_WORK_DIR="$(to_native_path "$WORK_DIR_ABS")"
    export PYMOL_VINA_RECEPTOR_DIR="$(to_native_path "$RECEPTOR_DIR_ABS")"
    export PYMOL_VINA_DOCKING_DIR="$(to_native_path "$DOCK_OUT_DIR_ABS")"
    export PYMOL_VINA_OUTPUT_DIR="$(to_native_path "$PYMOL_FINAL_OUT_DIR_ABS")"
    export PYMOL_VINA_RECEPTORS="${PYMOL_FINAL_RECEPTORS:-}"
    export PYMOL_VINA_OUTPUT_MODE="${PYMOL_FINAL_OUTPUT_MODE:-both}"
    export PYMOL_VINA_SAVE_FOCUS_PSE="${PYMOL_FINAL_SAVE_PSE:-1}"
    export PYMOL_VINA_RENDER_ENGINE="${PYMOL_FINAL_RENDER_ENGINE:-ray}"

    local mode_text render_text output_text
    render_text="${PYMOL_FINAL_RENDER_ENGINE:-ray}"
    output_text="${PYMOL_FINAL_OUTPUT_MODE:-both}"
    if [ "${PYMOL_FINAL_RENDER_ENGINE:-ray}" = "draw" ]; then
        PYMOL_FINAL_ARGS=(-cq "$(to_native_path "$PYMOL_FINAL_SCRIPT_ABS")")
        mode_text="No-GUI（draw自动禁用GUI）"
    elif [ "${PYMOL_FINAL_MODE:-2}" = "2" ]; then
        PYMOL_FINAL_ARGS=(-cq "$(to_native_path "$PYMOL_FINAL_SCRIPT_ABS")")
        mode_text="No-GUI"
    else
        PYMOL_FINAL_ARGS=(-r "$(to_native_path "$PYMOL_FINAL_SCRIPT_ABS")")
        mode_text="GUI"
    fi

    bar
    echo "开始 PyMOL 最终可视化"
    echo "ChimeraX结果TXT: $PYMOL_FINAL_SUMMARY_ABS"
    echo "受体目录: $RECEPTOR_DIR_ABS"
    echo "Vina结果目录: $DOCK_OUT_DIR_ABS"
    echo "输出目录: $PYMOL_FINAL_OUT_DIR_ABS"
    case "$output_text" in
        pse) echo "输出内容: 仅输出PSE文件" ;;
        image) echo "输出内容: 仅渲染图像" ;;
        both) echo "输出内容: 输出PSE文件和渲染图像" ;;
        *) echo "输出内容: $output_text" ;;
    esac
    [ "$render_text" != "none" ] && echo "渲染方式: $render_text"
    echo "运行模式: $mode_text"
    [ -n "${PYMOL_FINAL_RECEPTORS:-}" ] && echo "指定受体: $PYMOL_FINAL_RECEPTORS" || echo "指定受体: 读取TXT全部结果"
    bar

    "$PYMOL_CMD" "${PYMOL_FINAL_ARGS[@]}"
    local exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo "PyMOL最终可视化完成: $PYMOL_FINAL_OUT_DIR_ABS"
    else
        echo "错误: PyMOL最终可视化失败，退出码: $exit_code"
        return "$exit_code"
    fi
}

run_all() {  # 全流程串联运行，中途任一步失败就停止
    if [ "${RUN_CHIMERAX_AFTER:-0}" -eq 1 ] && [ "${RUN_PYMOL_FINAL_AFTER:-0}" -eq 1 ]; then
        echo "将依次运行: SDF→PDB、配体PDB→PDBQT、可选受体处理、Vina对接、ChimeraX氢键分析、PyMOL最终可视化"
    elif [ "${RUN_CHIMERAX_AFTER:-0}" -eq 1 ]; then
        echo "将依次运行: SDF→PDB、配体PDB→PDBQT、可选受体处理、Vina对接、ChimeraX氢键分析"
    else
        echo "将依次运行: SDF→PDB、配体PDB→PDBQT、可选受体处理、Vina对接"
    fi
    step_sdf_to_pdb || return 1
    step_pdb_to_pdbqt || return 1
    if [ "${RUN_RECEPTOR_PDBQT_PREP:-0}" -eq 1 ]; then
        step_receptor_pdb_to_pdbqt || return 1
    fi
    if [ "${RUN_P2RANK_BEFORE_VINA:-0}" -eq 1 ]; then
        step_p2rank_generate_configs || return 1
    fi
    step_vina_docking || return 1
    if [ "${RUN_CHIMERAX_AFTER:-0}" -eq 1 ]; then
        step_chimerax_analysis || return 1
    fi
    if [ "${RUN_PYMOL_FINAL_AFTER:-0}" -eq 1 ]; then
        step_pymol_final_visualization || return 1
    fi
}

execute_choice() {
    case "$choice" in
        1) step_sdf_to_pdb ;;
        2) step_pdb_to_pdbqt ;;
        3)
            if [ "${RUN_RECEPTOR_PDBQT_PREP:-0}" -eq 1 ]; then
                step_receptor_pdb_to_pdbqt || return 1
            fi
            if [ "${RUN_P2RANK_BEFORE_VINA:-0}" -eq 1 ]; then
                step_p2rank_generate_configs || return 1
            fi
            step_vina_docking || return 1
            if [ "${RUN_CHIMERAX_AFTER:-0}" -eq 1 ]; then
                step_chimerax_analysis || return 1
            fi
            if [ "${RUN_PYMOL_FINAL_AFTER:-0}" -eq 1 ]; then
                step_pymol_final_visualization || return 1
            fi
            ;;
        4) run_all ;;
        5)
            step_chimerax_analysis || return 1
            if [ "${RUN_PYMOL_FINAL_AFTER:-0}" -eq 1 ]; then
                step_pymol_final_visualization || return 1
            fi
            ;;
        6) step_pymol_final_visualization ;;
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
    echo "6) PyMOL 可视化"
    echo "0) 退出"
    read -r -p "选择一个流程 [默认: 4]: " choice
    [ -z "$choice" ] && choice=4
    [ "$choice" = "0" ] && exit 0
    collect_all_inputs || exit 1
    execute_choice
}

main_menu
