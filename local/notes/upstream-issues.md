# Upstream issue candidates (ddalcu/mlx-serve)

Found while building the steering PR. All exist on `main` without our branch.
Nothing here is filed; each is a candidate to decide on.

## 1. A client-supplied absolute path is a file-existence oracle

- **Where:** `src/lora.zig` `validatePath` (image/video/audio `lora_paths`, `lora_path`).
- **What:** any client that can reach a generation endpoint can name an absolute path.
  The error differs for "no such file" vs "exists but not a LoRA", so the client learns
  whether a path exists on the host. Over `--lan-share` (media routes are model-gated,
  so allowed) or with `--api-key`, that client is remote.
- **Note:** the steering PR follows the same rule for `steering.file` (and adds a size
  check), so a fix upstream should cover both.
- **Possible fix:** accept absolute paths only from loopback; remote clients name files
  relative to a registry dir.

## 2. Opening a LoRA path that is a FIFO hangs the connection thread

- **Where:** `src/lora.zig` `validatePath` opens the file before checking its kind.
- **What:** a FIFO path blocks `open` until a writer appears, so the request never
  returns. Needs someone to place a FIFO at a path a request names: low risk.
- **Possible fix:** `statFile` first and refuse anything that is not a regular file
  (the steering loader now does this).

## 3. Flaky unit test: `kv_disk_cache volumeSpace`

- **Where:** `src/kv_disk_cache.zig:6147`, test "volumeSpace: free is what the OS grants,
  never less than statfs' f_bavail".
- **What:** it reads free disk space twice (OS "important usage" API, then statfs) and
  asserts they match. Anything writing to the disk between the two reads changes the
  number, so the test fails at random on a busy machine (seen while a model test was
  writing files). A rerun passes.
- **Possible fix:** compare with a tolerance, or assert only `granted >= statfs free`.

## 4. Repo policy drift

- `CLAUDE.md` is ~136 KB on `main`; its own growth policy says under 100 KB.
- `zig fmt --check` fails on several files on `main` (e.g. `src/lan.zig`).
