# Upstream issue drafts (for review, not submitted)

Format: the repo's bug form (`.github/ISSUE_TEMPLATE/1-bug.yml`). The body below is what the
form renders: one `### <label>` heading per field, in form order, with dropdown values copied
exactly from the form options. Blank issues are disabled, so submit with the form, or with
`gh issue create --repo ddalcu/mlx-serve --title "..." --body-file <file>` using the body
as written. The form adds the `bug` label; `gh` cannot add it for a non-collaborator.

Required fields: Before opening, Priority, Area, mlx-serve version, Hardware + macOS,
What happened vs what you expected, Reproduction steps. Optional: Model, Server log tail.

---

## Issue 1

**Title:** A lora_paths request can find out if a file exists on the host

### Before opening

- [x] I searched open and closed issues, open PRs and recent commits for this, and it is not already reported or fixed

### Priority

low (minor annoyance)

### Area

Media generation (image / video / audio / 3D / TTS)

### mlx-serve version

26.9.5-dev (main at 3a9181f)

### Hardware + macOS

M5 Max 128 GB, macOS 27.0

### Model

Any media model that accepts `lora_paths` / `lora_path`

### What happened vs what you expected

A client can send an absolute path in `lora_path` or `lora_paths`. The server gives two different results:

- If the file does not exist, `lora.validatePath` fails. The server sends a 400: "must be absolute path(s) to .safetensors file(s)".
- If the file exists but is not a LoRA, the check passes. `mlx_load_safetensors` then fails with a different error.

Thus a client can find out if any path exists on the host. A loopback client is the owner. But with `--lan-share` (media routes are model-gated, so LAN peers can use them) or with `--api-key`, the client can be on a different machine.

I expected a remote client to get the same answer for "no file" and "not a LoRA", or to be unable to name host paths.

Possible fix: accept absolute paths only from loopback clients. Remote clients name an adapter relative to a fixed directory. PR #538 uses the same path rule for `steering.file`, so one fix can cover both.

### Reproduction steps

I found this in the code: `src/lora.zig` (`validatePath`, `loadFile`) and the LoRA error mapping in `src/gen.zig`. I did not send the requests. The steps to show it:

1. Launch with `--lan-share` and a media model that takes LoRAs.
2. From another machine, send an image request with `"lora_paths": ["/etc/does-not-exist"]`. Result: the 400 above.
3. Send it again with `"lora_paths": ["/etc/hosts"]`. Result: a different error.

---

## Issue 2

**Title:** A lora_paths entry that is a FIFO stops the request

### Before opening

- [x] I searched open and closed issues, open PRs and recent commits for this, and it is not already reported or fixed

### Priority

low (minor annoyance)

### Area

Media generation (image / video / audio / 3D / TTS)

### mlx-serve version

26.9.5-dev (main at 3a9181f)

### Hardware + macOS

M5 Max 128 GB, macOS 27.0

### Model

Any media model that accepts `lora_paths` / `lora_path`

### What happened vs what you expected

`lora.validatePath` opens the file before it checks the file kind. If the path is a FIFO (named pipe), `open` waits for a writer. The connection thread stops at that point, and the request does not get a response.

I expected the server to refuse any path that is not a regular file, with a 400, before it opens the path.

Possible fix: use `statFile` first and refuse anything that is not a regular file. Then open the file. PR #538 does this for steering bank files.

### Reproduction steps

I found this in the code (`src/lora.zig` `validatePath`). I did not run it. The steps to show it:

1. `mkfifo /tmp/lora.safetensors`
2. Launch with a media model that takes LoRAs.
3. Send an image request with `"lora_paths": ["/tmp/lora.safetensors"]`. Result: no response.

The risk is low: a person must put a FIFO at a path that a request names.

---

## Issue 3

**Title:** Flaky unit test: kv_disk_cache volumeSpace fails when the disk is busy

### Before opening

- [x] I searched open and closed issues, open PRs and recent commits for this, and it is not already reported or fixed

### Priority

low (minor annoyance)

### Area

Other

### mlx-serve version

26.9.5-dev (main at 3a9181f)

### Hardware + macOS

M5 Max 128 GB, macOS 27.0

### What happened vs what you expected

`zig build test` failed one time in `kv_disk_cache.test.volumeSpace: free is what the OS grants, never less than statfs' f_bavail`. The test reads the free disk space two times, with two different calls. It then expects the two values to be equal. If another process writes to the disk between the two reads, the values are different and the test fails. At that time, a separate model test wrote dump files to the same disk. The next run passed.

I expected the test to pass when other processes use the disk.

Possible fix: compare the two values with a tolerance, or check only that the granted value is not less than the statfs value.

### Reproduction steps

1. Start a process that writes large files to the same volume.
2. Run `zig build test`.
3. The test fails on some runs.

### Server log tail

```text
error: 'kv_disk_cache.test.volumeSpace: free is what the OS grants, never less than statfs' f_bavail' failed:
src/kv_disk_cache.zig:6147:30: in test.volumeSpace: free is what the OS grants, never less than statfs' f_bavail
    if (granted <= vs.total) try testing.expectEqual(granted, vs.free);
```

---

## Dropped

- **CLAUDE.md size**: upstream main is now 86 KB, under the 100 KB rule. Fixed.
- **`zig fmt --check` fails on many files**: CI does not check formatting, so this is a project choice, not a bug.
