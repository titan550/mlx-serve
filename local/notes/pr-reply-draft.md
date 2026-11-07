Thank you for the review.

**1. Prefix cache with steering.** This is intentional. Steering is not a frequent setting. You set it for a special operation, and then you set it off.

A steered request uses the cached prefix, the same as a request without steering. The server does a prefill of the new tokens only. The steering of the request applies to these tokens and to the decode. A steered request does not do a full prefill.

Thus, a restored prefix keeps the steering that the server used when it calculated that prefix. `docs/reference.md` gives this rule. `tests/test_qwen4_steering.sh` [6] tests it.

A separate cache for each steering setting costs more than it gives. A steered request that does not use the cache also costs more than it gives. If you want a different rule, tell me and I will change the code.

**2. `steering.file` shows if a file exists.** This problem is the same as #540. I can do one of these two changes:
- Let the request field accept only names of banks in `~/.mlx-serve/steering/`. Keep absolute paths for the launch flags and `POST /v1/steering`.
- Use the same fix as #540.

Which change do you want?

Before I rebase or change the code, please tell me: do you agree with the direction of this PR?
