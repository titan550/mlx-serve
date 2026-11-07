# Title

feat: directional steering for Qwen3.8 Flash Next (qwen4_exp)

# Body

**What changed / why**

This PR adds directional steering to the native `qwen4_exp` forward. The method and the bank format are the same as the [ds4 `dir-steering` tool](https://github.com/antirez/ds4/blob/main/dir-steering/README.md). Each trunk layer has one direction `d`. The server applies `y -= scale * d * dot(d, y)` to the attention output (attn arm) and to the residual after the MLP (ffn arm). The MTP head is not steered.

You can set steering in four ways: the launch flags `--dir-steering-file/-ffn/-attn`, the `steering` key in `model-settings.json`, `POST /v1/steering` (or `mlx-serve steer`), or a `steering` object in a request. A bank is a raw f32 file in `~/.mlx-serve/steering/`. `tests/build_steering_bank.py` makes a bank from two prompt sets. The example sets in `tests/fixtures/steering/` make a verbosity bank. At decode, the edit runs in the hyper-connection read kernel that already runs. It adds no dispatch. The app shows steering in Model Settings and in the menu bar. This is not the chat "steering note" of #497.

Note: this PR adds `steering_flags` to the existing cold-load source-scan test. The CLAUDE.md rule for cold-load flags names that test as the guard.

**How I verified it**

Apple M5 Max, 128 GB, macOS 27.0. `zig build test`: 2697 passed, 0 failed. `swift test` (steering and model-settings tests): 31 passed, 0 failed. `tests/test_qwen4_steering.sh` on the mixed-4-8bit pack: 54 passed, 0 failed.

- [x] Searched open and closed issues, open PRs and recent commits; linked the existing thread if there is one
- [x] Built and ran this tree on a real Apple Silicon Mac in this session
- [x] No comments that restate code, carry history, or cite audit/review items
- [ ] No source-scan tests; every test checks behaviour
- [x] One fix or feature; description under ~15 lines
