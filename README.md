# axelera-metis-setup

One-command bring-up of an **Axelera Metis PCIe card** with the **Voyager SDK v1.6.1**.
It covers hardware detection, the driver, SDK dependencies, and a full verification with an inference test.
Each stage shows progress bars, logs everything, and the run can be resumed.

## Workflow

1. **Install the card.** Power off, seat the Metis PCIe card, and connect power.
2. **BIOS settings.**
   - Set **Secure Boot** to **Disabled**. The `metis` DKMS module is unsigned.
   - Set **Above 4G Decoding** to **Enabled**. This is needed for multi-chip BAR space.
3. **Boot Ubuntu 22.04 or 24.04, clone this repo and run:**

   ```bash
   git clone <this-repo-url> axelera-metis-setup
   cd axelera-metis-setup
   ./setup.sh
   ```

4. **Log out and back in** (or reconnect SSH) when the script asks. This activates the `axelera`/`render` groups.
5. **Confirm everything:**

   ```bash
   ./verify.sh --per-device
   ```

## What `setup.sh` does

| # | Stage | Details |
|---|-------|---------|
| 1 | Preflight | Checks Ubuntu version, non-root user, sudo (kept alive for the run), disk, RAM and network |
| 2 | PCIe detection | Counts `1f9d` devices (expects 4) and reports BAR-assignment errors |
| 3 | Secure Boot | Stops with instructions if it is enabled |
| 4 | Base packages | Installs git, dkms, build-essential, `linux-headers-$(uname -r)` and mokutil, with a per-package progress bar |
| 5 | SDK checkout | Resolves `v1.6.1` (tag) and clones or updates `~/voyager-sdk`; refuses to touch local changes unless `--stash` is given |
| 6 | multi-device (pre) | Stops `axelera-multi-device.service` if it is already present |
| 7 | install.sh | Runs `./install.sh --all --media --YES`, with a live `[N/206]` progress bar parsed from its output |
| 8 | Repair | Reinstalls every package that `install.sh` reported as failed (e.g. `onnxoptimizer`, `typing-inspection`), with reduced build parallelism (4 → 2 → 1 jobs) |
| 9 | multi-device (post) | Disables **and masks** `axelera-multi-device.service`, because it drops the PCIe links on this board |
| 10 | Driver | Runs `modprobe metis`, waits for 4 `/dev/metis-*` nodes, sets the module to load at boot, and reports the dkms status |
| 11 | Groups | Adds the user to `axelera`/`render`/`video` and detects whether a re-login is needed |
| 12 | Verify | Runs `verify.sh` (below) |

If a stage fails, fix the cause and run `./setup.sh --resume`. Completed heavy stages are skipped.
For example, disable Secure Boot, reboot, and then resume.

## What `verify.sh` checks

It checks PCIe count and link speed/width, Secure Boot, driver loaded, DKMS built for the running kernel, and device nodes and permissions.
It checks group membership (both the group database and the current session) and that `axelera-multi-device` is masked.
It checks that the `axelera-runtime-1.6.1` and `metis-dkms` packages are installed and that the git checkout is 1.6.1.
In the venv it checks activation, runs `pip check`, and imports the key modules (onnxoptimizer, torch, cv2, gi, …) plus the Axelera Python packages.
It runs `axdevice` (device count, firmware and clock) and checks OpenCL and the GStreamer Axelera elements.
It looks for hardware stability problems (MCE, invalid opcode, segfaults, compiler crashes).
It runs the **inference smoke test** (`yolov8s-coco-onnx` on `traffic1_1080p.mp4`) and, with `--per-device`, a short run on each chip.

The result is a coloured PASS/WARN/FAIL table in the terminal and a text report in `reports/report-<timestamp>.txt`.
The exit code is `0` if everything passed, `2` if there were warnings, and `1` if anything failed.

## Options

```bash
./setup.sh --help
./setup.sh --resume              # continue after fixing something / after reboot
./setup.sh --reset               # forget progress, start over
./setup.sh --stash               # git-stash local changes in ~/voyager-sdk before checkout
./setup.sh --devices 1           # single-chip card
./setup.sh --no-inference        # skip the (slow on first run) inference test
./verify.sh --no-inference       # quick health check, ~30 s
./verify.sh --per-device         # also test each Metis chip individually
```

All defaults are in `config.env`, including version, SDK path, expected devices, test model and timeouts.
You can also override them per run, e.g. `SDK_VERSION=1.6.1 SDK_DIR=/opt/voyager-sdk ./setup.sh`.

## Files

```
setup.sh        end-to-end installer (12 stages)
verify.sh       health check + tests + report
config.env      defaults
lib/ui.sh       progress bars, spinners, logging
lib/system.sh   hardware / service / venv helpers
logs/           setup, install.sh, verify and inference logs (git-ignored)
reports/        verification reports (git-ignored)
```

## Notes

- The first inference run compiles or downloads the model, which can take 10–30 minutes. Later runs are fast.
- Compiler crashes or `Illegal instruction` during the install usually point to RAM/CPU instability, e.g. XMP/EXPO memory profiles. `verify.sh` flags these as warnings.
- To keep `axelera-multi-device` enabled on other boards, use `--keep-multi-device` or set `DISABLE_MULTI_DEVICE=0`.
