# -*- coding: utf-8 -*-
"""
ChimeraX batch script for AutoDock Vina PDBQT results.

This pipeline version can read directly from the normal AutoDock pipeline layout:
    receptor_dir/
        OR1A1.pdbqt
        OR1D2.pdbqt
        ...
    Docking_Results_Parallel/
        Linalool/
            OR1A1_Linalool_out.pdbqt
            OR1D2_Linalool_out.pdbqt
        alphaTerpineol/
            OR1A1_alphaTerpineol_out.pdbqt

It also remains compatible with the older flat layout where receptor PDBQT files
and *_out.pdbqt files are in the same WORK_DIR.

The Shell pipeline passes paths through environment variables:
    CHIMERAX_WORK_DIR
    CHIMERAX_RECEPTOR_DIR
    CHIMERAX_DOCKING_DIR
    CHIMERAX_OUTPUT_TXT
    CHIMERAX_RECEPTORS
    CHIMERAX_RELAX_HBOND_CRITERIA
    CHIMERAX_PRINT_EACH_POSE
    CHIMERAX_KEEP_HBOND_DETAIL_FILES
    CHIMERAX_HYDROPHOBIC_CONTACT_DISTANCE
    CHIMERAX_HYDROPHOBIC_RESIDUES
"""

from pathlib import Path
import os
import re
import tempfile
import traceback
import time

from chimerax.core.commands import run

# ===================== DEFAULT USER SETTINGS =====================
# These defaults are used only when the script is run directly without the shell pipeline.
WORK_DIR = r"[WORK DIR]"
RECEPTOR_DIR = ""      # Empty = WORK_DIR
DOCKING_DIR = ""       # Empty = WORK_DIR
RECEPTORS = []         # Empty = auto-detect receptor_dir/*.pdbqt
OUTPUT_TXT = ""        # Empty = docking_dir/vina_hbond_summary_with_progress.txt

RELAX_HBOND_CRITERIA = True
PRINT_EACH_POSE = True
KEEP_HBOND_DETAIL_FILES = False
CLOSE_ALL_AT_START = True
DEFAULT_OUTPUT_FILENAME = "vina_hbond_summary_with_progress.txt"

# Operational definition of hydrophobic/aromatic contacts:
# ligand carbon atoms within this distance (Angstrom) of receptor carbon atoms
# belonging to the listed hydrophobic/aromatic residues.
HYDROPHOBIC_CONTACT_DISTANCE = 4.2
HYDROPHOBIC_RESIDUES = [
    "ALA", "VAL", "LEU", "ILE", "MET", "PHE", "TRP", "PRO", "TYR", "CYS",
    "HIS", "HID", "HIE", "HIP"
]
# ================================================================

AA3 = {
    "ALA", "ARG", "ASN", "ASP", "CYS", "GLN", "GLU", "GLY", "HIS", "ILE",
    "LEU", "LYS", "MET", "PHE", "PRO", "SER", "THR", "TRP", "TYR", "VAL",
    "HID", "HIE", "HIP", "CYX", "MSE", "SEC", "PYL"
}


def env_bool(name, default):
    value = os.environ.get(name)
    if value is None or str(value).strip() == "":
        return bool(default)
    return str(value).strip().lower() in {"1", "true", "yes", "y", "on", "是", "运行", "需要"}


def env_list(name, default):
    value = os.environ.get(name, "").strip()
    if not value:
        return list(default or [])
    return [x.strip() for x in re.split(r"[,;\s]+", value) if x.strip()]


def env_float(name, default):
    value = os.environ.get(name)
    if value is None or str(value).strip() == "":
        return float(default)
    try:
        return float(str(value).strip())
    except Exception:
        return float(default)


def effective_settings():
    work_dir = Path(os.environ.get("CHIMERAX_WORK_DIR", WORK_DIR)).expanduser()
    receptor_dir_raw = os.environ.get("CHIMERAX_RECEPTOR_DIR", RECEPTOR_DIR).strip()
    docking_dir_raw = os.environ.get("CHIMERAX_DOCKING_DIR", DOCKING_DIR).strip()

    receptor_dir = Path(receptor_dir_raw).expanduser() if receptor_dir_raw else work_dir
    docking_dir = Path(docking_dir_raw).expanduser() if docking_dir_raw else work_dir

    output_txt = os.environ.get("CHIMERAX_OUTPUT_TXT", OUTPUT_TXT).strip()
    receptors = env_list("CHIMERAX_RECEPTORS", RECEPTORS)
    hydrophobic_residues = [
        x.upper() for x in env_list("CHIMERAX_HYDROPHOBIC_RESIDUES", HYDROPHOBIC_RESIDUES)
    ]

    return {
        "work_dir": work_dir,
        "receptor_dir": receptor_dir,
        "docking_dir": docking_dir,
        "output_txt": output_txt,
        "receptors": receptors,
        "relax": env_bool("CHIMERAX_RELAX_HBOND_CRITERIA", RELAX_HBOND_CRITERIA),
        "print_each_pose": env_bool("CHIMERAX_PRINT_EACH_POSE", PRINT_EACH_POSE),
        "keep_details": env_bool("CHIMERAX_KEEP_HBOND_DETAIL_FILES", KEEP_HBOND_DETAIL_FILES),
        "hydrophobic_cutoff": env_float("CHIMERAX_HYDROPHOBIC_CONTACT_DISTANCE", HYDROPHOBIC_CONTACT_DISTANCE),
        "hydrophobic_residues": hydrophobic_residues,
    }


def log_msg(session, msg, also_status=True):
    """Print progress to ChimeraX Log and terminal."""
    try:
        session.logger.info(msg)
    except Exception:
        pass
    if also_status:
        try:
            session.logger.status(msg)
        except Exception:
            pass
    print(msg, flush=True)


def safe_name(s):
    return re.sub(r"[^A-Za-z0-9_.+-]+", "_", str(s))


def resolve_output_file(output_txt, docking_dir):
    """
    Resolve output path robustly.
    Important fix: if OUTPUT_TXT is a directory, append DEFAULT_OUTPUT_FILENAME instead of write_text() on the directory.
    """
    docking_dir = Path(docking_dir)
    if not output_txt:
        out = docking_dir / DEFAULT_OUTPUT_FILENAME
    else:
        out = Path(output_txt).expanduser()
        out_str = str(output_txt).strip()
        if out_str.endswith(("/", "\\")):
            out = out / DEFAULT_OUTPUT_FILENAME
        elif out.exists() and out.is_dir():
            out = out / DEFAULT_OUTPUT_FILENAME
        elif out.parent == Path("."):
            out = docking_dir / out

    if out.exists() and out.is_dir():
        out = out / DEFAULT_OUTPUT_FILENAME

    out.parent.mkdir(parents=True, exist_ok=True)
    return out


def parse_energy_from_lines(lines):
    """Parse Vina energy from REMARK VINA RESULT line."""
    for line in lines:
        m = re.search(r"REMARK\s+VINA\s+RESULT:\s*([-+]?\d+(?:\.\d+)?)", line, re.I)
        if m:
            return float(m.group(1))
    return None


def split_vina_pdbqt_to_poses(pdbqt_file, pose_dir):
    """
    Split a Vina output PDBQT file into single-pose PDBQT files.
    Returns list of dicts: {pose_index, energy, pose_file}
    """
    pdbqt_file = Path(pdbqt_file)
    text = pdbqt_file.read_text(encoding="utf-8", errors="ignore").splitlines(keepends=True)

    poses = []
    current = []
    current_pose_index = None
    saw_model = False

    def flush_pose():
        nonlocal current, current_pose_index
        if not current:
            return
        pose_idx = current_pose_index if current_pose_index is not None else len(poses) + 1
        energy = parse_energy_from_lines(current)
        out_file = Path(pose_dir) / f"{safe_name(pdbqt_file.stem)}__pose_{pose_idx:02d}.pdbqt"
        cleaned = [ln for ln in current if not ln.lstrip().upper().startswith(("MODEL", "ENDMDL"))]
        out_file.write_text("".join(cleaned), encoding="utf-8", errors="ignore")
        poses.append({"pose_index": pose_idx, "energy": energy, "pose_file": out_file})
        current = []
        current_pose_index = None

    for ln in text:
        stripped = ln.strip()
        upper = stripped.upper()
        if upper.startswith("MODEL"):
            saw_model = True
            flush_pose()
            current = [ln]
            parts = stripped.split()
            current_pose_index = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else len(poses) + 1
        elif upper.startswith("ENDMDL"):
            current.append(ln)
            flush_pose()
        else:
            current.append(ln)

    if current:
        flush_pose()

    return poses


def ligand_name_from_file(receptor_name, out_file):
    stem = Path(out_file).stem
    prefix = receptor_name + "_"
    suffix = "_out"
    if stem.startswith(prefix) and stem.endswith(suffix):
        return stem[len(prefix):-len(suffix)]
    if stem.startswith(prefix):
        return stem[len(prefix):]
    return stem


def model_spec_from_open_result(open_result, fallback):
    """Try to obtain #model_id from ChimeraX open command result."""
    try:
        if isinstance(open_result, (list, tuple)) and len(open_result) > 0:
            m = open_result[0]
            if hasattr(m, "id_string"):
                return "#" + m.id_string
    except Exception:
        pass
    return fallback


def extract_receptor_residues_from_hbond_lines(lines, receptor_spec="#1"):
    """
    Parse receptor residue names from hbonds saveFile lines using namingStyle simple.
    Example lines can contain model tags like #1/A or #1.1/A.
    """
    residues = set()
    receptor_tag = "#" + str(receptor_spec).lstrip("#")

    for line in lines:
        toks = line.replace("\t", " ").split()
        for i, tok in enumerate(toks):
            if not tok.startswith(receptor_tag):
                continue

            chain = ""
            j = i + 1

            rest = tok[len(receptor_tag):]
            if rest.startswith("/"):
                chain = rest[1:].strip().replace(":", "")

            if j < len(toks) and toks[j].startswith("/"):
                chain = toks[j].lstrip("/").replace(":", "")
                j += 1

            if j + 1 >= len(toks):
                continue

            resname = toks[j].upper().strip(" ,;:")
            resnum = toks[j + 1].strip(" ,;:")

            if resname in AA3 and re.match(r"^-?\d+[A-Za-z]?$", resnum):
                residues.add(f"{resname}{resnum}({chain})" if chain else f"{resname}{resnum}")

    def sort_key(x):
        m = re.search(r"-?\d+", x)
        return (re.sub(r"\d.*", "", x), int(m.group(0)) if m else 99999, x)

    return sorted(residues, key=sort_key)


def parse_hbond_savefile(hbond_file, receptor_spec="#1", ligand_spec="#2"):
    """Return hbond_count, receptor_residues, raw_data_lines from hbonds saveFile."""
    hbond_file = Path(hbond_file)
    if not hbond_file.exists():
        return 0, [], []

    text = hbond_file.read_text(encoding="utf-8", errors="ignore")
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]

    count = None
    for ln in lines:
        m = re.search(r"(\d+)\s+H[- ]?bonds?", ln, re.I)
        if m:
            count = int(m.group(1))
            break

    data_lines = []
    rec_tag = "#" + str(receptor_spec).lstrip("#")
    lig_tag = "#" + str(ligand_spec).lstrip("#")
    for ln in lines:
        if rec_tag in ln and lig_tag in ln:
            if re.search(r"donor|acceptor|distance|angle", ln, re.I):
                continue
            data_lines.append(ln)

    if count is None:
        count = len(data_lines)

    residues = extract_receptor_residues_from_hbond_lines(data_lines, receptor_spec=receptor_spec)
    return count, residues, data_lines


def source_label(path, base_dir):
    try:
        return str(Path(path).relative_to(base_dir))
    except Exception:
        return Path(path).name


def find_docking_outputs(docking_dir, receptor_name):
    """Find *_out.pdbqt for one receptor in both flat and nested Vina output layouts."""
    docking_dir = Path(docking_dir)
    pattern = f"{receptor_name}_*_out.pdbqt"
    found = []
    seen = set()
    for p in docking_dir.rglob(pattern):
        if not p.is_file():
            continue
        # Avoid re-reading detail/split pose files if users place details inside docking_dir.
        parts_lower = {part.lower() for part in p.parts}
        if "split_poses" in parts_lower or "chimerax_hbond_details" in parts_lower:
            continue
        rp = str(p.resolve())
        if rp not in seen:
            found.append(p)
            seen.add(rp)
    return sorted(found, key=lambda x: str(x).lower())


def find_jobs(receptor_dir, docking_dir, receptors, pose_dir, session):
    receptor_dir = Path(receptor_dir)
    docking_dir = Path(docking_dir)
    jobs = []

    if not receptors:
        receptors = sorted([
            p.stem for p in receptor_dir.glob("*.pdbqt")
            if not p.name.endswith("_out.pdbqt")
        ])
        log_msg(session, f"Auto-detected receptors from receptor_dir: {', '.join(receptors) if receptors else 'None'}")

    for rec in receptors:
        receptor_file = receptor_dir / f"{rec}.pdbqt"
        if not receptor_file.exists():
            log_msg(session, f"[WARNING] Receptor file not found: {receptor_file}")
            continue

        out_files = find_docking_outputs(docking_dir, rec)
        if not out_files:
            log_msg(session, f"[WARNING] No docking output files found for receptor {rec}: {docking_dir}/**/{rec}_*_out.pdbqt")
            continue

        for out_file in out_files:
            ligand = ligand_name_from_file(rec, out_file)
            poses = split_vina_pdbqt_to_poses(out_file, pose_dir)
            if not poses:
                log_msg(session, f"[WARNING] No poses parsed from: {out_file}")
                continue
            jobs.append({
                "receptor": rec,
                "ligand": ligand,
                "receptor_file": receptor_file,
                "out_file": out_file,
                "source_label": source_label(out_file, docking_dir),
                "poses": poses,
            })

    return jobs


def calculate_one_pose_hbonds(session, receptor_file, pose_file, hbond_file, relax=True):
    """Open receptor and one ligand pose, run hbonds, parse saveFile."""
    run(session, "close all")

    rec_result = run(session, f'open "{receptor_file}"')
    lig_result = run(session, f'open "{pose_file}"')

    rec_spec = model_spec_from_open_result(rec_result, "#1")
    lig_spec = model_spec_from_open_result(lig_result, "#2")

    relax_text = "true" if relax else "false"
    cmd = (
        f'hbonds {lig_spec} restrict {rec_spec} '
        f'interModel true intraModel false interSubmodel true '
        f'makePseudobonds false reveal false showDist false '
        f'relax {relax_text} batch true log false '
        f'namingStyle simple saveFile "{hbond_file}"'
    )
    run(session, cmd)

    hbond_count, residues, data_lines = parse_hbond_savefile(hbond_file, receptor_spec=rec_spec, ligand_spec=lig_spec)
    run(session, "close all")
    return hbond_count, residues, data_lines




def get_first_opened_model(open_result):
    """Return the first model object from a ChimeraX open command result."""
    if open_result is None:
        return None
    if isinstance(open_result, (list, tuple)) and len(open_result) > 0:
        return open_result[0]
    return open_result


def atom_element_symbol(atom):
    """Get an atom element symbol robustly; fall back to atom name when needed."""
    symbol = ""
    try:
        symbol = atom.element.name
    except Exception:
        symbol = ""
    if symbol:
        return str(symbol).upper()

    try:
        name = str(atom.name).strip().upper()
    except Exception:
        return ""
    # PDBQT atom names can include digits; use the leading alphabetic part as fallback.
    m = re.match(r"[A-Z]+", name)
    return m.group(0) if m else name[:1]


def is_carbon_atom(atom):
    return atom_element_symbol(atom) == "C"


def atom_xyz(atom):
    """Return atom coordinates in scene coordinates when available."""
    try:
        c = atom.scene_coord
    except Exception:
        c = atom.coord

    # ChimeraX Point/Place-compatible objects are usually indexable, but x/y/z may also exist.
    try:
        return float(c[0]), float(c[1]), float(c[2])
    except Exception:
        return float(c.x), float(c.y), float(c.z)


def residue_label_from_atom(atom):
    """Format residue label as RES123 or RES123(A)."""
    r = atom.residue
    resname = str(r.name).upper()
    resnum = str(r.number)
    chain = ""
    try:
        chain = str(r.chain_id).strip()
    except Exception:
        chain = ""
    label = f"{resname}{resnum}"
    if chain:
        label += f"({chain})"
    return label


def residue_sort_key(label):
    m = re.search(r"-?\d+", str(label))
    prefix = re.sub(r"\d.*", "", str(label))
    number = int(m.group(0)) if m else 99999
    return (prefix, number, str(label))


def calculate_one_pose_hydrophobic_contacts(
    session,
    receptor_file,
    pose_file,
    cutoff=HYDROPHOBIC_CONTACT_DISTANCE,
    hydrophobic_resnames=None,
    contact_file=None,
):
    """
    Identify receptor residues having hydrophobic/aromatic contacts with one ligand pose.

    Operational definition:
        ligand carbon atoms vs receptor carbon atoms in selected hydrophobic/aromatic residues
        within cutoff Angstrom.

    Returns:
        contact_count, unique_receptor_residues, contact_lines
    """
    hydrophobic_resnames = {str(x).upper() for x in (hydrophobic_resnames or HYDROPHOBIC_RESIDUES)}
    cutoff = float(cutoff)
    cutoff2 = cutoff * cutoff

    contact_lines = []
    residues = set()

    try:
        run(session, "close all")

        rec_result = run(session, f'open "{receptor_file}"')
        lig_result = run(session, f'open "{pose_file}"')

        rec_model = get_first_opened_model(rec_result)
        lig_model = get_first_opened_model(lig_result)
        if rec_model is None or lig_model is None:
            raise RuntimeError("Failed to open receptor or ligand model for hydrophobic-contact analysis.")

        rec_atoms = []
        for a in rec_model.atoms:
            try:
                r = a.residue
                if r is None:
                    continue
                if str(r.name).upper() not in hydrophobic_resnames:
                    continue
                if not is_carbon_atom(a):
                    continue
                rec_atoms.append(a)
            except Exception:
                continue

        lig_atoms = []
        for a in lig_model.atoms:
            try:
                if is_carbon_atom(a):
                    lig_atoms.append(a)
            except Exception:
                continue

        for la in lig_atoms:
            lx, ly, lz = atom_xyz(la)
            for ra in rec_atoms:
                rx, ry, rz = atom_xyz(ra)
                d2 = (lx - rx) ** 2 + (ly - ry) ** 2 + (lz - rz) ** 2
                if d2 <= cutoff2:
                    d = d2 ** 0.5
                    res_label = residue_label_from_atom(ra)
                    residues.add(res_label)
                    contact_lines.append(
                        f"{res_label}\t{ra.name}\t{la.name}\t{d:.3f}"
                    )

        residues_sorted = sorted(residues, key=residue_sort_key)
        contact_lines = sorted(
            contact_lines,
            key=lambda x: (residue_sort_key(x.split("\t")[0]), float(x.split("\t")[-1])),
        )

        if contact_file is not None:
            contact_file = Path(contact_file)
            contact_file.parent.mkdir(parents=True, exist_ok=True)
            header = [
                "Hydrophobic/aromatic contact definition:\n",
                f"Ligand carbon atoms within {cutoff:.2f} Angstrom of receptor carbon atoms in residues: "
                + ", ".join(sorted(hydrophobic_resnames)) + "\n",
                "Receptor_residue\tReceptor_atom\tLigand_atom\tDistance_A\n",
            ]
            if contact_lines:
                contact_file.write_text("".join(header) + "\n".join(contact_lines) + "\n", encoding="utf-8")
            else:
                contact_file.write_text("".join(header) + "No hydrophobic/aromatic contacts found.\n", encoding="utf-8")

        return len(contact_lines), residues_sorted, contact_lines

    finally:
        try:
            run(session, "close all")
        except Exception:
            pass


def energy_sort_key(row):
    return row["energy"] if row["energy"] is not None else 1e9


def format_seconds(sec):
    sec = int(sec)
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m}m {s}s"
    if m:
        return f"{m}m {s}s"
    return f"{s}s"


def main(session):
    settings = effective_settings()
    work_dir = settings["work_dir"]
    receptor_dir = settings["receptor_dir"]
    docking_dir = settings["docking_dir"]
    receptors = settings["receptors"]
    relax = settings["relax"]
    print_each_pose = settings["print_each_pose"]
    keep_details = settings["keep_details"]
    hydrophobic_cutoff = settings["hydrophobic_cutoff"]
    hydrophobic_residues = settings["hydrophobic_residues"]

    if not work_dir.exists():
        log_msg(session, f"[ERROR] WORK_DIR does not exist: {work_dir}")
        return
    if not receptor_dir.exists():
        log_msg(session, f"[ERROR] RECEPTOR_DIR does not exist: {receptor_dir}")
        return
    if not docking_dir.exists():
        log_msg(session, f"[ERROR] DOCKING_DIR does not exist: {docking_dir}")
        return

    output_file = resolve_output_file(settings["output_txt"], docking_dir)

    if CLOSE_ALL_AT_START:
        try:
            run(session, "close all")
        except Exception:
            pass

    if keep_details:
        detail_dir = docking_dir / "chimerax_hbond_details"
        detail_dir.mkdir(parents=True, exist_ok=True)
        temp_context = None
        pose_dir = detail_dir / "split_poses"
        pose_dir.mkdir(parents=True, exist_ok=True)
    else:
        temp_context = tempfile.TemporaryDirectory(prefix="chimerax_vina_hbond_")
        detail_dir = Path(temp_context.name) / "hbond_details"
        detail_dir.mkdir(parents=True, exist_ok=True)
        pose_dir = Path(temp_context.name) / "split_poses"
        pose_dir.mkdir(parents=True, exist_ok=True)

    log_msg(session, "=" * 80)
    log_msg(session, "ChimeraX Vina H-bond + hydrophobic-contact batch analysis started")
    log_msg(session, f"WORK_DIR: {work_dir}")
    log_msg(session, f"RECEPTOR_DIR: {receptor_dir}")
    log_msg(session, f"DOCKING_DIR: {docking_dir}")
    log_msg(session, f"Output TXT: {output_file}")
    log_msg(session, f"Receptors: {', '.join(receptors) if receptors else 'auto-detect'}")
    log_msg(session, f"Relax H-bond criteria: {relax}")
    log_msg(session, f"Hydrophobic contact cutoff: {hydrophobic_cutoff:.2f} Angstrom")
    log_msg(session, f"Hydrophobic/aromatic residues: {', '.join(hydrophobic_residues)}")
    log_msg(session, f"Keep H-bond/contact detail files: {keep_details}")

    jobs = find_jobs(receptor_dir, docking_dir, receptors, pose_dir, session)
    total_pairs = len(jobs)
    total_poses = sum(len(job["poses"]) for job in jobs)

    if total_pairs == 0 or total_poses == 0:
        log_msg(session, "[ERROR] No valid receptor-ligand jobs found. Please check receptor_dir, docking_dir and file names.")
        if temp_context is not None:
            temp_context.cleanup()
        return

    log_msg(session, f"Found receptor-ligand pairs: {total_pairs}")
    log_msg(session, f"Found total poses: {total_poses}")
    log_msg(session, "=" * 80)

    all_rows = []
    selected_rows = []
    raw_hbond_blocks = []
    raw_hydrophobic_blocks = []
    pose_counter = 0
    start_time = time.time()

    for pair_i, job in enumerate(jobs, start=1):
        rec = job["receptor"]
        lig = job["ligand"]
        poses = job["poses"]
        pair_header = f"[PAIR {pair_i}/{total_pairs}] {rec} vs {lig} | poses={len(poses)} | source={job['source_label']}"
        log_msg(session, "-" * 80)
        log_msg(session, pair_header)

        pair_rows = []

        for local_pose_i, pose in enumerate(poses, start=1):
            pose_counter += 1
            percent = 100.0 * pose_counter / total_poses
            elapsed = time.time() - start_time
            avg_sec_per_pose = elapsed / max(pose_counter, 1)
            remain_sec = avg_sec_per_pose * max(total_poses - pose_counter, 0)
            energy = pose["energy"]
            energy_text = "NA" if energy is None else f"{energy:.3f}"

            if print_each_pose:
                log_msg(
                    session,
                    f"[POSE {pose_counter}/{total_poses} | {percent:6.2f}% | elapsed {format_seconds(elapsed)} | ETA {format_seconds(remain_sec)}] "
                    f"pair {pair_i}/{total_pairs}: {rec} vs {lig}, "
                    f"pose {pose['pose_index']} ({local_pose_i}/{len(poses)}), energy={energy_text}",
                    also_status=True,
                )

            hbond_file = detail_dir / f"hbonds__{safe_name(rec)}__{safe_name(lig)}__pose_{pose['pose_index']:02d}.txt"
            hydrophobic_file = detail_dir / f"hydrophobic__{safe_name(rec)}__{safe_name(lig)}__pose_{pose['pose_index']:02d}.txt"

            try:
                hbond_count, residues, data_lines = calculate_one_pose_hbonds(
                    session=session,
                    receptor_file=job["receptor_file"],
                    pose_file=pose["pose_file"],
                    hbond_file=hbond_file,
                    relax=relax,
                )
                hbond_error = ""
            except Exception as e:
                hbond_count = 0
                residues = []
                data_lines = []
                hbond_error = str(e)
                log_msg(session, f"[ERROR] H-bond failed: {rec} vs {lig}, pose {pose['pose_index']}: {e}")
                log_msg(session, traceback.format_exc())

            try:
                hydro_count, hydro_residues, hydro_lines = calculate_one_pose_hydrophobic_contacts(
                    session=session,
                    receptor_file=job["receptor_file"],
                    pose_file=pose["pose_file"],
                    cutoff=hydrophobic_cutoff,
                    hydrophobic_resnames=hydrophobic_residues,
                    contact_file=hydrophobic_file,
                )
                hydro_error = ""
            except Exception as e:
                hydro_count = 0
                hydro_residues = []
                hydro_lines = []
                hydro_error = str(e)
                log_msg(session, f"[ERROR] Hydrophobic contacts failed: {rec} vs {lig}, pose {pose['pose_index']}: {e}")
                log_msg(session, traceback.format_exc())

            residue_text = "; ".join(residues) if residues else "None"
            hydro_residue_text = "; ".join(hydro_residues) if hydro_residues else "None"
            error = "; ".join([x for x in [hbond_error, hydro_error] if x])

            row = {
                "receptor": rec,
                "ligand": lig,
                "pose_index": pose["pose_index"],
                "energy": energy,
                "hbond_count": hbond_count,
                "receptor_residues": residue_text,
                "hydrophobic_contact_count": hydro_count,
                "hydrophobic_residue_count": len(hydro_residues),
                "hydrophobic_residues": hydro_residue_text,
                "hbond_file": str(hbond_file) if keep_details else "temporary",
                "hydrophobic_file": str(hydrophobic_file) if keep_details else "temporary",
                "error": error,
                "source_file": job["source_label"],
            }
            pair_rows.append(row)
            all_rows.append(row)

            if data_lines:
                raw_hbond_blocks.append(
                    f"\n--- {rec} vs {lig} | pose {pose['pose_index']} | energy={energy_text} | hbonds={hbond_count} ---\n"
                    + "\n".join(data_lines)
                    + "\n"
                )

            if hydro_lines:
                raw_hydrophobic_blocks.append(
                    f"\n--- {rec} vs {lig} | pose {pose['pose_index']} | energy={energy_text} | "
                    f"hydrophobic_contacts={hydro_count} | cutoff={hydrophobic_cutoff:.2f} A ---\n"
                    + "Receptor_residue\tReceptor_atom\tLigand_atom\tDistance_A\n"
                    + "\n".join(hydro_lines)
                    + "\n"
                )

            log_msg(
                session,
                f"    -> H-bonds={hbond_count}; receptor residues={residue_text}; "
                f"hydrophobic contacts={hydro_count}; hydrophobic residues={hydro_residue_text}",
                also_status=False,
            )

        with_hbond = [r for r in pair_rows if r["hbond_count"] > 0]
        if with_hbond:
            selected = min(with_hbond, key=energy_sort_key)
            selected["selection_rule"] = "lowest_energy_with_hbond"
        else:
            selected = min(pair_rows, key=energy_sort_key)
            selected["selection_rule"] = "no_hbond_use_lowest_energy"
        selected_rows.append(selected)

        selected_energy_text = "NA" if selected["energy"] is None else f"{selected['energy']:.3f}"
        log_msg(
            session,
            f"[SELECTED] {rec} vs {lig}: pose {selected['pose_index']}, "
            f"energy={selected_energy_text}, H-bonds={selected['hbond_count']}, "
            f"rule={selected['selection_rule']}, residues={selected['receptor_residues']}, "
            f"hydrophobic_contacts={selected['hydrophobic_contact_count']}, "
            f"hydrophobic_residues={selected['hydrophobic_residues']}",
        )

    lines = []
    lines.append("ChimeraX Vina H-bond + hydrophobic-contact batch summary\n")
    lines.append(f"WORK_DIR: {work_dir}\n")
    lines.append(f"RECEPTOR_DIR: {receptor_dir}\n")
    lines.append(f"DOCKING_DIR: {docking_dir}\n")
    lines.append(f"Total receptor-ligand pairs: {total_pairs}\n")
    lines.append(f"Total poses analyzed: {total_poses}\n")
    lines.append(f"Relax H-bond criteria: {relax}\n")
    lines.append(f"Hydrophobic contact cutoff: {hydrophobic_cutoff:.2f} Angstrom\n")
    lines.append("Hydrophobic/aromatic residues: " + ", ".join(hydrophobic_residues) + "\n")
    lines.append("\n")

    lines.append("===== SELECTED RESULT PER RECEPTOR-LIGAND PAIR =====\n")
    lines.append(
        "Receptor\tLigand\tSelected_pose\tEnergy_kcal_mol\tSelection_rule\t"
        "Hbond_count\tReceptor_residues\t"
        "Hydrophobic_contact_count\tHydrophobic_residue_count\tHydrophobic_residues\tSource_file\n"
    )
    for r in selected_rows:
        energy_text = "NA" if r["energy"] is None else f"{r['energy']:.3f}"
        lines.append(
            f"{r['receptor']}\t{r['ligand']}\t{r['pose_index']}\t{energy_text}\t"
            f"{r['selection_rule']}\t{r['hbond_count']}\t{r['receptor_residues']}\t"
            f"{r['hydrophobic_contact_count']}\t{r['hydrophobic_residue_count']}\t"
            f"{r['hydrophobic_residues']}\t{r['source_file']}\n"
        )

    lines.append("\n===== ALL POSE DETAILS =====\n")
    lines.append(
        "Receptor\tLigand\tPose\tEnergy_kcal_mol\t"
        "Hbond_count\tReceptor_residues\t"
        "Hydrophobic_contact_count\tHydrophobic_residue_count\tHydrophobic_residues\t"
        "Source_file\tHbond_detail_file\tHydrophobic_detail_file\tError\n"
    )
    for r in all_rows:
        energy_text = "NA" if r["energy"] is None else f"{r['energy']:.3f}"
        lines.append(
            f"{r['receptor']}\t{r['ligand']}\t{r['pose_index']}\t{energy_text}\t"
            f"{r['hbond_count']}\t{r['receptor_residues']}\t"
            f"{r['hydrophobic_contact_count']}\t{r['hydrophobic_residue_count']}\t"
            f"{r['hydrophobic_residues']}\t{r['source_file']}\t"
            f"{r['hbond_file']}\t{r['hydrophobic_file']}\t{r['error']}\n"
        )

    lines.append("\n===== RAW HBOND LINES PARSED FROM CHIMERAX SAVEFILE =====\n")
    if raw_hbond_blocks:
        lines.extend(raw_hbond_blocks)
    else:
        lines.append("No raw H-bond lines were parsed.\n")

    lines.append("\n===== RAW HYDROPHOBIC/AROMATIC CONTACT LINES CALCULATED FROM COORDINATES =====\n")
    if raw_hydrophobic_blocks:
        lines.extend(raw_hydrophobic_blocks)
    else:
        lines.append("No hydrophobic/aromatic contact lines were calculated.\n")

    output_file.write_text("".join(lines), encoding="utf-8")

    log_msg(session, "=" * 80)
    log_msg(session, "ChimeraX Vina H-bond + hydrophobic-contact batch analysis finished")
    log_msg(session, f"Results saved to: {output_file}")
    log_msg(session, "=" * 80)

    if temp_context is not None:
        temp_context.cleanup()


if "session" in globals():
    main(session)
else:
    raise RuntimeError("This script must be run inside UCSF ChimeraX with the runscript command.")
