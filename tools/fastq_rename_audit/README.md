# Auditable FASTQ renaming for DARWIN

A simple Bash workflow for renaming existing FASTQ files to approved specimen or DNA identifiers while preserving a detailed, reversible audit trail. Prepared for the RMCA molecular laboratory; improvements and review are welcome.

**The script does not infer sample identities.** It applies only the supplied mapping. A curator must check the proposed mapping against the original sequencing provider sample sheet and the DARWIN records. A successful checksum check proves sequence bytes were preserved, not that the biological identity was assigned correctly.

## Repository files

* [rename_fastq.sh](rename_fastq.sh): Bash implementation, with preflight validation, checksums, event logging and undo.
* [mapping_EXAMPLE.tsv](mapping_EXAMPLE.tsv): synthetic two column input table. No actual specimen identifiers.
* [OPERATING_PROCEDURE.txt](OPERATING_PROCEDURE.txt): complete operating instructions, audit files, recovery and verification procedures.

## Requirements

Linux or Windows Subsystem for Linux (WSL), Bash 4 or newer, and GNU coreutils including `sha256sum`, `stat`, `mv`, `cp` and `sed`.

Create a **tab separated** `mapping.tsv` containing exactly these two columns:

```tsv
old_filename	new_filename
OriginalSampleA_L001_R1_001.fastq.gz	NewSample001_L001_R1_001.fastq.gz
OriginalSampleA_L001_R2_001.fastq.gz	NewSample001_L001_R2_001.fastq.gz
```

The example identifiers above are fictitious. Both columns must contain full file names without directory paths.

## Workflow

1. Independently review and approve the mapping. Save the approval and its mapping SHA256 in the institutional record.
2. Make a normal backup of the FASTQ data and ensure no other process is changing the files.
3. Run the validation command, which does not modify any data.
4. Run the rename command on the approved mapping.
5. Copy the resulting audit directory and signed mapping approval to controlled institutional storage.

```bash
# Validate without modifying FASTQ files
bash rename_fastq.sh check /path/to/mapping.tsv /path/to/fastq

# Rename and save a complete audit trail
bash rename_fastq.sh run /path/to/mapping.tsv /path/to/fastq /path/to/audit

# Verify the audit records
cd /path/to/audit/fastq_rename_RUN_ID
sha256sum -c provenance.sha256 run_finished.sha256

# Restore original filenames when necessary
bash /path/to/rename_fastq.sh undo /path/to/audit/fastq_rename_RUN_ID
```

The audit directory **must be outside the FASTQ directory**. Each run creates a unique folder containing the approved mapping, original and new filenames, file sizes, SHA256 hashes before and after renaming, timestamped operation log, script snapshot, execution context and completion status. Undo adds its own audit log without erasing the original history. See the complete operating procedure for handling incomplete runs.

## Improving this tool

Marzie and other laboratory contributors can update the Bash script and documentation in GitHub, subject to their repository permissions. For changes to safety checks or the audit schema, use a branch and pull request so changes can be reviewed. Before approving a code change, test at least one synthetic R1/R2 pair through `check`, `run`, audit verification and `undo`. Preserve backward compatibility with audit bundles created by earlier versions wherever possible.

The repository is **public**. Only synthetic mapping examples and source code belong here. Keep real FASTQ files, actual sample identity mappings, sequencing sheets, audit records and any restricted DARWIN metadata in approved institutional storage.

This utility preserves naming provenance for DARWIN imports. The original sequencing provider filenames, DARWIN specimen or DNA identifiers, and curator approved cross reference should remain separately traceable.
