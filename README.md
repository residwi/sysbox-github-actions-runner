# sysbox-github-actions-runner

One Sysbox container per job, each with its own Docker daemon, destroyed after its single job. One VM serves several private repositories of one GitHub account (`OWNER`), one loop per repository (a personal account has no organization runners). Jobs never see the host's Docker socket.

Versions are pinned, except Docker: the Ubuntu 24.04 base by digest, the runner and `gh` in the `Dockerfile`, Sysbox and its SHA-256 in `setup.sh`. Bump a version and its checksum together. Docker, on the host and in the image, is the latest from Docker's signed apt repository each time `setup.sh` runs.

The image carries Go tools (`build-essential` for `go test -race`, `git`, `curl`, `gnupg`, `gh`, Docker, `sudo`, `jq`, `python3`, `unzip`, `xz-utils`, `zstd`). Other languages come from a `setup-*` action, services from the job's own Docker daemon.

## Why

- Each job runs in its own Sysbox container with its own Docker daemon, destroyed afterwards, so a job never touches the host's Docker socket or another job's state.
- The registration token never enters a job: the host loop uses it to mint a single-use JIT config, and only that config reaches the container.
- The host firewall drops traffic from job containers to the cloud metadata address, the host and private ranges, so a job cannot reach instance credentials or the VM's network.
- Only private repositories are served, because a public one would run fork pull requests on this VM.
- Only `run.sh` applies the `sysbox` label, so a job that requires it runs only inside this isolation; require it on every job.

## Private repositories only

`run.sh` asks GitHub whether `<owner>/<repo>` is private before every registration. Anything but `true` exits 78 and the unit stays stopped. A public repository would run fork pull requests on this VM.

The check cannot reach a runner already waiting. If a served repository is made public, run `sudo systemctl stop ci-runner@<repo>` at once.

## Token

One fine-grained personal access token covers every served repository:

- Resource owner `OWNER`, repository access: only the served repositories. Edit the list when you add or remove one.
- Permission: Administration, read and write (the smallest scope GitHub accepts for creating a JIT runner config). It is broad, so set a short expiry and rotate it.
- Lives only in `/etc/ci-runner/token`, mode 600, owned by `ci-runner`. `run.sh` rereads it each loop, so rotation needs no restart. Never in git, the image, the user-data or a workflow secret.
- Never run `gh auth login` on this VM.

## Install

1. Edit the top of `setup.sh`: `OWNER` (required: the GitHub account that owns the repositories) and `KIT_REF` (a full commit SHA of <https://github.com/residwi/sysbox-github-actions-runner>, so the VM gets exactly the code you reviewed; leave it empty and `main` is used, with a warning; it moves). `setup.sh` clones this public repository over https at that ref, so the user-data holds no credential and no token.
2. Create the VM (see Cloud notes) with `setup.sh` as user-data. Or, on an existing 24.04 VM: `sudo bash setup.sh`.
3. On the VM, wait and check:

   ```bash
   cloud-init status --wait                         # skip when run by hand
   sudo tail -n 20 /var/log/ci-runner-setup.log     # last line: PASS: ci-runner host setup complete
   ```

   A `FAIL` line names the step; fix the cause and re-run `sudo bash /usr/local/src/ci-runner/setup.sh`. Safe to repeat: `OWNER` and `KIT_REF` are stored in `/etc/ci-runner/env` and read back, so a re-run keeps the pinned ref unless you pass `KIT_REF=<new ref>`.

4. Write the token: `sudo -u ci-runner sh -c 'umask 077; cat > /etc/ci-runner/token'` (paste, then Ctrl-D).
5. Start a repository (below). No runner starts and nothing registers with GitHub before this.

## Cloud notes

- x86_64 only, Ubuntu 24.04 only (`setup.sh` refuses anything else). The image is amd64.
- Attach no instance identity (service account, instance profile, managed identity, instance principal). The firewall blocks the metadata address as a second layer, so containers use public DNS (`DNS_SERVERS`, default `1.1.1.1 8.8.8.8`). Keep that default.
- Use the VM for CI only.
- A provider image may ship its own iptables rules, loaded at boot. After the first reboot run `sudo bash /usr/local/src/ci-runner/setup.sh verify` and check it ends in `PASS`. Never run `netfilter-persistent save`: it would write Docker's rules into the saved set.

## Add a repository

The repository must be private and owned by `OWNER`. `<repo>` is the bare name.

1. Add `<repo>` to the token's repository access.
2. Start its loop:

   ```bash
   sudo systemctl enable --now ci-runner@<repo>
   sudo journalctl -u ci-runner@<repo> -f
   ```

   `refusing: ... is not private` means public: nothing registered. `cannot look up` means a wrong name or a missing token grant; it retries every 30 s.

3. Require the isolation label on every job in that repository:

   ```yaml
   runs-on: [self-hosted, Linux, X64, sysbox]
   ```

4. Under the repository's Settings, Actions, Runners, check an idle `sysbox-<repo>-...` runner, then run a job.

Never give the `sysbox` label to a runner outside this container; only `run.sh` applies it. Each instance runs one job at a time, so one repository's jobs queue while different repositories run side by side. A restart (`sudo systemctl restart 'ci-runner@*'`) cancels running jobs; do it when none run, for example after an image rebuild.

## Remove a repository

```bash
sudo systemctl disable --now ci-runner@<repo>
sudo rm -f /etc/ci-runner/<repo>.env
```

Then drop `<repo>` from the token's access. One idle runner stays registered until GitHub removes it (about a day), or delete it with `gh api -X DELETE repos/<owner>/<repo>/actions/runners/<id>` from your machine.

## Limits

Each runner container gets `--memory 6g --pids-limit 4096`, starting points rather than measurements. Settings are plain `NAME=value` lines (mode 600, no quotes) in `/etc/ci-runner/env` (all instances) and `/etc/ci-runner/<repo>.env` (one, wins); `sudo systemctl restart ci-runner@<repo>` applies them: `RUNNER_MEMORY=8g`, `RUNNER_PIDS_LIMIT=8192`, `DNS_SERVERS=9.9.9.9 1.1.1.1`. Size the VM for about `RUNNER_MEMORY` times the number of instances plus the host's needs; `--memory` is a cap, so a smaller VM starts but ends in OOM kills when every instance is busy. Watch `sudo docker stats` during a `Test` run.

## Maintenance

A kernel or Sysbox escape would expose the token and every served repository, so keep both current.

- Rotate the token before it expires. An expired token shows as `generate-jitconfig failed` or `cannot look up` in the journal.
- Security updates install unattended. The VM reboots at 04:00 (VM time) only when an update requires it, and that cancels running jobs. After a kernel upgrade run `sudo bash /usr/local/src/ci-runner/setup.sh verify`.
- To update the VM, see Versions.

`bash test.sh` checks `run.sh`'s guards (public repository, bad name, Sysbox label) with fake `gh` and `docker`; it needs neither Docker nor network.

## Versions

Every version but Docker is pinned, with a checksum where the publisher gives one. Dependabot updates two of them; the rest are bumped by hand.

| Pin                              | File                                           | How it updates                                                                                                                                                                                                                        |
| -------------------------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ubuntu 24.04 base digest         | `Dockerfile` `FROM`                            | Dependabot, weekly. Release bumps (26.04) are ignored on purpose.                                                                                                                                                                     |
| GitHub Actions in this repo's CI | `.github/workflows/ci.yml`                     | Dependabot, weekly.                                                                                                                                                                                                                   |
| Actions runner                   | `Dockerfile` `RUNNER_VERSION`, `RUNNER_SHA256` | By hand. The SHA-256 is in the [release notes](https://github.com/actions/runner/releases). Bump at least monthly: GitHub stops sending jobs to runners that fall too far behind.                                                     |
| `gh` in the image                | `Dockerfile` `GH_VERSION`, `GH_SHA256`         | By hand. The SHA-256 is in the release's `gh_<version>_checksums.txt` ([releases](https://github.com/cli/cli/releases)).                                                                                                              |
| Docker, host and image           | not pinned                                     | Latest from Docker's apt repository, on every `setup.sh` run (steps 2 and 3 below, with the same `KIT_REF`). The run upgrades the host's Docker, which restarts dockerd and stops running jobs, and rebuilds the image without cache. |
| Sysbox on the host               | `setup.sh` `SYSBOX_VERSION`, `SYSBOX_SHA256`   | By hand. The SHA-256 is in the [release notes](https://github.com/nestybox/sysbox/releases). Check the release supports Ubuntu 24.04 and the VM's kernel.                                                                             |
| Docker apt key                   | `setup.sh` and `Dockerfile` `DOCKER_KEY_FPR`   | Only if Docker rotates its key; `setup.sh` fails at "docker" and the image build fails when it no longer matches.                                                                                                                     |

To bump a version by hand:

1. Change the version and its checksum together, in one commit, and push. CI runs `shellcheck`, `test.sh` and the image build, so a wrong checksum fails there.
2. On the VM, once CI passes and when no job runs: `sudo KIT_REF=<new commit SHA> bash /usr/local/src/ci-runner/setup.sh`. It upgrades Docker, rebuilds the image, re-runs every check and stores the new ref for later re-runs.
3. When no job runs, restart the loops so they use the new image: `sudo systemctl restart 'ci-runner@*'`.

## Monitoring

```bash
sudo ci-runner-status
```

It shows each enabled instance (state, restarts, last exit, recent errors), disk, memory, runner containers and the runners GitHub has registered, and exits 1 when an enabled instance is not active. GitHub sends no alert for a job stuck in "Waiting for a runner", so run it then. Logs: a job's output is on its GitHub run page; the loop is in `sudo journalctl -u ci-runner@<repo>` (capped at 1 GB for the host); OOM kills are in `sudo journalctl -k | grep -i oom`.

In the provider's console, alert on: VM down or unreachable, CPU above 90% for 15 minutes, memory above 90%, disk above 80%. Memory and disk usually need the provider's agent; without it rely on `ci-runner-status`.

## Troubleshooting

- `docker run --runtime=sysbox-runc` fails: try `{"features": {"containerd-snapshotter": false}}` in `/etc/docker/daemon.json`, restart Docker, rebuild the image. Not verified.
- `runner container exited non-zero`: the loop waits 30 s and retries. Logs are gone (`--rm`); reproduce with `setup.sh verify`.
- Names do not resolve: check `DNS_SERVERS` is reachable and the env files have no quotes.
- Instance `failed` with exit 78: public repository or invalid name; the journal says which. Fix it, then restart the instance.
