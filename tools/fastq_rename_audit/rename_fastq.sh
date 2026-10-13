#!/usr/bin/env bash
# Auditable, reversible FASTQ filename renaming. Requires Bash >= 4 and GNU coreutils.
set -Eeuo pipefail
export LC_ALL=C
umask 077

mode="${1:-}"
run_dir=''
lock_dir=''
lock_owned=0
run_started=0
run_finished=0
undo_started=0
undo_finished=0

timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log_event() {
    local log_file="$1" action="$2" old="$3" new="$4" detail="$5"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(timestamp)" "$action" "$old" "$new" "$detail" >> "$log_file"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    if [[ "$run_started" -eq 1 && "$run_finished" -eq 0 ]]; then
        log_event "$run_dir/events.tsv" 'ERROR' '' '' "$*" || true
    fi
    if [[ "$undo_started" -eq 1 && "$undo_finished" -eq 0 ]]; then
        log_event "$run_dir/undo_events.tsv" 'ERROR' '' '' "$*" || true
    fi
    exit 1
}

cleanup() {
    local exit_code=$?
    if [[ "$run_started" -eq 1 && "$run_finished" -eq 0 && -d "$run_dir" ]]; then
        printf 'INCOMPLETE\n' > "$run_dir/status.txt" || true
    fi
    if [[ "$undo_started" -eq 1 && "$undo_finished" -eq 0 && -d "$run_dir" ]]; then
        printf 'UNDO_INCOMPLETE\n' > "$run_dir/undo_status.txt" || true
    fi
    if [[ "$lock_owned" -eq 1 && -d "$lock_dir" ]]; then
        rm -f -- "$lock_dir/owner.txt" || true
        rmdir -- "$lock_dir" || true
    fi
    return "$exit_code"
}
trap cleanup EXIT
trap 'fail "Interrupted by a signal; inspect audit files before resuming."' HUP INT TERM

usage() {
    cat <<'EOF'
Usage:
  bash rename_fastq.sh check mapping.tsv /path/to/fastq
  bash rename_fastq.sh run   mapping.tsv /path/to/fastq /path/to/audit
  bash rename_fastq.sh undo  /path/to/audit/fastq_rename_RUN_ID

Input mapping.tsv MUST have exactly two tab-separated columns with header:
old_filename<TAB>new_filename

Names must be single filenames, not directories; no destination may already exist.
A run creates an audit bundle (copy it to independently controlled storage).
EOF
}

require_tools() {
    [[ ${BASH_VERSINFO[0]} -ge 4 ]] || fail 'Bash 4 or newer is required.'
    local tool
    for tool in sha256sum stat mv cp date hostname id mkdir rmdir mktemp sed; do
        command -v "$tool" >/dev/null 2>&1 || fail "Missing required tool: $tool"
    done
}

absolute_dir() {
    [[ -d "$1" ]] || fail "Not a directory: $1"
    (cd -- "$1" && pwd -P) || fail "Unable to enter directory: $1"
}

name_is_safe() {
    local name="$1" allowed='^[A-Za-z0-9_.+ -]+$'
    [[ -n "$name" && "$name" != '.' && "$name" != '..' && "$name" != -* \
       && "$name" != [[:space:]]* && "$name" != *[[:space:]] \
       && "$name" =~ $allowed ]]
}

extension_of() {
    case "$1" in
        *.fastq.gz) printf 'fastq.gz' ;;
        *.fq.gz)    printf 'fq.gz' ;;
        *.fastq)    printf 'fastq' ;;
        *.fq)       printf 'fq' ;;
        *)          return 1 ;;
    esac
}

# Detect the most common paired FASTQ naming patterns, without altering them.
mate_of() {
    local name="$1"
    case "$name" in
        *_R1_*) printf '%s' "${name/_R1_/_R2_}" ;;
        *_R2_*) printf '%s' "${name/_R2_/_R1_}" ;;
        *_R1.*) printf '%s' "${name/_R1./_R2.}" ;;
        *_R2.*) printf '%s' "${name/_R2./_R1.}" ;;
        *.R1.*) printf '%s' "${name/.R1./.R2.}" ;;
        *.R2.*) printf '%s' "${name/.R2./.R1.}" ;;
        *)      printf '' ;;
    esac
}

direction_of() {
    case "$1" in
        *_R1_*|*_R1.*|*.R1.*) printf 'R1' ;;
        *_R2_*|*_R2.*|*.R2.*) printf 'R2' ;;
        *)                     printf '' ;;
    esac
}

sha_of() {
    local result
    result=$(sha256sum -- "$1") || fail "Could not calculate SHA256 for $1"
    printf '%s' "${result%% *}"
}

declare -a old_names=() new_names=()
declare -A mapped_to=() used_targets=()

load_and_check_mapping() {
    local map="$1" data_dir="$2" line header old new row=1
    local old_ext new_ext old_mate new_mate old_direction new_direction
    [[ -f "$map" ]] || fail "Mapping file not found: $map"
    [[ -d "$data_dir" ]] || fail "FASTQ directory not found: $data_dir"
    old_names=(); new_names=(); mapped_to=(); used_targets=()
    {
        IFS= read -r header || fail 'The mapping file is empty.'
        header="${header%$'\r'}"
        [[ "$header" == $'old_filename\tnew_filename' ]] || fail 'Expected header: old_filename<TAB>new_filename'
        while IFS= read -r line || [[ -n "$line" ]]; do
            row=$((row + 1))
            line="${line%$'\r'}"
            [[ -z "$line" ]] && continue
            [[ "$line" == *$'\t'* ]] || fail "Line $row is not tab-separated."
            old="${line%%$'\t'*}"
            new="${line#*$'\t'}"
            [[ "$new" != *$'\t'* ]] || fail "Line $row has more than two columns."
            name_is_safe "$old" || fail "Line $row has an invalid source filename: $old"
            name_is_safe "$new" || fail "Line $row has an invalid new filename: $new"
            [[ "$old" != "$new" ]] || fail "Line $row has identical old and new names: $old"
            old_ext=$(extension_of "$old") || fail "Line $row: old name is not a FASTQ filename: $old"
            new_ext=$(extension_of "$new") || fail "Line $row: new name is not a FASTQ filename: $new"
            [[ "$old_ext" == "$new_ext" ]] || fail "Line $row changes the extension/compression suffix."
            [[ -f "$data_dir/$old" && ! -L "$data_dir/$old" ]] || fail "Line $row: source missing, not regular, or a symlink: $old"
            [[ ! -e "$data_dir/$new" && ! -L "$data_dir/$new" ]] || fail "Line $row: destination already exists: $new"
            [[ ! -v 'mapped_to[$old]' ]] || fail "Line $row: source listed more than once: $old"
            [[ ! -v 'used_targets[$new]' ]] || fail "Line $row: destination repeated: $new"
            mapped_to["$old"]="$new"
            used_targets["$new"]="$old"
            old_names+=("$old")
            new_names+=("$new")
        done
    } < "$map"
    (( ${#old_names[@]} > 0 )) || fail 'There are no rename rows.'
    local index
    for index in "${!old_names[@]}"; do
        old="${old_names[$index]}"; new="${new_names[$index]}"
        old_direction=$(direction_of "$old")
        new_direction=$(direction_of "$new")
        [[ "$old_direction" == "$new_direction" ]] || fail "Read orientation (R1/R2) changed: $old -> $new"
        old_mate=$(mate_of "$old")
        if [[ -n "$old_mate" ]]; then
            new_mate=$(mate_of "$new")
            if [[ -f "$data_dir/$old_mate" && ! -v 'mapped_to[$old_mate]' ]]; then
                fail "Paired mate exists but is not in mapping: $old_mate"
            fi
            if [[ -v 'mapped_to[$old_mate]' && "$new_mate" != "${mapped_to[$old_mate]}" ]]; then
                fail "R1/R2 files mapped to different sample labels: $old and $old_mate"
            fi
        fi
    done
    printf 'VALIDATED: %d requested filename changes. No files modified.\n' "${#old_names[@]}"
    printf 'Mapping SHA256: %s\n' "$(sha_of "$map")"
    printf 'Validation includes file existence, unique names, absent targets, extensions, and common R1/R2 patterns.\n'
}

lock_dataset() {
    local data_dir="$1" owner="$2"
    lock_dir="$data_dir/.fastq_rename.lock"
    mkdir -- "$lock_dir" 2>/dev/null || fail "Dataset is locked: $lock_dir (inspect before removing a stale lock)."
    lock_owned=1
    printf 'user=%s\nhost=%s\ntime_utc=%s\noperation=%s\n' "$(id -un)" "$(hostname)" "$(timestamp)" "$owner" > "$lock_dir/owner.txt"
}

perform_run() {
    local input_map="$1" data_dir="$2" audit_parent="$3"
    local map index old new before_bytes before_sha after_bytes after_sha
    data_dir=$(absolute_dir "$data_dir")
    [[ "$data_dir" != *$'\t'* && "$data_dir" != *$'\n'* ]] || fail 'Dataset path cannot contain tabs/newlines.'
    mkdir -p -- "$audit_parent" || fail "Cannot create audit folder: $audit_parent"
    audit_parent=$(absolute_dir "$audit_parent")
    [[ "$audit_parent" != "$data_dir" && "$audit_parent" != "$data_dir"/* ]] || fail 'Audit folder must be outside the FASTQ folder.'
    run_dir=$(mktemp -d -- "$audit_parent/fastq_rename_$(date -u '+%Y%m%dT%H%M%SZ')_XXXXXX") || fail 'Cannot create audit run folder.'
    printf 'STARTED\n' > "$run_dir/status.txt"
    printf 'time_utc\taction\told_filename\tnew_filename\tdetail\n' > "$run_dir/events.tsv"
    run_started=1
    cp -- "$input_map" "$run_dir/approved_mapping.tsv" || fail 'Could not copy input mapping.'
    cp -- "$0" "$run_dir/rename_fastq.sh" || fail 'Could not snapshot the script.'
    printf '%s\n' "$data_dir" > "$run_dir/data_dir.txt"
    {
        printf 'started_utc=%s\n' "$(timestamp)"
        printf 'user=%s\n' "$(id -un)"
        printf 'host=%s\n' "$(hostname)"
        printf 'bash=%s\n' "$BASH_VERSION"
        printf 'source_mapping=%s\n' "$input_map"
        printf 'fastq_directory=%s\n' "$data_dir"
    } > "$run_dir/context.txt"
    load_and_check_mapping "$run_dir/approved_mapping.tsv" "$data_dir"
    lock_dataset "$data_dir" "RUN $run_dir"
    log_event "$run_dir/events.tsv" 'PREFLIGHT_OK' '' '' "${#old_names[@]} filenames"

    # Complete baseline manifest and its digest BEFORE any rename.
    printf 'old_filename\tnew_filename\tbytes\tsha256_before\n' > "$run_dir/manifest.tmp"
    for index in "${!old_names[@]}"; do
        old="${old_names[$index]}"; new="${new_names[$index]}"
        before_bytes=$(stat -c '%s' -- "$data_dir/$old") || fail "Could not stat: $old"
        before_sha=$(sha_of "$data_dir/$old")
        printf '%s\t%s\t%s\t%s\n' "$old" "$new" "$before_bytes" "$before_sha" >> "$run_dir/manifest.tmp"
    done
    mv -- "$run_dir/manifest.tmp" "$run_dir/manifest.tsv"
    (cd -- "$run_dir" && sha256sum -- approved_mapping.tsv rename_fastq.sh data_dir.txt context.txt manifest.tsv > provenance.sha256) || fail 'Could not hash audit inputs.'
    log_event "$run_dir/events.tsv" 'BASELINE_COMPLETE' '' '' "${#old_names[@]} SHA256 checksums"

    # A no-overwrite mv and explicit before/after events for each filename.
    for index in "${!old_names[@]}"; do
        old="${old_names[$index]}"; new="${new_names[$index]}"
        [[ -f "$data_dir/$old" && ! -L "$data_dir/$old" ]] || fail "Original disappeared during run: $old"
        [[ ! -e "$data_dir/$new" && ! -L "$data_dir/$new" ]] || fail "Destination appeared during run: $new"
        log_event "$run_dir/events.tsv" 'MOVE_BEGIN' "$old" "$new" ''
        mv -n -- "$data_dir/$old" "$data_dir/$new" || fail "mv failed: $old -> $new"
        [[ ! -e "$data_dir/$old" && -f "$data_dir/$new" ]] || fail "mv did not finish cleanly: $old -> $new"
        log_event "$run_dir/events.tsv" 'MOVE_DONE' "$old" "$new" ''
    done

    # Verify sizes AND contents after EVERY rename.
    printf 'old_filename\tnew_filename\tbytes_after\tsha256_after\tverified_utc\n' > "$run_dir/verification.tmp"
    for index in "${!old_names[@]}"; do
        old="${old_names[$index]}"; new="${new_names[$index]}"
        before_bytes=$(stat -c '%s' -- "$data_dir/$new") || fail "Cannot stat renamed file: $new"
        before_sha=$(sha_of "$data_dir/$new")
        # Baseline row order is identical to mapping order.
        expected_line=$(sed -n "$((index+2))p" "$run_dir/manifest.tsv")
        expected_size="${expected_line#*$'\t'}"; expected_size="${expected_size#*$'\t'}"; expected_size="${expected_size%%$'\t'*}"
        expected_sha="${expected_line##*$'\t'}"
        [[ "$before_bytes" == "$expected_size" && "$before_sha" == "$expected_sha" ]] || fail "Size/SHA256 differs after rename: $new"
        printf '%s\t%s\t%s\t%s\t%s\n' "$old" "$new" "$before_bytes" "$before_sha" "$(timestamp)" >> "$run_dir/verification.tmp"
        log_event "$run_dir/events.tsv" 'VERIFY_OK' "$old" "$new" "$before_sha"
    done
    mv -- "$run_dir/verification.tmp" "$run_dir/verification.tsv"
    log_event "$run_dir/events.tsv" 'RUN_COMPLETE' '' '' "${#old_names[@]} files renamed and hash-verified"
    printf 'COMPLETE\n' > "$run_dir/status.txt"
    (cd -- "$run_dir" && sha256sum -- events.tsv verification.tsv status.txt > run_finished.sha256) || fail 'Could not hash final audit records.'
    run_finished=1
    printf '\nSUCCESS: %d FASTQ files renamed and SHA256 verified.\n' "${#old_names[@]}"
    printf 'Audit folder: %s\n' "$run_dir"
    printf 'Keep this folder as the permanent old-name/new-name cross-reference.\n'
}

load_manifest_for_undo() {
    local file="$1" line header old new bytes digest row=1 extra
    declare -g -a undo_old=() undo_new=() undo_bytes=() undo_sha=()
    declare -A old_seen=() new_seen=()
    {
        IFS= read -r header || fail 'Manifest is empty.'
        [[ "$header" == $'old_filename\tnew_filename\tbytes\tsha256_before' ]] || fail 'Unexpected manifest header.'
        while IFS= read -r line || [[ -n "$line" ]]; do
            row=$((row+1))
            IFS=$'\t' read -r old new bytes digest extra <<< "$line"
            [[ -z "${extra:-}" && -n "$old" && -n "$new" && -n "$bytes" && -n "$digest" ]] || fail "Bad manifest row: $row"
            name_is_safe "$old" && name_is_safe "$new" || fail "Unsafe filename in manifest row $row"
            [[ "$bytes" =~ ^[0-9]+$ && "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "Bad size/checksum in manifest row $row"
            [[ ! -v 'old_seen[$old]' && ! -v 'new_seen[$new]' ]] || fail "Duplicate filename in manifest row $row"
            old_seen["$old"]=1; new_seen["$new"]=1
            undo_old+=("$old"); undo_new+=("$new"); undo_bytes+=("$bytes"); undo_sha+=("$digest")
        done
    } < "$file"
    (( ${#undo_old[@]} > 0 )) || fail 'Manifest has no rename rows.'
}

perform_undo() {
    run_dir=$(absolute_dir "$1")
    [[ -f "$run_dir/manifest.tsv" && -f "$run_dir/data_dir.txt" && -f "$run_dir/provenance.sha256" ]] || fail 'Audit folder is missing the manifest or provenance files.'
    if [[ -f "$run_dir/undo_status.txt" && "$(cat -- "$run_dir/undo_status.txt")" == 'UNDONE' ]]; then
        printf 'Already undone: %s\n' "$run_dir"
        return 0
    fi
    # Reject modified audit inputs or completed-run records.
    (cd -- "$run_dir" && sha256sum -c -- provenance.sha256 >/dev/null) || fail 'Audit input checksums do not verify.'
    if [[ -f "$run_dir/run_finished.sha256" ]]; then
        (cd -- "$run_dir" && sha256sum -c -- run_finished.sha256 >/dev/null) || fail 'Completed-run audit checksums do not verify.'
    fi
    local data_dir index old new expected_size actual_size actual_sha state
    data_dir=$(cat -- "$run_dir/data_dir.txt")
    data_dir=$(absolute_dir "$data_dir")
    load_manifest_for_undo "$run_dir/manifest.tsv"
    lock_dataset "$data_dir" "UNDO $run_dir"
    # Verify every existing original/new file BEFORE starting any reversal.
    for index in "${!undo_old[@]}"; do
        old="${undo_old[$index]}"; new="${undo_new[$index]}"
        if [[ -f "$data_dir/$new" && ! -L "$data_dir/$new" && ! -e "$data_dir/$old" ]]; then
            state='RENAMED'; actual_path="$data_dir/$new"
        elif [[ -f "$data_dir/$old" && ! -L "$data_dir/$old" && ! -e "$data_dir/$new" ]]; then
            state='ORIGINAL'; actual_path="$data_dir/$old"
        else
            fail "Cannot undo safely; unexpected file state: $old / $new"
        fi
        actual_size=$(stat -c '%s' -- "$actual_path") || fail "Cannot read file size: $actual_path"
        actual_sha=$(sha_of "$actual_path")
        [[ "$actual_size" == "${undo_bytes[$index]}" && "$actual_sha" == "${undo_sha[$index]}" ]] || fail "Refusing to undo a modified file: $actual_path"
    done
    if [[ ! -f "$run_dir/undo_events.tsv" ]]; then
        printf 'time_utc\taction\told_filename\tnew_filename\tdetail\n' > "$run_dir/undo_events.tsv"
    fi
    undo_started=1
    log_event "$run_dir/undo_events.tsv" 'UNDO_BEGIN' '' '' "${#undo_old[@]} manifest rows verified"
    local count=0
    for index in "${!undo_old[@]}"; do
        old="${undo_old[$index]}"; new="${undo_new[$index]}"
        if [[ -f "$data_dir/$new" && ! -e "$data_dir/$old" ]]; then
            log_event "$run_dir/undo_events.tsv" 'RESTORE_BEGIN' "$new" "$old" ''
            mv -n -- "$data_dir/$new" "$data_dir/$old" || fail "Undo mv failed: $new -> $old"
            [[ -f "$data_dir/$old" && ! -e "$data_dir/$new" ]] || fail "Undo mv did not finish cleanly: $new -> $old"
            log_event "$run_dir/undo_events.tsv" 'RESTORE_DONE' "$new" "$old" "${undo_sha[$index]}"
            count=$((count+1))
        fi
    done
    log_event "$run_dir/undo_events.tsv" 'UNDO_COMPLETE' '' '' "$count files restored; others already original"
    printf 'UNDONE\n' > "$run_dir/undo_status.txt"
    (cd -- "$run_dir" && sha256sum -- undo_events.tsv undo_status.txt > undo_finished.sha256) || fail 'Could not hash undo audit.'
    undo_finished=1
    printf 'UNDO COMPLETE: %d original filenames restored. Original audit retained.\n' "$count"
    printf 'Audit folder: %s\n' "$run_dir"
}

require_tools
case "$mode" in
    check)
        [[ $# -eq 3 ]] || { usage; exit 2; }
        data_dir=$(absolute_dir "$3")
        load_and_check_mapping "$2" "$data_dir"
        ;;
    run)
        [[ $# -eq 4 ]] || { usage; exit 2; }
        perform_run "$2" "$3" "$4"
        ;;
    undo)
        [[ $# -eq 2 ]] || { usage; exit 2; }
        perform_undo "$2"
        ;;
    *) usage; exit 2 ;;
esac
