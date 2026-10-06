# build-environment

Like Eighteen Bears' build environment: Docker images with our supported C/C++ toolchains, for building in CI and developing locally.

## Images

| Image | Use it for | Built from target |
|---|---|---|
| `likeeighteenbears/build-environment-ci-desktop` | CI builds for desktop (x86_64) targets | `ci_desktop` |
| `likeeighteenbears/build-environment` | Local development, including the [docker-development-environment](https://github.com/like-eighteen-bears/docker-development-environment) (DDE) | `development` |

The development image is the CI image plus a non-root `leb` user and shell setup for interactive work. Anything that builds in CI builds the same way in development.

### Tags

Both images get the same tags:

| Tag | Published when | Use it for |
|---|---|---|
| `sha-<commit>`, e.g. `sha-74526ca` | Every push to `main` | Pinning an exact build |
| `1.2.3` and `1.2` | A `v1.2.3` git tag is pushed | Pinning a release |
| `latest` | Every push to `main` | Trying out the newest build |

Pin a `sha-` or version tag in CI and in DDE's `BUILD_ENVIRONMENT_TAG`. `latest` changes with every push to `main`, so a build that passed yesterday can fail today for reasons unrelated to your change.

## What's included

Both images are based on Ubuntu 24.04 and include:

| Tool | Version | Notes |
|---|---|---|
| GCC | 14 | Default `gcc`, `g++`, `cc`, `c++` and `gcov` |
| Clang / LLVM | 17 | Default `clang`, `clang++`, `clang-format`, `clang-tidy`, `git-clang-format`, `lld`/`ld.lld` and `llvm-*` tools |
| CMake | 4.1.1 | |
| Ninja | 1.12.1 | |
| ccache | 4.11.3 | See [ccache](#ccache) |
| lcov | 2.0 | |
| Python | 3.11.9 via pyenv, plus the system's 3.12 | See [Python](#python) |
| Node.js | 22 | |
| Docker CLI | Latest from Docker's apt repo | Includes `docker buildx` and `docker compose`. There's no daemon: mount the host's socket |
| git, git-lfs | Ubuntu 24.04's versions | |

The development image also has the Wayland and xkbcommon development libraries, XWayland, `sshpass` and an SSH server. See [SSH access](#ssh-access).

### Python

- `python`, `python3`, `pip` and `pip3` all use pyenv's 3.11.9.
- Ubuntu's 3.12 is still installed, without pip or development headers, because the system's own tools use it through `/usr/bin/python3`. It also stays available as `python3.12`.
- `sudo` resets `PATH`, so `sudo python3` runs Ubuntu's 3.12, not pyenv's.
- In the development image, `leb` can install packages and extra Python versions into pyenv, at `/opt/pyenv`, through the `pyenv` group.

### ccache

`CCACHE_DIR` tells ccache where to keep its cache:

| Image | `CCACHE_DIR` | Why |
|---|---|---|
| CI | `/ccache` | Writable by any user, so CI can run as any UID. Mount a cache volume here to keep the cache between runs |
| Development | `/home/leb/.ccache` | Matches the persistent volume DDE mounts |

## Using the images

### In CI

The CI image has no non-root user. It runs as root unless your CI system passes its own UID. Everything is configured with environment variables, so no login shell is needed.

For example, as a GitHub Actions container job with a persistent ccache:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    container: likeeighteenbears/build-environment-ci-desktop:sha-74526ca
    steps:
      - uses: actions/checkout@v7
      - uses: actions/cache@v6
        with:
          path: /ccache
          key: ccache-${{ github.sha }}
          restore-keys: ccache-
      - run: cmake -B build -G Ninja -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
      - run: cmake --build build
```

To use Docker inside the job, mount the host's socket with `options: -v /var/run/docker.sock:/var/run/docker.sock`.

### For development

The development image adds a `leb` user:

- UID and GID 999, in the `sudo`, `pyenv` and `docker` groups.
- Passwordless `sudo`. The password is locked, so `leb` can't log in with one.
- Home directories that are usually volume-mounted already exist and belong to `leb`: `~/.cache`, `~/.ccache`, `~/.config`, `~/.persistent`, `~/.vscode` and `~/.vscode-server`. This stops Docker creating them as root when the volume is first mounted.
- `~/.persistent/.persistent_bashrc` is sourced by `~/.bashrc`. Put your own shell customisation there and keep it on a persistent volume.
- The login shell is bash.

The image's default user is root so that derived images can adjust the user before switching to it, as below.

#### Matching your host user and Docker group

Files that `leb` writes to bind mounts are owned by UID 999 on the host. To make them yours, and to let `leb` use a mounted Docker socket, run the image's remap script as root in a derived image:

```dockerfile
FROM likeeighteenbears/build-environment:sha-74526ca

ARG HOST_USER_ID
ARG HOST_GROUP_ID
ARG DOCKER_GROUP_ID
RUN /opt/leb/update_user_group_ids.sh "${HOST_USER_ID}" "${HOST_GROUP_ID}" "${DOCKER_GROUP_ID}"

USER $DEFAULT_USER
```

- `update_user_group_ids.sh userId groupId [dockerGroupId]` changes `leb`'s UID and GID and re-owns `/home/leb`.
- If you leave out `dockerGroupId`, the script uses the group of `/var/run/docker.sock` when that is mounted, which only happens at runtime.
- The `docker` group takes the Docker group ID. If another group in the image already has it, `leb` joins that group instead. That includes `leb`'s own group, e.g. when the host user's primary group is `docker`, as on GitHub's runners.
- The script stops with an error if the user or group ID belongs to another user or group in the image, such as `pyenv` (995).
- On the host, get the values with `id -u`, `id -g` and `getent group docker | cut -d: -f3`.
- The Ubuntu base image's `ubuntu` user, which has UID/GID 1000, is removed from the development image so that `leb` can take those IDs. Don't try to `userdel ubuntu` in a derived image: it fails because the user no longer exists.

DDE does the same. See its [Dockerfile](https://github.com/like-eighteen-bears/docker-development-environment/blob/main/Dockerfile).

#### SSH access

The development image has an SSH server, for tools that connect over SSH, such as IDE remote toolchains. It isn't started automatically. Start it as root in a running container:

```sh
docker exec -u root <container> /opt/leb/start_sshd.sh
```

- sshd listens on port 22 in the container. Publish it to reach it from the host, e.g. `ports: ["2222:22"]` in compose.
- Only key authentication works: `leb` has no password. Put your public key in `/home/leb/.ssh/authorized_keys`.
- Host keys are generated the first time sshd starts in a container, so each container has its own. Recreating the container changes them, and your SSH client will warn about the changed key.
- SSH sessions don't inherit the container's environment, so every session is started through [env_setup.sh](sshd/env_setup.sh). It loads the image's settings, like `PATH`, `CCACHE_DIR` and `LANG`, as they were when the image was built. Values you override at runtime, e.g. with compose's `environment:`, don't reach SSH sessions.

## Maintaining the images

### Layout

The [Dockerfile](Dockerfile) is a multi-stage build:

```
downloader ─┬─ cmake, ninja, ccache, pyenv    one stage per downloaded tool, so changing
            │                                 one doesn't rebuild the others
            └─ base                           tools needed by every image, configured with ENV
                 └─ ci_desktop                desktop compilers, Docker CLI, Node.js
                      └─ development          leb user, shell setup, SSH server, GUI libraries
```

Keep CI-only needs out of `development` and development-only needs out of `base` and `ci_desktop`. The CI image is meant to contain only what a build needs.

### Dev container

The repo has a [dev container](.devcontainer) for working on it in VS Code: **Dev Containers: Reopen in Container**.

- It runs the published development image as `leb`, with the Docker socket mounted, so you can build and test the images from inside.
- Before building, [initialize.sh](.devcontainer/initialize.sh) records your host UID, GID and Docker socket group. The container's `leb` is changed to match, so files you create in the workspace belong to you and `docker` works without `sudo`.
- To run a locally built development image instead, set `BASE_IMAGE`, e.g. `BASE_IMAGE=build-environment:test`, in the environment VS Code is started from. Then rebuild the container.

The dev container expects a Linux host.

### Building and testing locally

Build with a `docker-container` builder, the same kind the workflow uses. Docker's default builder handles some instructions differently, e.g. `COPY --link`, so a build that passes on it can still fail in CI.

```sh
# Once
docker buildx create --name build-environment --driver docker-container

docker buildx build --builder build-environment --target ci_desktop  -t build-environment-ci-desktop:test --load .
docker buildx build --builder build-environment --target development -t build-environment:test --load .

./test/smoke-test.sh build-environment-ci-desktop:test ci_desktop
./test/smoke-test.sh build-environment:test development
```

The [smoke tests](test/smoke-test.sh) check that the tools run non-interactively as the users each image is meant for. They also check the ccache, pyenv, sudo and ID-remapping setup. Add a check when you add a tool or change configuration.

### Updating a tool version

Every download is verified against a SHA-256 declared next to its version at the top of the [Dockerfile](Dockerfile). A mismatch fails the build. To update a tool:

1. Change the version ARG, e.g. `CMAKE_VERSION`.
2. Download the new file and get its checksum. Where the project publishes checksums or signatures, check against those too:
   ```sh
   curl -fsSL <url> | sha256sum
   ```
3. Update the matching `_SHA256` ARG.
4. Build and run the smoke tests.

The Docker and NodeSource apt signing keys are pinned the same way, with `DOCKER_APT_GPG_SHA256` and `NODESOURCE_APT_GPG_SHA256`. If either project rotates its key, the build fails until the checksum is updated. Check the new key's fingerprint against the project's documentation first.

GCC, Clang and Node.js come from apt. Change `GCC_VERSION`, `CLANG_VERSION` or `NODE_VERSION` to switch major versions.

### Publishing

[The workflow](.github/workflows/main.yml) builds both images and runs the smoke tests:

- **Pull requests to `main`:** build and test only.
- **Pushes to `main`:** also push the `sha-` and `latest` tags.
- **`v*` git tags:** also push the version tags.

Nothing is pushed unless the smoke tests pass.

To publish a release:

```sh
git tag v1.2.3
git push origin v1.2.3
```

It needs the `DOCKER_USERNAME` and `DOCKER_PASSWORD` repository secrets for an account that can push to `likeeighteenbears` on Docker Hub.
