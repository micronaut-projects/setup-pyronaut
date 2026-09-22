# setup-pyronaut

A GitHub Action that provisions everything [Pyronaut](https://github.com/micronaut-projects/pyronaut)
needs in CI, and caches all of it.

Getting a Pyronaut project building on a fresh runner means four separate things have to line up:
a GraalVM JDK 25 or later, the Pyronaut CLI, a GraalPy environment with `pytest` in it, and a
completed `pyronaut setup` — which downloads native launchers and resolves the SDK classpath.
Done by hand that is a few hundred megabytes of downloads on every single job. This action does
it in one step and keeps the result in the GitHub Actions cache.

```yaml
- uses: actions/checkout@v5

- uses: micronaut-projects/setup-pyronaut@v1

- run: pyronaut install
- run: pyronaut test
```

That is the whole workflow. The action installs the CLI, puts it on `PATH`, sets `JAVA_HOME` to a
GraalVM, creates `.venv` from GraalPy with `pytest` in it, and runs `pyronaut setup`.

## Contents

- [What it does](#what-it-does)
- [Caching](#caching)
- [Usage](#usage)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [Notes](#notes)
- [Development](#development)

## What it does

The action runs these steps, in order:

1. **Preflight.** Settles the project directory, the Pyronaut home, the Maven repository and the
   cache key base. Fails immediately on Windows, which Pyronaut does not support.
2. **GraalVM.** Delegates to [`graalvm/setup-graalvm`](https://github.com/graalvm/setup-graalvm)
   and then verifies that `JAVA_HOME` really is a GraalVM 25 or later. Pyronaut's own toolchain
   discovery takes `JAVA_HOME` first when it satisfies the requested toolchain, so this is what
   stops `pyronaut setup` from downloading a second GraalVM of its own.
3. **Pyronaut CLI.** Installs the wheel into a dedicated CPython virtual environment and puts
   `pyronaut` on `PATH`. Reads `pyronaut --version` to learn which GraalPy that CLI expects.
4. **GraalPy and pytest.** Installs GraalPy through `pyenv` and builds the project's `.venv` from
   it, with `pytest` inside. `pyronaut test` runs pytest on the embedded GraalPy runtime, and a
   CPython environment cannot supply packages to it, so this environment has to be created by
   GraalPy itself.
5. **Settings.** Writes `~/.pyronaut/settings.toml` when any of the settings inputs are given.
6. **`pyronaut setup`.** Provisions the SDK toolchain, downloads the native launchers and resolves
   the SDK classpaths into the Maven repository.

Steps 2 and 4 can be turned off individually when a workflow already provides them.

## Caching

Three caches, each keyed on what actually invalidates it:

| Cache | Contents | Key |
| --- | --- | --- |
| SDK | `~/.pyronaut` — the setup manifest, provisioned JDKs, native launchers and resolved tool runtime | OS, architecture, Pyronaut version, the exact GraalVM in use, and the contents of `settings.toml` |
| GraalPy | `~/.pyenv` and the project environment | OS, architecture, the pyenv GraalPy identifier, and every requirement installed into the environment |
| Maven | `~/.m2/repository` | OS, architecture, Pyronaut version, and a hash of the project's `pyproject.toml` |

A few details worth knowing:

- **The SDK cache is saved as soon as `pyronaut setup` succeeds**, not in a post step. A failing
  build later in the job does not throw away a good SDK.
- **The Maven cache is saved at the end of the job**, because `pyronaut install` keeps resolving
  project dependencies into it long after this action has finished.
- **A stale cache costs one extra `pyronaut setup`, never a broken build.** Pyronaut re-validates
  its manifest against the current GraalVM, repositories and launcher configuration on every run
  and re-provisions whatever no longer matches. That is why the SDK cache has restore-key
  fallbacks: a near-miss still saves most of the downloads.
- **A restored GraalPy environment is verified before it is trusted.** The action records what it
  installed in a marker file and rebuilds the environment if the marker, the interpreter, or the
  environment itself does not check out.

Set `cache: false` or `cache-maven: false` to opt out. Use `cache-key-suffix` to keep unrelated
jobs from sharing an entry, and bump `cache-key-prefix` to invalidate everything at once.

## Usage

### Build and test a Pyronaut project

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - uses: micronaut-projects/setup-pyronaut@v1
        with:
          pyronaut-version: '0.0.3'
          java-version: '25'
          graalvm-version: '25.3'
          pytest-version: '9.0.3'

      - run: pyronaut install
      - run: pyronaut process
      - run: pyronaut test
```

### Across operating systems

```yaml
strategy:
  fail-fast: false
  matrix:
    os: [ubuntu-latest, macos-latest]
runs-on: ${{ matrix.os }}
steps:
  - uses: actions/checkout@v5
  - uses: micronaut-projects/setup-pyronaut@v1
  - run: pyronaut test
```

Caches are keyed per operating system and architecture, so the matrix legs never collide.

### Testing a CLI built in the same workflow

```yaml
- run: ./gradlew :micronaut-pyronaut:buildSdkWheel

- uses: micronaut-projects/setup-pyronaut@v1
  with:
    pyronaut-wheel: pyronaut/build/wheel/dist/pyronaut-*.whl
    project-dir: examples/hello-world
```

The glob has to match exactly one file. A `https://` or `file://` URL works too.

### Reusing a GraalVM the workflow already set up

```yaml
- uses: graalvm/setup-graalvm@v1
  with:
    distribution: graalvm
    java-version: '25'
    version: '25.3'
    components: native-image

- uses: micronaut-projects/setup-pyronaut@v1
  with:
    graalvm: 'false'
```

The action still verifies `JAVA_HOME` and fails with a clear message if it is not a GraalVM 25+.

### A job that only builds, and never runs pytest

```yaml
- uses: micronaut-projects/setup-pyronaut@v1
  with:
    graalpy: 'false'
```

This skips the GraalPy install entirely, which is the slowest part of a cold run.

### Pointing at a private native-launcher bundle

```yaml
- uses: micronaut-projects/setup-pyronaut@v1
  with:
    github-token: ${{ secrets.PYRONAUT_RELEASE_TOKEN }}
    native-images-base-url: https://github.com/micronaut-projects/pyronaut/releases
    native-images-version: '0.0.3'
    maven-repositories: |
      mavenCentral
      https://central.sonatype.com/repository/maven-snapshots/
```

These are written to `~/.pyronaut/settings.toml` before setup runs, and they take part in the SDK
cache key.

### Diagnosing a failure

```yaml
- uses: micronaut-projects/setup-pyronaut@v1
  with:
    run-doctor: 'true'
```

`pyronaut doctor` checks Python, the setup state, GraalVM, GraalPy, the native launchers and the
project, and prints a fix for every failing check. It is reported as a warning, not a failure.

## Inputs

### Pyronaut CLI

| Input | Default | Description |
| --- | --- | --- |
| `pyronaut-version` | `latest` | Version to install from PyPI. `latest`, an exact version such as `0.0.3`, or a PEP 440 specifier such as `>=0.0.3,<0.1`. Ignored when `pyronaut-wheel` is set. |
| `pyronaut-wheel` | | Path, glob or URL of a wheel to install instead. A glob must match exactly one file. |
| `cli-venv-dir` | `$RUNNER_TEMP/pyronaut-cli-venv` | Where the CPython environment holding the CLI goes. |

### GraalVM

| Input | Default | Description |
| --- | --- | --- |
| `graalvm` | `true` | Set up a GraalVM via `graalvm/setup-graalvm`. Set to `false` when the workflow already provides one. |
| `java-version` | `25` | Java version. Pyronaut requires 25 or later. |
| `graalvm-version` | `25.3` | GraalVM release, for example `25.3`, `latest` or `dev`. |
| `graalvm-distribution` | `graalvm` | `graalvm` for Oracle GraalVM, `graalvm-community` for the community build. |

### GraalPy

| Input | Default | Description |
| --- | --- | --- |
| `graalpy` | `true` | Install GraalPy and create the project environment. Required for `pyronaut test`. |
| `graalpy-version` | from the CLI | A pyenv identifier such as `graalpy3.13-25.3.4.1`, or a bare version such as `25.3.4.1`. Defaults to the GraalPy the installed CLI reports. |
| `graalpy-python-version` | `3.13` | Python feature version used to build a pyenv identifier from a bare GraalPy version. |
| `pytest-version` | `latest` | `latest`, an exact version, or a PEP 440 specifier. |
| `python-packages` | | Extra pip requirements for the GraalPy environment, one per line. |
| `venv-dir` | `<project-dir>/.venv` | Where the GraalPy environment goes. Pyronaut looks for a project `.venv`. |
| `activate-venv` | `false` | Put the environment on `PATH` and export `VIRTUAL_ENV`, making `python` GraalPy for the rest of the job. |

### Setup

| Input | Default | Description |
| --- | --- | --- |
| `project-dir` | `.` | Project root, used to find `pyproject.toml` and to place the GraalPy environment. |
| `run-setup` | `true` | Run `pyronaut setup`. |
| `setup-args` | | Extra arguments for `pyronaut setup`, one argument per line — see [Notes](#notes). |
| `run-doctor` | `false` | Run `pyronaut doctor` afterwards and print its report. |
| `local-repository` | `~/.m2/repository` | Maven local repository. |
| `maven-repositories` | | Repositories for `[maven].repositories` in `settings.toml`, one per line. |
| `native-images-base-url` | | `[native-images].base-url` in `settings.toml`. |
| `native-images-version` | | `[native-images].version` in `settings.toml`. |
| `native-images-release-tag` | | `[native-images].release-tag` in `settings.toml`. |
| `github-token` | `${{ github.token }}` | Token for downloading native launchers and for API rate limits. See [Notes](#notes). |

### Caching

| Input | Default | Description |
| --- | --- | --- |
| `cache` | `true` | Cache `~/.pyronaut` and the GraalPy installation. |
| `cache-maven` | `true` | Cache the Maven local repository. |
| `cache-key-prefix` | `setup-pyronaut-v1` | Prefix for every cache key. Bump it to invalidate all caches. |
| `cache-key-suffix` | | Extra key component, to keep unrelated jobs from sharing caches. |

## Outputs

| Output | Description |
| --- | --- |
| `pyronaut-version` | Version reported by the installed CLI. |
| `pyronaut` | Absolute path of the `pyronaut` executable. |
| `pyronaut-home` | The Pyronaut state directory, `~/.pyronaut`. |
| `micronaut-core-version` | Micronaut Core version bundled with the CLI. |
| `graalpy-version` | GraalPy version that was installed, for example `25.3.4.1`. |
| `graalpy-pyenv-version` | pyenv identifier of the installed GraalPy. |
| `java-home` | The GraalVM installation Pyronaut uses. |
| `venv-dir` | The GraalPy environment created for the project. |
| `python` | Absolute path of the GraalPy interpreter in that environment. |
| `local-repository` | The Maven local repository Pyronaut uses. |
| `cache-hit` | `true` when `~/.pyronaut` was restored from an exact key match. |
| `graalpy-cache-hit` | `true` when the GraalPy cache was restored from an exact key match. |

## Notes

**Platforms.** Linux and macOS, on x64 and aarch64. Pyronaut does not support Windows, and the
action fails in its first step there rather than partway through a download.

**`github-token` and private releases.** Pyronaut downloads its native launcher bundles from
GitHub releases of `micronaut-projects/pyronaut`. The default `${{ github.token }}` is scoped to
the repository running the workflow, so while that repository is private you need a token with
`contents: read` on it:

```yaml
with:
  github-token: ${{ secrets.PYRONAUT_RELEASE_TOKEN }}
```

Once the releases are public the default token is enough, and only serves to raise API rate limits.

**The project `.venv` is recreated.** The action owns `<project-dir>/.venv`. If your repository
checks in or pre-creates that directory, point `venv-dir` somewhere else.

**`python` stays CPython.** The GraalPy environment is not put on `PATH` unless you ask for it
with `activate-venv`, so other tooling in the job keeps the Python it expects. Pyronaut finds the
environment through the project directory, not through `PATH`.

**`PYENV_VERSION` is exported.** The action sets `PYENV_ROOT` and `PYENV_VERSION` so
`pyronaut doctor` agrees with what was installed, but deliberately keeps pyenv's shims off `PATH`.

**Boolean inputs** accept `true`/`false`, `yes`/`no`, `on`/`off` and `1`/`0`, in any case. Anything
else fails the first step with a message naming the input, rather than being quietly read as off.

**`setup-args` is one argument per line**, so that a value containing spaces survives:

```yaml
setup-args: |
  --refresh
  --progress
  on
```

Writing `--progress on` on a single line would reach the CLI as one token. The action warns when it
sees that, and suggests `--option=value` as the shorter alternative.

## Development

```bash
./tests/run-tests.sh              # the whole suite
./tests/run-tests.sh graalpy      # just the tests whose name matches
shellcheck -x -S style scripts/*.sh tests/run-tests.sh
shfmt --diff --indent 2 --case-indent scripts/*.sh tests/run-tests.sh
python3 tests/validate-action.py  # action.yml references resolve, inputs are documented
```

The scripts must run on bash 3.2, which is what macOS runners still provide: no `local -n`, no
associative arrays, no `mapfile`, no `${var,,}`. The unit suite runs on macOS in CI for exactly
this reason.

CI runs on every push: shellcheck, shfmt, actionlint, the unit suite on Linux and macOS, and the
action itself end to end — including a second invocation that has to come back with `cache-hit` set.
`.github/workflows/integration.yml` is the manual counterpart: it runs the action against the real
Pyronaut CLI and a real hello-world project, all the way through `pyronaut test`.

`tests/fixtures/stub-cli` is a stand-in for the real Pyronaut CLI. It reproduces the parts this
action contracts on — the `--version` report and an idempotent `setup` — so CI can exercise the
whole action, including the real GraalVM and GraalPy installs and the caching, without read access
to a private repository.

## License

Apache License 2.0. See [LICENSE](LICENSE).
