# gnina_local

Local setup for [gnina](https://github.com/gnina/gnina) — molecular docking with
CNN scoring — on a machine with **no NVIDIA GPU, no CUDA toolkit, and no sudo**.

gnina's CNN scoring still works in this configuration. It runs on the CPU, and
for the default `rescore` mode it is fast enough to be practical (~40 s per
ligand, or ~11 s with `--cnn fast`; see [CPU performance](#cpu-performance)).

## Quick start

```bash
./setup.sh          # ~6GB download, idempotent, no sudo required
./bin/gnina --help
```

Then dock as usual, via the `bin/gnina` wrapper rather than the raw binary:

```bash
./bin/gnina -r rec.pdb -l lig.sdf --autobox_ligand ref.sdf -o docked.sdf.gz
```

## Why not just build from source?

Upstream's README documents a source build, which hard-requires the CUDA
toolkit — `CMakeLists.txt` declares CUDA as a project language
(`project(gnina C CXX CUDA)`) and calls `find_package(CUDA 12.0 REQUIRED)`. On a
machine with no NVIDIA GPU that build buys nothing: there is no device to run
CNN scoring on either way, and it costs a ~4GB toolkit install (needing sudo),
an OpenBabel source build, and a multi-hour compile.

The prebuilt release binary already contains the compiled CUDA code. It only
needs the CUDA **runtime** shared libraries present at load time, and those are
available as pip wheels. Hence this repo.

## What setup.sh does

1. Creates `.venv` and installs the six CUDA runtime wheels that satisfy the
   seven libraries `ldd` reports missing (`libcudnn`, `libcudart`, `libcublas`,
   `libcublasLt`, `libcusparse`, `libcufft`, `libcusolver`), plus
   `openbabel-wheel`/`numpy`/`pytest` for the test suite.
2. Downloads the `gnina.cuda12.8.static` release asset to `bin/gnina.bin` and
   verifies its SHA256 against the published digest.
3. Sparse-clones **only** `test/` and `scripts/` from upstream at the pinned tag
   into `upstream/` — about 9MB, versus ~400MB for a full clone.
4. Runs a smoke test using the same thresholds as upstream's own
   `test_gnina.py`.

`libcuda.so.1` — the actual driver library — is *not* required. The binary
dlopens it lazily, which is exactly why it runs CPU-only with no GPU present.

## The two gotchas

**CUDA runtime libs.** The release asset is named `.static` but still
dynamically links seven CUDA libraries. Without them it fails at load with
`error while loading shared libraries: libcudnn.so.9`. The pip wheels supply
them without touching the system.

**`LD_LIBRARY_PATH` must not be inherited.** gnina dynamically links
`libstdc++.so.6`. If your shell puts a bundled toolchain ahead of the system one
— ORCA does this — gnina resolves the wrong, older `libstdc++` and dies with
`version 'CXXABI_1.3.15' not found`. The same breakage hits `obabel` and even
`apt`. `bin/gnina` is a wrapper that sets a clean `LD_LIBRARY_PATH` containing
only the CUDA wheel paths, so **always invoke `bin/gnina`, not `bin/gnina.bin`.**

## CPU performance

Measured on 8 CPU cores, docking a 21-atom ligand into a pocket-sized autobox
(SULT1A3 / PDB 2A3R). Reproduce with `./bench.sh`.

| Mode | Time |
| --- | --- |
| `--score_only`, `--cnn_scoring=none` | 1.3 s |
| `--score_only`, `--cnn fast` | 1.6 s |
| `--score_only`, CNN ensemble (default) | 2.8 s |
| `--minimize`, `--cnn_scoring=none` | 1.4 s |
| `--minimize`, CNN ensemble | 3.2 s |
| dock `--exhaustiveness 8`, `--cnn_scoring=none` | 5.3 s |
| dock `--exhaustiveness 8`, `--cnn fast` | 11.2 s |
| dock `--exhaustiveness 8`, CNN ensemble (default) | 39.6 s |

### Choosing settings on CPU

`--cnn_scoring=rescore` is the default and the only mode worth using here. The
Vina search stays on the CPU where it is cheap (5.3 s above); CNN then rescores
just the final `--num_modes` poses (default 9). **Cost scales with
`--num_modes`, not `--exhaustiveness`** — more exhaustiveness buys more search
almost for free.

- `--cnn fast` uses one model instead of the default ensemble, cutting rescoring
  from ~34 s to ~6 s. It reports no `CNNvariance` because there is no ensemble to
  vary, and its absolute scores differ (on one complex, `CNNaffinity` 4.82 vs
  5.62), so don't mix the two within a campaign.
- **Avoid `refinement`, `metrorescore` and `metrorefine` without a GPU.** These
  put CNN inside the Monte Carlo loop. A single `metrorescore` run with an
  ensemble and `--num_mc_steps 1000` took **over 16 minutes**, versus 40 s for
  the same complex in `rescore`.
- To rescore poses from an existing Vina/smina run, skip docking entirely and
  use `--score_only` on the multi-model SDF — a couple of seconds per pose.

Rough throughput at defaults: ~90 ligands/hour, or ~320/hour with `--cnn fast`.
Larger or more flexible ligands and bigger boxes cost more.

## Tests

```bash
cd upstream/test/gnina
../../../.venv/bin/python ./test_gnina.py ../../../bin/gnina
```

| Suite | Result |
| --- | --- |
| `test_gnina.py` | passes (12 assertions, ~12 s) |
| `test_min.py` | passes |
| `test_flex.py` | **fails — expected, see below** |
| `test_cnn.py` | very slow on CPU; dominated by `metrorescore`/`metrorefine`/`refinement` |

`test_flex.py` fails at `assert content.count("WARNING") == 0`. This is an
artifact of having no GPU, not a defect: gnina unconditionally prints
`WARNING: No GPU detected. CNN scoring will be slow.` — even with
`--cnn_scoring=none` — and that trips an assertion meant to catch a *duplicate
residue* warning. The warning it actually tests for is correctly absent.

`gninacheck`, the compiled C++/CUDA unit test, is unavailable without a source
build.

## Credits

gnina is by the [Koes lab](https://github.com/gnina/gnina) and is licensed
Apache-2.0 / GPL — see `upstream/LICENSE.APACHE` and `upstream/LICENSE.GNU`
after running `setup.sh`. If you use it, cite their papers as listed in the
[upstream README](https://github.com/gnina/gnina#citation).

The MIT license here covers only the setup scripts in this repository.
