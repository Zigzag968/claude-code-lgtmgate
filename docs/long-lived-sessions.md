# Long-lived Lead sessions

A Lead session older than three days loses the certificate bundle of its sandbox: every `git` and `gh` call over HTTPS then fails on certificates (#251).

## Cause

- At session start the sandbox writes one bundle, `srt-ca-<id>/trust-bundle.crt`, in the process temp directory.
- It exports the file as `SSL_CERT_FILE`, `GIT_SSL_CAINFO`, `NODE_EXTRA_CA_CERTS`, `CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`.
- macOS (`com.apple.bsd.dirhelper`) cleans files older than three days from the user temp directory.
- Nothing recreates the file; only a new process restores it.

## Symptom and check

- Symptom: TLS or x509 errors on `git` and `gh` in a session that worked before.
- Check: `bash scripts/ca-bundle-check.sh` (the Lead runs it at step 0 of `skills/deliver/SKILL.md`).
- A gone bundle prints `sandbox-ca-stale`, names the variable and the cause (`missing` or `empty`), exit 1.
- Row: `docs/consumer-reference.md`, Other reasons.

## Restart rule

- Restart a Lead session before it reaches three days.
- Age of the bundle: `stat -f '%SB' "$SSL_CERT_FILE"` (birth time).

## Launcher recipe

| Option | Status |
|---|---|
| Run the session in `tmux` (survives a closed terminal) | Observed to work for keeping the process alive; says nothing about the bundle |
| Start with the process temp directory on a volume the sweep does not touch (`TMPDIR=<dir> claude ...`) | One observation: the bundle is created under the relocated directory. Survival beyond three days: untested |
| Remote control for the tmux session | Convenience only, no effect on the bundle |

## Keepalive

Options weighed in #251; the maintainer has not chosen yet.

- Hook refreshing the access time: not chosen (ships an OS-specific hook to every consumer, fires only while the session has events; unverified that access time protects the file).
- User-level scheduled task touching the bundle: not chosen (unverified for the same reason).
- Relocated temp directory: proposed, partly verified (creation only).
- Restart under three days: proposed, follows from the cause.
